#!/usr/bin/env bash
set -Eeuo pipefail

# Purpose: transactionally reconcile one minimal static Nginx site and an
# optional Let's Encrypt certificate. Runs as root after Ubuntu packages exist.
# Inputs: site filename, zero or more validated DNS names, local probe name,
# Certbot email, and certificate name.
# Safety model: snapshot every managed path and relevant service state, stage an
# HTTP challenge configuration only when needed, request/renew the certificate,
# validate and probe the final configuration, then commit. Any failure restores
# the preceding Nginx files, certificate lineage, and service state.

# `:?` requires a non-empty value. Plain `?` requires the variable to exist but
# permits an empty value, which is the supported private HTTP-only configuration.
: "${NGINX_SITE_NAME:?}"
: "${NGINX_SERVER_NAMES?}"
: "${NGINX_PROBE_SERVER_NAME:?}"
: "${CERTBOT_EMAIL?}"
: "${CERTBOT_CERTIFICATE_NAME?}"

if [[ ! "$NGINX_SITE_NAME" =~ ^[a-z0-9][a-z0-9.-]*$ ]]; then
  echo "NGINX_SITE_NAME contains unsafe path characters." >&2
  exit 1
fi
if [ -n "$CERTBOT_CERTIFICATE_NAME" ] && \
   [[ ! "$CERTBOT_CERTIFICATE_NAME" =~ ^[a-z0-9][a-z0-9.-]*$ ]]; then
  echo "CERTBOT_CERTIFICATE_NAME contains unsafe path characters." >&2
  exit 1
fi

NGINX_SITE_AVAILABLE="/etc/nginx/sites-available/$NGINX_SITE_NAME"
NGINX_SITE_ENABLED="/etc/nginx/sites-enabled/$NGINX_SITE_NAME"
NGINX_DEFAULT_ENABLED="/etc/nginx/sites-enabled/default"
NGINX_INDEX_FILE="/var/www/html/index.html"
CERTBOT_DEPLOY_HOOK="/etc/letsencrypt/renewal-hooks/deploy/reload-nginx"
CERTBOT_ARCHIVE="/etc/letsencrypt/archive/$CERTBOT_CERTIFICATE_NAME"
CERTBOT_LIVE="/etc/letsencrypt/live/$CERTBOT_CERTIFICATE_NAME"
CERTBOT_RENEWAL="/etc/letsencrypt/renewal/$CERTBOT_CERTIFICATE_NAME.conf"

# Keep transaction data root-only and outside the configuration trees being
# changed. The snapshot mirrors absolute paths beneath its snapshot directory.
TRANSACTION_PARENT="/var/lib/vagrant/nginx-transactions"
install -d -m 0700 "$TRANSACTION_PARENT"
TRANSACTION_DIRECTORY="$(mktemp -d "$TRANSACTION_PARENT/transaction.XXXXXX")"
SNAPSHOT_DIRECTORY="$TRANSACTION_DIRECTORY/snapshot"
install -d -m 0700 "$SNAPSHOT_DIRECTORY"

remove_path() {
  local path="$1"
  if [ -L "$path" ] || [ -f "$path" ]; then
    rm -f -- "$path"
  elif [ -d "$path" ]; then
    find "$path" -mindepth 1 -depth -delete
    rmdir -- "$path"
  fi
}

snapshot_path() {
  local path="$1"
  local snapshot="$SNAPSHOT_DIRECTORY$path"
  if [ -e "$path" ] || [ -L "$path" ]; then
    install -d -m 0700 "$(dirname "$snapshot")"
    cp -a -- "$path" "$snapshot"
  fi
}

restore_path() {
  local path="$1"
  local snapshot="$SNAPSHOT_DIRECTORY$path"
  remove_path "$path"
  if [ -e "$snapshot" ] || [ -L "$snapshot" ]; then
    install -d -m 0755 "$(dirname "$path")"
    cp -a -- "$snapshot" "$path"
  fi
}

NGINX_WAS_ACTIVE=false
NGINX_WAS_ENABLED=false
CERTBOT_TIMER_WAS_ACTIVE=false
CERTBOT_TIMER_WAS_ENABLED=false
systemctl is-active --quiet nginx && NGINX_WAS_ACTIVE=true
systemctl is-enabled --quiet nginx && NGINX_WAS_ENABLED=true
systemctl is-active --quiet certbot.timer && CERTBOT_TIMER_WAS_ACTIVE=true
systemctl is-enabled --quiet certbot.timer && CERTBOT_TIMER_WAS_ENABLED=true

MANAGED_PATHS=(
  "$NGINX_SITE_AVAILABLE"
  "$NGINX_SITE_ENABLED"
  "$NGINX_DEFAULT_ENABLED"
  "$NGINX_INDEX_FILE"
  "$CERTBOT_DEPLOY_HOOK"
)
if [ -n "$CERTBOT_CERTIFICATE_NAME" ]; then
  MANAGED_PATHS+=("$CERTBOT_ARCHIVE" "$CERTBOT_LIVE" "$CERTBOT_RENEWAL")
fi
for MANAGED_PATH in "${MANAGED_PATHS[@]}"; do
  snapshot_path "$MANAGED_PATH"
done

TRANSACTION_ACTIVE=true
cleanup_transaction() {
  if [ -d "$TRANSACTION_DIRECTORY" ]; then
    find "$TRANSACTION_DIRECTORY" -depth -delete
  fi
}

rollback_transaction() {
  local original_status=$?
  trap - EXIT INT TERM HUP

  if [ "$TRANSACTION_ACTIVE" = true ]; then
    echo "Nginx/Certbot reconciliation failed; restoring the previous state." >&2
    for ((INDEX=${#MANAGED_PATHS[@]} - 1; INDEX >= 0; INDEX--)); do
      restore_path "${MANAGED_PATHS[$INDEX]}" || true
    done

    if [ "$NGINX_WAS_ENABLED" = true ]; then
      systemctl enable nginx > /dev/null 2>&1 || true
    else
      systemctl disable nginx > /dev/null 2>&1 || true
    fi
    if [ "$NGINX_WAS_ACTIVE" = true ]; then
      if nginx -t; then
        if systemctl is-active --quiet nginx; then
          systemctl reload nginx || true
        else
          systemctl start nginx || true
        fi
      fi
    else
      systemctl stop nginx > /dev/null 2>&1 || true
    fi

    if [ "$CERTBOT_TIMER_WAS_ENABLED" = true ]; then
      systemctl enable certbot.timer > /dev/null 2>&1 || true
    else
      systemctl disable certbot.timer > /dev/null 2>&1 || true
    fi
    if [ "$CERTBOT_TIMER_WAS_ACTIVE" = true ]; then
      systemctl start certbot.timer > /dev/null 2>&1 || true
    else
      systemctl stop certbot.timer > /dev/null 2>&1 || true
    fi
  fi

  cleanup_transaction
  exit "$original_status"
}
trap rollback_transaction EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# Build candidates in the transaction directory. Files are installed atomically
# only after they are complete; the whole Nginx configuration is then tested
# before any reload or start.
NGINX_CONFIG_TEMP="$TRANSACTION_DIRECTORY/site.conf"
NGINX_INDEX_TEMP="$TRANSACTION_DIRECTORY/index.html"
NGINX_CONFIG_CHANGED=false

# Keep the default site immediately useful and make the integration probe test
# an actual document response instead of only a listening socket. The index is
# part of MANAGED_PATHS, so a later failure restores prior content or absence.
cat > "$NGINX_INDEX_TEMP" <<'HTML'
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Ubuntu development VM</title>
  </head>
  <body>
    <h1>Ubuntu development VM is running</h1>
  </body>
</html>
HTML
install -d -o root -g root -m 0755 "$(dirname "$NGINX_INDEX_FILE")"
if ! cmp --silent "$NGINX_INDEX_TEMP" "$NGINX_INDEX_FILE" 2> /dev/null; then
  install -o root -g root -m 0644 "$NGINX_INDEX_TEMP" "$NGINX_INDEX_FILE"
fi

write_http_config() {
  local server_names="$NGINX_SERVER_NAMES"
  [ -n "$server_names" ] || server_names="_"
  cat > "$NGINX_CONFIG_TEMP" <<NGINX
server {
    listen 80 default_server;
    server_name $server_names;
    server_tokens off;

    root /var/www/html;
    index index.html;
    location / {
        try_files \$uri \$uri/ =404;
    }
}
NGINX
}

write_https_config() {
  cat > "$NGINX_CONFIG_TEMP" <<NGINX
server {
    listen 80 default_server;
    server_name $NGINX_SERVER_NAMES;
    return 308 https://\$host\$request_uri;
}

server {
    listen 443 ssl default_server;
    server_name $NGINX_SERVER_NAMES;
    server_tokens off;

    ssl_certificate $CERTBOT_LIVE/fullchain.pem;
    ssl_certificate_key $CERTBOT_LIVE/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_timeout 1d;
    ssl_session_cache shared:TLS:10m;
    ssl_session_tickets off;

    root /var/www/html;
    index index.html;
    location / {
        try_files \$uri \$uri/ =404;
    }
}
NGINX
}

apply_nginx_config() {
  NGINX_CONFIG_CHANGED=false
  if ! cmp --silent "$NGINX_CONFIG_TEMP" "$NGINX_SITE_AVAILABLE" \
       2> /dev/null; then
    install -m 0644 "$NGINX_CONFIG_TEMP" "$NGINX_SITE_AVAILABLE"
    NGINX_CONFIG_CHANGED=true
  fi
  if [ "$(readlink "$NGINX_SITE_ENABLED" 2> /dev/null || true)" != \
       "$NGINX_SITE_AVAILABLE" ]; then
    ln -sfn "$NGINX_SITE_AVAILABLE" "$NGINX_SITE_ENABLED"
    NGINX_CONFIG_CHANGED=true
  fi
  if [ -e "$NGINX_DEFAULT_ENABLED" ] || [ -L "$NGINX_DEFAULT_ENABLED" ]; then
    rm -f "$NGINX_DEFAULT_ENABLED"
    NGINX_CONFIG_CHANGED=true
  fi

  nginx -t
  systemctl enable nginx
  if systemctl is-active --quiet nginx; then
    if [ "$NGINX_CONFIG_CHANGED" = true ]; then
      systemctl reload nginx
    fi
  else
    systemctl start nginx
  fi
}

# Renewal reloads are guarded by a full configuration test. The hook itself is
# part of the snapshot so failure later in this transaction restores its prior
# contents or absence.
install -d -m 0755 "$(dirname "$CERTBOT_DEPLOY_HOOK")"
cat > "$CERTBOT_DEPLOY_HOOK" <<'HOOK'
#!/usr/bin/env bash
set -Eeuo pipefail
nginx -t
systemctl reload nginx
HOOK
chmod 0755 "$CERTBOT_DEPLOY_HOOK"

systemctl enable --now certbot.timer
if ! certbot plugins --text | grep --quiet 'nginx'; then
  echo "The Certbot Nginx plugin is unavailable." >&2
  exit 1
fi

if [ -z "$CERTBOT_CERTIFICATE_NAME" ]; then
  # Private mode has no certificate lineage. Reconcile a single HTTP site.
  write_http_config
  apply_nginx_config
else
  # Avoid an HTTP-only intermediate reload during unchanged reprovisioning. A
  # challenge configuration is needed only before first issuance or when the
  # desired final site differs (for example, after changing domain names).
  write_https_config
  FINAL_SITE_ALREADY_ACTIVE=false
  if [ -f "$CERTBOT_LIVE/fullchain.pem" ] && \
     [ -f "$CERTBOT_LIVE/privkey.pem" ] && \
     cmp --silent "$NGINX_CONFIG_TEMP" "$NGINX_SITE_AVAILABLE" \
       2> /dev/null && \
     [ "$(readlink "$NGINX_SITE_ENABLED" 2> /dev/null || true)" = \
       "$NGINX_SITE_AVAILABLE" ] && \
     [ ! -e "$NGINX_DEFAULT_ENABLED" ] && \
     [ ! -L "$NGINX_DEFAULT_ENABLED" ]; then
    FINAL_SITE_ALREADY_ACTIVE=true
  fi
  if [ "$FINAL_SITE_ALREADY_ACTIVE" != true ]; then
    write_http_config
    apply_nginx_config
  fi

  DOMAIN_ARGUMENTS=()
  for DOMAIN in $NGINX_SERVER_NAMES; do
    DOMAIN_ARGUMENTS+=(--domain "$DOMAIN")
  done
  certbot certonly \
    --nginx \
    --non-interactive \
    --agree-tos \
    --email "$CERTBOT_EMAIL" \
    --cert-name "$CERTBOT_CERTIFICATE_NAME" \
    --keep-until-expiring \
    --renew-with-new-domains \
    "${DOMAIN_ARGUMENTS[@]}"

  if [ ! -f "$CERTBOT_LIVE/fullchain.pem" ] || \
     [ ! -f "$CERTBOT_LIVE/privkey.pem" ]; then
    echo "Certbot did not create the expected certificate lineage." >&2
    exit 1
  fi
  write_https_config
  apply_nginx_config
fi

# Probes are inside the transaction boundary. HTTP-only mode expects a usable
# response. Certificate mode verifies both the redirect and a TLS handshake for
# the configured DNS name using loopback, independent of external DNS caching.
systemctl is-active --quiet nginx
systemctl is-active --quiet certbot.timer
test -r "$NGINX_INDEX_FILE"
curl --fail --silent --show-error --head \
  --resolve "$NGINX_PROBE_SERVER_NAME:80:127.0.0.1" \
  "http://$NGINX_PROBE_SERVER_NAME/" > /dev/null
if [ -n "$CERTBOT_CERTIFICATE_NAME" ]; then
  curl --fail --silent --show-error --head \
    --resolve "$NGINX_PROBE_SERVER_NAME:443:127.0.0.1" \
    "https://$NGINX_PROBE_SERVER_NAME/" > /dev/null
fi

# Commit only after file validation, service state checks, and health probes.
TRANSACTION_ACTIVE=false
cleanup_transaction
trap - EXIT INT TERM HUP

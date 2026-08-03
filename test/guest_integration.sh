#!/usr/bin/env bash
set -Eeuo pipefail

# Read-only integration checks for a fully provisioned guest. Vagrant runs this
# script only when explicitly selected with `--provision-with integration-test`.
# It verifies live behavior without installing packages, editing configuration,
# restarting services, creating containers, or changing database contents.

for VARIABLE in \
  PRIVATE_NETWORK_IP PRIVATE_NETWORK_CIDR BRIDGED_ROUTE_METRIC \
  SHARED_ROUTE_METRIC TRUSTED_VPN_TUNNEL_INTERFACES \
  INOTIFY_MAX_USER_WATCHES INOTIFY_MAX_USER_INSTANCES \
  DOCKER_ENABLED DOCKER_DEFAULT_NOFILE_LIMIT \
  POSTGRESQL_ENABLED MONGODB_ENABLED \
  NGINX_ENABLED POSTGRESQL_MAJOR_VERSION POSTGRESQL_PACKAGE_VERSION \
  MONGODB_CONTAINER MONGODB_IMAGE MONGODB_VOLUME MONGODB_PORT \
  MONGODB_MANAGED_LABEL MONGODB_NOFILE_LIMIT \
  MONGODB_SECRETS_DIRECTORY NGINX_PROBE_SERVER_NAME \
  CERTBOT_CERTIFICATE_NAME; do
  : "${!VARIABLE?Integration input $VARIABLE is unset}"
done

for BOOLEAN_VARIABLE in \
  DOCKER_ENABLED POSTGRESQL_ENABLED MONGODB_ENABLED NGINX_ENABLED; do
  case "${!BOOLEAN_VARIABLE}" in
    true|false) ;;
    *)
      echo "$BOOLEAN_VARIABLE must be true or false." >&2
      exit 1
      ;;
  esac
done

pass() {
  printf 'PASS: %s\n' "$1"
}

interface_for_default_metric() {
  local metric="$1"
  ip -4 route show default | awk -v expected="$metric" '
    {
      interface = ""
      route_metric = "0"
      for (field_index = 1; field_index <= NF; field_index++) {
        if ($field_index == "dev") interface = $(field_index + 1)
        if ($field_index == "metric") route_metric = $(field_index + 1)
      }
      if (route_metric == expected && interface != "") print interface
    }
  ' | sort --unique
}

require_one_line() {
  local description="$1"
  local value="$2"
  if [ -z "$value" ] || [[ "$value" == *$'\n'* ]]; then
    echo "$description must resolve to exactly one value." >&2
    exit 1
  fi
}

ipv6_defaults_have_metric() {
  local interface="$1"
  local expected_metric="$2"
  local route
  while IFS= read -r route; do
    [ -n "$route" ] || continue
    case " $route " in
      *" metric $expected_metric "*) ;;
      *)
        echo "IPv6 default on $interface has the wrong metric: $route" >&2
        return 1
        ;;
    esac
  done < <(ip -6 route show default dev "$interface")
}

# Network roles must resolve from the declared private address and route metrics.
PRIVATE_INTERFACE="$(
  ip -o -4 address show | awk -v address="$PRIVATE_NETWORK_IP" \
    '$4 ~ ("^" address "/") { print $2 }'
)"
SHARED_INTERFACE="$(interface_for_default_metric "$SHARED_ROUTE_METRIC")"
BRIDGED_INTERFACE="$(interface_for_default_metric "$BRIDGED_ROUTE_METRIC")"
require_one_line "Private interface" "$PRIVATE_INTERFACE"
require_one_line "Shared interface" "$SHARED_INTERFACE"
require_one_line "Bridged interface" "$BRIDGED_INTERFACE"
if [ "$PRIVATE_INTERFACE" = "$SHARED_INTERFACE" ] || \
   [ "$PRIVATE_INTERFACE" = "$BRIDGED_INTERFACE" ] || \
   [ "$SHARED_INTERFACE" = "$BRIDGED_INTERFACE" ]; then
  echo "Network roles resolved to duplicate interfaces." >&2
  exit 1
fi
ip -4 route show default dev "$SHARED_INTERFACE" | \
  grep --quiet "metric $SHARED_ROUTE_METRIC"
ip -4 route show default dev "$BRIDGED_INTERFACE" | \
  grep --quiet "metric $BRIDGED_ROUTE_METRIC"
ipv6_defaults_have_metric "$SHARED_INTERFACE" "$SHARED_ROUTE_METRIC"
ipv6_defaults_have_metric "$BRIDGED_INTERFACE" "$BRIDGED_ROUTE_METRIC"
! ip -6 route show default dev "$PRIVATE_INTERFACE" | grep --quiet .
! ip -o -6 address show dev "$PRIVATE_INTERFACE" scope global | grep --quiet .
[ -f /etc/netplan/99-vagrant-network.yaml ]
[ ! -e /run/vagrant-network-rollback-state ]
pass "network roles and IPv4/IPv6 route policy"

# UFW must be active and expose the expected template-tagged policy.
UFW_STATUS="$(ufw status verbose)"
grep --quiet '^Status: active$' <<< "$UFW_STATUS"
grep --quiet 'Vagrant managed: Shared SSH' <<< "$UFW_STATUS"
grep --quiet 'Vagrant managed: private development' <<< "$UFW_STATUS"
grep --quiet 'Vagrant managed: trusted VPN tunnel' <<< "$UFW_STATUS"
read -r -a VPN_TUNNEL_INTERFACES <<< "$TRUSTED_VPN_TUNNEL_INTERFACES"
for VPN_INTERFACE in "${VPN_TUNNEL_INTERFACES[@]}"; do
  iptables --wait --check ufw-user-input \
    --in-interface "$VPN_INTERFACE" --jump ACCEPT
  ip6tables --wait --check ufw6-user-input \
    --in-interface "$VPN_INTERFACE" --jump ACCEPT
done
pass "UFW is active with physical-ingress and VPN-return policy"

# Provisioning must leave Ubuntu's automatic maintenance services restored.
systemctl is-active --quiet apt-daily.timer
systemctl is-active --quiet apt-daily-upgrade.timer
systemctl is-active --quiet unattended-upgrades.service
systemctl is-enabled --quiet unattended-upgrades.service
pass "automatic Ubuntu update services"

# File-watcher capacity must be active now and persist across guest boots. These
# are ceilings only; this check does not allocate hundreds of thousands of
# watches or disturb a running VS Code Remote session.
[ "$(sysctl --values fs.inotify.max_user_watches)" = \
  "$INOTIFY_MAX_USER_WATCHES" ]
[ "$(sysctl --values fs.inotify.max_user_instances)" = \
  "$INOTIFY_MAX_USER_INSTANCES" ]
grep --fixed-strings --line-regexp --quiet \
  "fs.inotify.max_user_watches=$INOTIFY_MAX_USER_WATCHES" \
  /etc/sysctl.d/90-vagrant-development-inotify.conf
grep --fixed-strings --line-regexp --quiet \
  "fs.inotify.max_user_instances=$INOTIFY_MAX_USER_INSTANCES" \
  /etc/sysctl.d/90-vagrant-development-inotify.conf
pass "persistent development file-watcher capacity"

# Root storage must use the supported LVM/filesystem model and have no unfinished
# growth transaction. Static tests separately assert the reserve algorithm.
ROOT_SOURCE="$(findmnt --noheadings --output SOURCE /)"
lvs "$ROOT_SOURCE" > /dev/null
case "$(findmnt --noheadings --output FSTYPE / | xargs)" in
  ext4|xfs) ;;
  *)
    echo "Root filesystem is outside the supported disk-growth model." >&2
    exit 1
    ;;
esac
[ ! -e /var/lib/vagrant/storage/root-vg-growth ]
pass "root LVM and disk-growth transaction state"

if [ "$DOCKER_ENABLED" = true ]; then
  systemctl is-active --quiet docker
  systemctl is-active --quiet vagrant-docker-ingress.service
  dockerd --validate --config-file=/etc/docker/daemon.json
  # Confirm that ad-hoc containers inherit enough descriptors for development
  # databases even when their creation command omits an explicit ulimit.
  python3 - "$DOCKER_DEFAULT_NOFILE_LIMIT" <<'PYTHON'
import json
import sys

with open("/etc/docker/daemon.json", encoding="utf-8") as daemon_file:
    daemon_config = json.load(daemon_file)

expected = int(sys.argv[1])
nofile = daemon_config["default-ulimits"]["nofile"]
assert nofile == {"Name": "nofile", "Soft": expected, "Hard": expected}
PYTHON
  docker info > /dev/null
  iptables --wait --check FORWARD --jump DOCKER-USER
  iptables --wait --check DOCKER-USER --jump VAGRANT-DOCKER-INGRESS
  iptables --wait --check VAGRANT-DOCKER-INGRESS \
    --in-interface "$PRIVATE_INTERFACE" --source "$PRIVATE_NETWORK_CIDR" --jump RETURN
  iptables --wait --check VAGRANT-DOCKER-INGRESS \
    --in-interface "$SHARED_INTERFACE" --jump DROP
  iptables --wait --check VAGRANT-DOCKER-INGRESS \
    --in-interface "$BRIDGED_INTERFACE" --jump DROP
  ip6tables --wait --check FORWARD --jump DOCKER-USER
  ip6tables --wait --check DOCKER-USER --jump VAGRANT-DOCKER-INGRESS
  ip6tables --wait --check VAGRANT-DOCKER-INGRESS \
    --in-interface "$SHARED_INTERFACE" --jump DROP
  ip6tables --wait --check VAGRANT-DOCKER-INGRESS \
    --in-interface "$BRIDGED_INTERFACE" --jump DROP
  pass "Docker daemon and independent ingress firewall"
fi

if [ "$POSTGRESQL_ENABLED" = true ]; then
  POSTGRESQL_PACKAGE="postgresql-$POSTGRESQL_MAJOR_VERSION"
  [ "$(dpkg-query --show --showformat='${Version}' "$POSTGRESQL_PACKAGE")" = \
    "$POSTGRESQL_PACKAGE_VERSION" ]
  TARGET_CLUSTER="$(
    pg_lsclusters --no-header | \
      awk -v major="$POSTGRESQL_MAJOR_VERSION" \
        '$1 == major && $2 == "main" { print $3, $4; exit }'
  )"
  read -r POSTGRESQL_PORT POSTGRESQL_STATUS <<< "$TARGET_CLUSTER"
  [ -n "${POSTGRESQL_PORT:-}" ]
  [ "$POSTGRESQL_STATUS" = online ]
  pg_isready --quiet --host /var/run/postgresql --port "$POSTGRESQL_PORT"
  pass "PostgreSQL package and online cluster"
fi

if [ "$MONGODB_ENABLED" = true ]; then
  [ "$(docker container inspect --format '{{.Config.Image}}' \
        "$MONGODB_CONTAINER")" = "$MONGODB_IMAGE" ]
  [ "$(docker container inspect --format '{{.State.Health.Status}}' \
        "$MONGODB_CONTAINER")" = healthy ]
  [ "$(docker container inspect \
        --format "{{index .Config.Labels \"$MONGODB_MANAGED_LABEL\"}}" \
        "$MONGODB_CONTAINER")" = true ]
  [ "$(docker volume inspect \
        --format "{{index .Labels \"$MONGODB_MANAGED_LABEL\"}}" \
        "$MONGODB_VOLUME")" = true ]
  [ "$(docker container port "$MONGODB_CONTAINER" 27017/tcp)" = \
    "$PRIVATE_NETWORK_IP:$MONGODB_PORT" ]
  [ "$(docker container inspect \
        --format '{{range .HostConfig.Ulimits}}{{if eq .Name "nofile"}}{{.Soft}}:{{.Hard}}{{end}}{{end}}' \
        "$MONGODB_CONTAINER")" = \
    "$MONGODB_NOFILE_LIMIT:$MONGODB_NOFILE_LIMIT" ]
  [ "$(docker exec "$MONGODB_CONTAINER" sh -c \
        'printf "%s:%s\n" "$(ulimit -Sn)" "$(ulimit -Hn)"')" = \
    "$MONGODB_NOFILE_LIMIT:$MONGODB_NOFILE_LIMIT" ]
  ! docker container inspect "${MONGODB_CONTAINER}-vagrant-rollback" \
    > /dev/null 2>&1
  docker exec "$MONGODB_CONTAINER" mongosh --quiet \
    --file /run/secrets/mongodb/verify.js
  [ -f "$MONGODB_SECRETS_DIRECTORY/.vagrant-managed" ]
  pass "MongoDB ownership, binding, health, and authenticated topology"
fi

if [ "$NGINX_ENABLED" = true ]; then
  nginx -t
  systemctl is-active --quiet nginx
  systemctl is-active --quiet certbot.timer
  curl --fail --silent --show-error --head \
    --resolve "$NGINX_PROBE_SERVER_NAME:80:127.0.0.1" \
    "http://$NGINX_PROBE_SERVER_NAME/" > /dev/null
  if [ -n "$CERTBOT_CERTIFICATE_NAME" ]; then
    curl --fail --silent --show-error --head \
      --resolve "$NGINX_PROBE_SERVER_NAME:443:127.0.0.1" \
      "https://$NGINX_PROBE_SERVER_NAME/" > /dev/null
  fi
  pass "Nginx configuration and local HTTP/TLS behavior"
fi

printf 'All enabled guest integration checks passed.\n'

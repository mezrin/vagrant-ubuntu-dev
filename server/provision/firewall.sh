#!/usr/bin/env bash
set -Eeuo pipefail

# Purpose: close a public development server to everything except SSH and an
# explicit list of public TCP ports. Runs as root.
# Inputs: SERVER_PUBLIC_TCP_PORTS, a space-separated list of extra TCP ports or
# ranges such as "80 443" or "15100:15105". It may be empty.
# Repeat behavior: UFW defaults and rules tagged "Server managed" converge to the
# inputs; untagged administrator rules are left intact.
# Development services are expected to listen on 127.0.0.1 and be reached
# through SSH port forwarding. Docker-published ports bypass UFW, so docker.sh's
# public-server ingress policy covers containers separately.

: "${SERVER_PUBLIC_TCP_PORTS?}"

echo "\n\n###\n### Configure the server firewall\n###\n"

# Allow every port sshd actually listens on, read from its effective
# configuration rather than assumed, so enabling UFW cannot cut off SSH.
mapfile -t SSH_PORTS < <(sshd -T | awk '$1 == "port" { print $2 }' | sort --unique)
if [ "${#SSH_PORTS[@]}" -eq 0 ]; then
  echo "Could not determine the sshd listening port." >&2
  exit 1
fi
read -r -a PUBLIC_PORTS <<< "$SERVER_PUBLIC_TCP_PORTS"
for PORT in "${PUBLIC_PORTS[@]}"; do
  if [[ ! "$PORT" =~ ^[0-9]+(:[0-9]+)?$ ]]; then
    echo "Invalid port or range in SERVER_PUBLIC_TCP_PORTS: $PORT" >&2
    exit 1
  fi
done

ufw default deny incoming
ufw default allow outgoing
ufw logging low

# Add the SSH rules before removing stale managed rules. Existing sessions are
# also kept by UFW's connection tracking, but there is never a window without an
# SSH allow rule while UFW is active.
for PORT in "${SSH_PORTS[@]}"; do
  ufw allow "$PORT/tcp" comment 'Server managed: SSH'
done

# Delete only stale template-owned rules, in descending numeric order so UFW's
# changing rule numbers stay valid.
mapfile -t DESIRED_RULES < <(
  for PORT in "${SSH_PORTS[@]}"; do printf '%s/tcp SSH\n' "$PORT"; done
  for PORT in "${PUBLIC_PORTS[@]}"; do printf '%s/tcp public\n' "$PORT"; done
)
while read -r RULE_NUMBER; do
  [ -n "$RULE_NUMBER" ] || continue
  ufw --force delete "$RULE_NUMBER"
done < <(
  ufw status numbered | awk -v desired="$(printf '%s\n' "${DESIRED_RULES[@]}")" '
    BEGIN { split(desired, lines, "\n"); for (i in lines) keep[lines[i]] = 1 }
    /# Server managed: / {
      number = $0; sub(/^\[ */, "", number); sub(/\].*/, "", number)
      port = $0; sub(/^\[ *[0-9]+\] */, "", port); sub(/ .*/, "", port)
      kind = $0; sub(/.*# Server managed: /, "", kind)
      if (!((port " " kind) in keep)) print number
    }
  ' | sort --numeric-sort --reverse
)

for PORT in "${PUBLIC_PORTS[@]}"; do
  ufw allow "$PORT/tcp" comment 'Server managed: public'
done

ufw --force enable
UFW_STATUS="$(ufw status verbose)"
printf '%s\n' "$UFW_STATUS"
if ! grep --quiet '^Status: active$' <<< "$UFW_STATUS" || \
   ! grep --quiet '^Default: deny (incoming), allow (outgoing)' <<< "$UFW_STATUS" || \
   ! grep --quiet 'Server managed: SSH' <<< "$UFW_STATUS"; then
  echo "UFW did not report the required server policy." >&2
  exit 1
fi

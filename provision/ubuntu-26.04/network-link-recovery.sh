#!/usr/bin/env bash
set -Eeuo pipefail

# Purpose: keep the template-owned Netplan configuration usable after
# Parallels Tools resets guest networking because a host link disappears and
# returns. Runs as root.
#
# Why this exists: prltoolsd uses umask 0077. Its `prl_nettool restart` invokes
# `netplan apply`, which can recreate /run/systemd/network/*.network as mode
# 0600. Ubuntu 26.04 runs systemd-networkd as `systemd-network`, so it cannot
# read those files and falls back to a generic DHCP configuration. Adapter 2
# then loses its stable host-only address and SSH/VS Code becomes unreachable.
#
# Repeat behavior: reconcile one helper and two systemd units, then verify the
# current runtime files. The path unit reacts to future Netplan regeneration;
# it does not poll. Parallels-owned files are never edited.

echo "\n\n###\n### Protect network configuration from Parallels link resets\n###\n"

RECOVERY_HELPER="/usr/local/sbin/vagrant-networkd-runtime-repair"
RECOVERY_SERVICE="vagrant-networkd-runtime-repair.service"
RECOVERY_PATH="vagrant-networkd-runtime-repair.path"
RECOVERY_SERVICE_FILE="/etc/systemd/system/$RECOVERY_SERVICE"
RECOVERY_PATH_FILE="/etc/systemd/system/$RECOVERY_PATH"
TEMP_DIRECTORY="$(mktemp --directory)"
trap 'rm -rf "$TEMP_DIRECTORY"' EXIT

cat > "$TEMP_DIRECTORY/recovery-helper" <<'RECOVERY_HELPER'
#!/usr/bin/env bash
set -Eeuo pipefail

# Netplan derives these stable names from the IDs in
# /etc/netplan/99-vagrant-network.yaml. Limit repairs to this explicit inventory
# so administrator-owned or future unrelated networkd files are untouched.
GENERATED_NETWORK_FILES=(
  /run/systemd/network/10-netplan-vagrant-shared.network
  /run/systemd/network/10-netplan-vagrant-private.network
  /run/systemd/network/10-netplan-vagrant-bridged.network
)
NETWORK_TRANSACTION_STATE="/run/vagrant-network-rollback-state"
LOCK_FILE="/run/lock/vagrant-networkd-runtime-repair.lock"

# Serialize boot-time execution and path events. A directory event can arrive
# once for each file that Netplan replaces during one regeneration.
exec 9> "$LOCK_FILE"
flock --exclusive 9

# The main network provisioner owns reconfiguration while its rollback marker
# exists. It applies and verifies the same files itself; racing it here could
# consume its safety snapshot or interfere with the Vagrant SSH transaction.
if [ -e "$NETWORK_TRANSACTION_STATE" ]; then
  exit 0
fi

# Coalesce Netplan's sequence of atomic file replacements. Then require every
# managed path to be a regular, non-symlink file before changing permissions.
sleep 2
for NETWORK_FILE in "${GENERATED_NETWORK_FILES[@]}"; do
  if [ ! -f "$NETWORK_FILE" ] || [ -L "$NETWORK_FILE" ]; then
    echo "Managed networkd runtime file is missing or unsafe: $NETWORK_FILE" >&2
    exit 1
  fi
done

REPAIR_REQUIRED=false
for NETWORK_FILE in "${GENERATED_NETWORK_FILES[@]}"; do
  read -r FILE_MODE FILE_OWNER FILE_GROUP < <(
    stat --format='%a %U %G' "$NETWORK_FILE"
  )
  if [ "$FILE_MODE" != 640 ] || [ "$FILE_OWNER" != root ] || \
     [ "$FILE_GROUP" != systemd-network ]; then
    REPAIR_REQUIRED=true
  fi
done
[ "$REPAIR_REQUIRED" = true ] || exit 0

# Netplan/networkd can remove dynamically installed policy rules while
# reconfiguring physical interfaces. Preserve non-built-in rules, including an
# active VPN's strict-route and leak-prevention policy, and restore them from
# parsed argument arrays rather than evaluating command text.
RULE_SNAPSHOT_DIRECTORY="$(mktemp --directory /run/vagrant-network-rules.XXXXXX)"
IPV4_POLICY_RULES="$RULE_SNAPSHOT_DIRECTORY/ipv4"
IPV6_POLICY_RULES="$RULE_SNAPSHOT_DIRECTORY/ipv6"
foreign_policy_rules() {
  local family="$1"
  ip -o "$family" rule show | awk -F: \
    '$1 + 0 != 0 && $1 + 0 != 32766 && $1 + 0 != 32767'
}
foreign_policy_rules -4 > "$IPV4_POLICY_RULES"
foreign_policy_rules -6 > "$IPV6_POLICY_RULES"
chmod 0600 "$IPV4_POLICY_RULES" "$IPV6_POLICY_RULES"

restore_foreign_policy_rules() {
  local family="$1"
  local source="$2"
  local priority rule
  local -a priorities rule_spec

  mapfile -t priorities < <(
    awk -F: '{ gsub(/[[:space:]]/, "", $1); print $1 }' "$source" | sort -nu
  )
  for priority in "${priorities[@]}"; do
    while ip "$family" rule show priority "$priority" | grep --quiet .; do
      ip "$family" rule del priority "$priority"
    done
  done
  while IFS= read -r rule; do
    [ -n "$rule" ] || continue
    priority="${rule%%:*}"
    priority="${priority//[[:space:]]/}"
    read -r -a rule_spec <<< "${rule#*:}"
    ip "$family" rule add priority "$priority" "${rule_spec[@]}"
  done < "$source"
}

# Always replay the snapshot, including when reload/reconfigure fails partway.
# This cleanup is best-effort so it never hides the original service failure.
restore_rules_on_exit() {
  local original_status=$?
  trap - EXIT
  restore_foreign_policy_rules -4 "$IPV4_POLICY_RULES" || true
  restore_foreign_policy_rules -6 "$IPV6_POLICY_RULES" || true
  rm -rf "$RULE_SNAPSHOT_DIRECTORY"
  exit "$original_status"
}
trap restore_rules_on_exit EXIT

chown root:systemd-network "${GENERATED_NETWORK_FILES[@]}"
chmod 0640 "${GENERATED_NETWORK_FILES[@]}"

# Resolve only real virtual NICs. Software interfaces such as Docker bridges and
# VPN tunnels have no device path and must remain under their owning software.
mapfile -t PHYSICAL_INTERFACES < <(
  for INTERFACE_PATH in /sys/class/net/*; do
    [ -e "$INTERFACE_PATH/device" ] || continue
    basename "$INTERFACE_PATH"
  done | sort
)
if [ "${#PHYSICAL_INTERFACES[@]}" -ne 3 ]; then
  echo "Expected three physical interfaces, found ${#PHYSICAL_INTERFACES[@]}." >&2
  exit 1
fi

networkctl reload
networkctl reconfigure "${PHYSICAL_INTERFACES[@]}"

# Map Adapter 2 from the MAC and address in its generated file. Verify that the
# stable address returns before declaring the asynchronous recovery successful.
PRIVATE_NETWORK_FILE="/run/systemd/network/10-netplan-vagrant-private.network"
PRIVATE_MAC="$(sed -n 's/^PermanentMACAddress=//p' "$PRIVATE_NETWORK_FILE")"
PRIVATE_ADDRESS_CIDR="$(sed -n 's/^Address=//p' "$PRIVATE_NETWORK_FILE")"
if [ -z "$PRIVATE_MAC" ] || [ -z "$PRIVATE_ADDRESS_CIDR" ] || \
   [[ "$PRIVATE_MAC" == *$'\n'* ]] || [[ "$PRIVATE_ADDRESS_CIDR" == *$'\n'* ]]; then
  echo "Cannot resolve the managed private interface configuration." >&2
  exit 1
fi
PRIVATE_INTERFACE=""
for INTERFACE in "${PHYSICAL_INTERFACES[@]}"; do
  if [ "$(tr '[:upper:]' '[:lower:]' < "/sys/class/net/$INTERFACE/address")" = \
       "${PRIVATE_MAC,,}" ]; then
    PRIVATE_INTERFACE="$INTERFACE"
    break
  fi
done
if [ -z "$PRIVATE_INTERFACE" ]; then
  echo "Cannot map the managed private MAC to a physical interface." >&2
  exit 1
fi

PRIVATE_ADDRESS="${PRIVATE_ADDRESS_CIDR%/*}"
for _ in $(seq 1 30); do
  if ip -o -4 address show dev "$PRIVATE_INTERFACE" | \
       grep --quiet " $PRIVATE_ADDRESS/"; then
    exit 0
  fi
  sleep 1
done
echo "The host-only address did not return after networkd reconfiguration." >&2
ip -brief address >&2
exit 1
RECOVERY_HELPER

cat > "$TEMP_DIRECTORY/$RECOVERY_SERVICE" <<UNIT
[Unit]
Description=Repair Vagrant networkd files after a Parallels network reset
Documentation=file://$RECOVERY_HELPER
After=systemd-networkd.service
Wants=systemd-networkd.service
ConditionPathExists=/etc/netplan/99-vagrant-network.yaml

[Service]
Type=oneshot
ExecStart=$RECOVERY_HELPER
NoNewPrivileges=yes
ProtectHome=yes
ProtectSystem=full

[Install]
WantedBy=multi-user.target
UNIT

cat > "$TEMP_DIRECTORY/$RECOVERY_PATH" <<UNIT
[Unit]
Description=Watch Netplan runtime files for Parallels regeneration
After=systemd-networkd.service

[Path]
PathChanged=/run/systemd/network
Unit=$RECOVERY_SERVICE

[Install]
WantedBy=multi-user.target
UNIT

# Install the helper first so systemd-analyze can resolve ExecStart, then
# validate both candidate units before replacing live unit definitions.
install -o root -g root -m 0755 "$TEMP_DIRECTORY/recovery-helper" \
  "$RECOVERY_HELPER"
if ! SYSTEMD_VERIFY_OUTPUT="$(
  systemd-analyze verify \
    "$TEMP_DIRECTORY/$RECOVERY_SERVICE" "$TEMP_DIRECTORY/$RECOVERY_PATH" 2>&1
)"; then
  printf '%s\n' "$SYSTEMD_VERIFY_OUTPUT" >&2
  exit 1
fi
install -o root -g root -m 0644 "$TEMP_DIRECTORY/$RECOVERY_SERVICE" \
  "$RECOVERY_SERVICE_FILE"
install -o root -g root -m 0644 "$TEMP_DIRECTORY/$RECOVERY_PATH" \
  "$RECOVERY_PATH_FILE"

systemctl daemon-reload
systemctl enable "$RECOVERY_SERVICE" "$RECOVERY_PATH"
systemctl start "$RECOVERY_PATH"
systemctl start "$RECOVERY_SERVICE"
systemctl is-enabled --quiet "$RECOVERY_SERVICE" "$RECOVERY_PATH"
systemctl is-active --quiet "$RECOVERY_PATH"
! systemctl is-failed --quiet "$RECOVERY_SERVICE"

rm -rf "$TEMP_DIRECTORY"
trap - EXIT

echo "Parallels-triggered Netplan regeneration is monitored by $RECOVERY_PATH."

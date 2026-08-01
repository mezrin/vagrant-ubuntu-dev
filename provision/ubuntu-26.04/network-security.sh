#!/usr/bin/env bash
set -Eeuo pipefail

# Purpose: declaratively reconcile the guest's three NICs, IPv4/IPv6 route
# priority, and interface-scoped UFW rules. Runs as root on every Vagrant
# up/reload.
# Inputs: private address/CIDR, route metrics, Nginx exposure flag, allowed
# host-only TCP ports, and trusted VPN tunnel interface names. See README.md for
# the full traffic model.
# Safety model: identify adapters from live facts, take a per-run snapshot of
# Netplan and UFW, schedule an automatic rollback, apply, then cancel rollback
# only after address, route, and firewall checks pass. Manual Netplan and
# template-tagged UFW edits are not durable; unrelated UFW rules remain owned by
# their administrator.

# Every network input must exist and be non-empty before any live state changes.
: "${PRIVATE_NETWORK_IP:?}"
: "${PRIVATE_NETWORK_CIDR:?}"
: "${BRIDGED_ROUTE_METRIC:?}"
: "${SHARED_ROUTE_METRIC:?}"
: "${NGINX_BRIDGED_INGRESS:?}"
: "${PRIVATE_NETWORK_TCP_PORTS:?}"
: "${TRUSTED_VPN_TUNNEL_INTERFACES:?}"

# Linux interface names are at most 15 characters. Validate the explicit trust
# list before taking a snapshot or mutating live network state; spaces separate
# names and therefore cannot be part of an interface name.
read -r -a VPN_TUNNEL_INTERFACES <<< "$TRUSTED_VPN_TUNNEL_INTERFACES"
if [ "${#VPN_TUNNEL_INTERFACES[@]}" -eq 0 ]; then
  echo "At least one trusted VPN tunnel interface is required." >&2
  exit 1
fi
for VPN_INTERFACE in "${VPN_TUNNEL_INTERFACES[@]}"; do
  if [[ ! "$VPN_INTERFACE" =~ ^[[:alnum:]][[:alnum:]_.-]{0,14}$ ]]; then
    echo "Invalid trusted VPN tunnel interface: $VPN_INTERFACE" >&2
    exit 1
  fi
done

# The managed file is the only Netplan YAML source left after a successful run.
# Each attempt gets an exact, short-lived snapshot of the immediately preceding
# state instead of reusing a stale provider backup from an older run.
NETPLAN_CONFIG="/etc/netplan/99-vagrant-network.yaml"
NETWORK_TRANSACTION_ROOT="/var/lib/vagrant/network-transactions"
ROLLBACK_STATE="/run/vagrant-network-rollback-state"
ROLLBACK_SCRIPT="/usr/local/sbin/vagrant-network-rollback"
NETWORKMANAGER_UNMANAGED_CONFIG="/etc/NetworkManager/conf.d/90-vagrant-physical-interfaces-unmanaged.conf"
SHARED_RA_DROPIN="/etc/systemd/network/10-netplan-vagrant-shared.network.d/50-vagrant-ra-route-metric.conf"
BRIDGED_RA_DROPIN="/etc/systemd/network/10-netplan-vagrant-bridged.network.d/50-vagrant-ra-route-metric.conf"
PRIVATE_NETWORK_PREFIX="${PRIVATE_NETWORK_CIDR#*/}"

# Ignore loopback and software-only devices. Parallels NICs have a device entry
# under sysfs; exactly three are required so adapter roles are unambiguous.
mapfile -t PHYSICAL_INTERFACES < <(
  for INTERFACE_PATH in /sys/class/net/*; do
    [ -e "$INTERFACE_PATH/device" ] || continue
    INTERFACE="${INTERFACE_PATH##*/}"
    printf '%s\n' "$INTERFACE"
  done | sort
)

if [ "${#PHYSICAL_INTERFACES[@]}" -ne 3 ]; then
  echo "Expected exactly three physical network interfaces, found ${#PHYSICAL_INTERFACES[@]}." >&2
  printf 'Detected interface: %s\n' "${PHYSICAL_INTERFACES[@]}" >&2
  exit 1
fi

# Adapter 2 is the interface on which Vagrant already assigned the configured
# static host-only address.
PRIVATE_INTERFACE="$(
  ip -o -4 address show | awk -v address="$PRIVATE_NETWORK_IP" \
    '$4 ~ ("^" address "/") { print $2; exit }'
)"
if [ -z "$PRIVATE_INTERFACE" ]; then
  echo "No interface has the configured private address $PRIVATE_NETWORK_IP." >&2
  exit 1
fi

# Vagrant provisions over SSH through Adapter 1. An unprivileged SSH shell has
# SSH_CONNECTION, but Vagrant's privileged shell may intentionally discard it
# while invoking sudo. In that case walk this process's parents to the owning
# sshd-session and read that session's IPv4 endpoints from the kernel socket
# table. Matching the process ancestry avoids selecting an engineer's concurrent
# VSCode/SSH connection. This keeps the role detection independent of interface
# names and of Parallels' configurable Shared-network address range.
if [ -n "${SSH_CONNECTION:-}" ]; then
  read -r SSH_CLIENT_IP _ SSH_SERVER_IP _ <<< "$SSH_CONNECTION"
else
  CURRENT_PID=$$
  SSH_ENDPOINTS=""
  while [ "$CURRENT_PID" -gt 1 ]; do
    SSH_ENDPOINTS="$(
      ss -H -4 -n -t -p state established '( sport = :22 )' | \
        awk -v marker="pid=$CURRENT_PID," \
          'index($0, marker) { print $4, $3; exit }'
    )"
    [ -z "$SSH_ENDPOINTS" ] || break
    CURRENT_PID="$(
      sed -n 's/^PPid:[[:space:]]*//p' "/proc/$CURRENT_PID/status"
    )"
    if [[ ! "$CURRENT_PID" =~ ^[0-9]+$ ]]; then
      break
    fi
  done
  if [ -z "$SSH_ENDPOINTS" ]; then
    echo "Cannot identify the Vagrant SSH session from process ancestry." >&2
    exit 1
  fi
  read -r SSH_CLIENT_ENDPOINT SSH_SERVER_ENDPOINT <<< "$SSH_ENDPOINTS"
  SSH_CLIENT_IP="${SSH_CLIENT_ENDPOINT%:*}"
  SSH_SERVER_IP="${SSH_SERVER_ENDPOINT%:*}"
fi
SHARED_INTERFACE="$(
  ip -o -4 address show | awk -v address="$SSH_SERVER_IP" \
    '$4 ~ ("^" address "/") { print $2; exit }'
)"
if [ -z "$SHARED_INTERFACE" ]; then
  echo "No interface owns the Vagrant SSH server address $SSH_SERVER_IP." >&2
  exit 1
fi

# With Shared and Host-only identified, the single remaining NIC is Adapter 3,
# the bridged Wi-Fi interface.
mapfile -t BRIDGED_INTERFACES < <(
  printf '%s\n' "${PHYSICAL_INTERFACES[@]}" | \
    awk -v shared="$SHARED_INTERFACE" -v private="$PRIVATE_INTERFACE" \
      '$0 != shared && $0 != private'
)
if [ "${#BRIDGED_INTERFACES[@]}" -ne 1 ]; then
  echo "Cannot identify exactly one Bridged adapter." >&2
  exit 1
fi
BRIDGED_INTERFACE="${BRIDGED_INTERFACES[0]}"

# Netplan matches MAC addresses because kernel interface names can change across
# box or provider versions. Duplicate MACs would make those matches unsafe.
interface_mac() {
  tr '[:upper:]' '[:lower:]' < "/sys/class/net/$1/address"
}
SHARED_MAC="$(interface_mac "$SHARED_INTERFACE")"
PRIVATE_MAC="$(interface_mac "$PRIVATE_INTERFACE")"
BRIDGED_MAC="$(interface_mac "$BRIDGED_INTERFACE")"
if [ "$SHARED_MAC" = "$PRIVATE_MAC" ] || \
   [ "$SHARED_MAC" = "$BRIDGED_MAC" ] || \
   [ "$PRIVATE_MAC" = "$BRIDGED_MAC" ]; then
  echo "Network adapter MAC addresses must be unique." >&2
  exit 1
fi

# Install a persistent recovery helper before opening a transaction. It accepts
# only transaction paths created below, which prevents a corrupted state file
# from turning its cleanup operations toward an arbitrary directory.
cat > "$ROLLBACK_SCRIPT" <<'ROLLBACK'
#!/usr/bin/env bash
set -Eeuo pipefail

# This helper may run from the main script's EXIT trap, a transient systemd
# timer after SSH loss, or an engineer's recovery shell. A successful run
# removes the state file, making a late invocation a no-op.
STATE_FILE="/run/vagrant-network-rollback-state"
TRANSACTION_ROOT="/var/lib/vagrant/network-transactions"
[ -e "$STATE_FILE" ] || exit 0
if ! read -r TRANSACTION_DIRECTORY EXTRA_STATE < "$STATE_FILE" || \
   [ -n "${EXTRA_STATE:-}" ]; then
  echo "Network rollback state is invalid: $STATE_FILE" >&2
  exit 1
fi
if [ "$(dirname "$TRANSACTION_DIRECTORY")" != "$TRANSACTION_ROOT" ] || \
   [[ "$(basename "$TRANSACTION_DIRECTORY")" != transaction.* ]] || \
   [ -L "$TRANSACTION_DIRECTORY" ]; then
  echo "Network rollback path is outside its managed root." >&2
  exit 1
fi
NETPLAN_SNAPSHOT="$TRANSACTION_DIRECTORY/netplan"
NETWORKD_SNAPSHOT="$TRANSACTION_DIRECTORY/networkd"
NETWORKMANAGER_SNAPSHOT="$TRANSACTION_DIRECTORY/networkmanager"
UFW_SNAPSHOT="$TRANSACTION_DIRECTORY/ufw"
UFW_STATE="$TRANSACTION_DIRECTORY/ufw-state"
NETWORKMANAGER_UNMANAGED_CONFIG="/etc/NetworkManager/conf.d/90-vagrant-physical-interfaces-unmanaged.conf"
SHARED_RA_DROPIN="/etc/systemd/network/10-netplan-vagrant-shared.network.d/50-vagrant-ra-route-metric.conf"
BRIDGED_RA_DROPIN="/etc/systemd/network/10-netplan-vagrant-bridged.network.d/50-vagrant-ra-route-metric.conf"
if [ ! -d "$NETPLAN_SNAPSHOT" ] || [ ! -d "$NETWORKD_SNAPSHOT" ] || \
   [ ! -d "$NETWORKMANAGER_SNAPSHOT" ] || [ ! -d "$UFW_SNAPSHOT" ] || \
   [ ! -f "$UFW_STATE" ]; then
  echo "Network rollback snapshot is incomplete." >&2
  exit 1
fi

# Restore the exact preceding YAML set and UFW configuration. Netplan is applied
# before UFW so management routing exists when the prior firewall is reloaded.
find /etc/netplan -maxdepth 1 -type f -name '*.yaml' -delete
while IFS= read -r -d '' CONFIG_FILE; do
  cp -a -- "$CONFIG_FILE" "/etc/netplan/$(basename "$CONFIG_FILE")"
done < <(find "$NETPLAN_SNAPSHOT" -maxdepth 1 -type f -name '*.yaml' -print0)

# Netplan 1.2 in Ubuntu 26.04 cannot express Router Advertisement metrics.
# Restore the two template-owned systemd-networkd drop-ins that supplement the
# YAML, without touching any other administrator-owned networkd configuration.
for MANAGED_DROPIN in "$SHARED_RA_DROPIN" "$BRIDGED_RA_DROPIN"; do
  rm -f -- "$MANAGED_DROPIN"
  DROPIN_SNAPSHOT="$NETWORKD_SNAPSHOT$MANAGED_DROPIN"
  if [ -f "$DROPIN_SNAPSHOT" ]; then
    install -d -m 0755 "$(dirname "$MANAGED_DROPIN")"
    cp -a -- "$DROPIN_SNAPSHOT" "$MANAGED_DROPIN"
  else
    rmdir --ignore-fail-on-non-empty "$(dirname "$MANAGED_DROPIN")" \
      2> /dev/null || true
  fi
done

# Restore whether NetworkManager managed the three physical adapters before
# this transaction. NetworkManager itself remains running so VPN/tunnel devices
# and its desktop UI continue to work.
rm -f -- "$NETWORKMANAGER_UNMANAGED_CONFIG"
if [ -f "$NETWORKMANAGER_SNAPSHOT/unmanaged.conf" ]; then
  install -d -m 0755 "$(dirname "$NETWORKMANAGER_UNMANAGED_CONFIG")"
  cp -a -- "$NETWORKMANAGER_SNAPSHOT/unmanaged.conf" \
    "$NETWORKMANAGER_UNMANAGED_CONFIG"
fi
if command -v nmcli > /dev/null 2>&1 && \
   systemctl is-active --quiet NetworkManager; then
  nmcli general reload conf
fi

find /etc/ufw -mindepth 1 -depth -delete
cp -a -- "$UFW_SNAPSHOT/." /etc/ufw/

netplan generate
netplan apply
if grep --quiet '^active$' "$UFW_STATE"; then
  ufw --force enable
  ufw reload
else
  ufw --force disable
fi

rm -f "$STATE_FILE"
find "$TRANSACTION_DIRECTORY" -depth -delete
ROLLBACK
chmod 0755 "$ROLLBACK_SCRIPT"

# Snapshot the exact live files for this attempt. Including the current managed
# YAML makes repeated runs roll back one step, not all the way to a potentially
# obsolete box/provider configuration. The UFW snapshot includes administrator
# rules because template rules share the same generated files.
install -d -m 0700 "$NETWORK_TRANSACTION_ROOT"
TRANSACTION_DIRECTORY="$(mktemp -d "$NETWORK_TRANSACTION_ROOT/transaction.XXXXXX")"
NETPLAN_SNAPSHOT="$TRANSACTION_DIRECTORY/netplan"
NETWORKD_SNAPSHOT="$TRANSACTION_DIRECTORY/networkd"
NETWORKMANAGER_SNAPSHOT="$TRANSACTION_DIRECTORY/networkmanager"
UFW_SNAPSHOT="$TRANSACTION_DIRECTORY/ufw"
install -d -m 0700 "$NETPLAN_SNAPSHOT"
install -d -m 0700 "$NETWORKD_SNAPSHOT"
install -d -m 0700 "$NETWORKMANAGER_SNAPSHOT"
while IFS= read -r -d '' CONFIG_FILE; do
  cp -a -- "$CONFIG_FILE" "$NETPLAN_SNAPSHOT/$(basename "$CONFIG_FILE")"
done < <(find /etc/netplan -maxdepth 1 -type f -name '*.yaml' -print0)
for MANAGED_DROPIN in "$SHARED_RA_DROPIN" "$BRIDGED_RA_DROPIN"; do
  if [ -e "$MANAGED_DROPIN" ] || [ -L "$MANAGED_DROPIN" ]; then
    if [ ! -f "$MANAGED_DROPIN" ] || [ -L "$MANAGED_DROPIN" ]; then
      echo "Managed networkd drop-in is not a regular file: $MANAGED_DROPIN" >&2
      exit 1
    fi
    DROPIN_SNAPSHOT="$NETWORKD_SNAPSHOT$MANAGED_DROPIN"
    install -d -m 0700 "$(dirname "$DROPIN_SNAPSHOT")"
    cp -a -- "$MANAGED_DROPIN" "$DROPIN_SNAPSHOT"
  fi
done
if [ -e "$NETWORKMANAGER_UNMANAGED_CONFIG" ] || \
   [ -L "$NETWORKMANAGER_UNMANAGED_CONFIG" ]; then
  if [ ! -f "$NETWORKMANAGER_UNMANAGED_CONFIG" ] || \
     [ -L "$NETWORKMANAGER_UNMANAGED_CONFIG" ]; then
    echo "Managed NetworkManager config is not a regular file: $NETWORKMANAGER_UNMANAGED_CONFIG" >&2
    exit 1
  fi
  cp -a -- "$NETWORKMANAGER_UNMANAGED_CONFIG" \
    "$NETWORKMANAGER_SNAPSHOT/unmanaged.conf"
fi
cp -a -- /etc/ufw "$UFW_SNAPSHOT"
UFW_STATUS_BEFORE="$(ufw status)"
if grep --quiet '^Status: active$' <<< "$UFW_STATUS_BEFORE"; then
  printf 'active\n' > "$TRANSACTION_DIRECTORY/ufw-state"
else
  printf 'inactive\n' > "$TRANSACTION_DIRECTORY/ufw-state"
fi
chmod 0600 "$TRANSACTION_DIRECTORY/ufw-state"

# Write rollback state atomically, then arm the out-of-band timer before the
# first live Netplan/UFW mutation. The timer remains armed through firewall
# verification, closing the previous gap where an UFW failure could strand SSH.
ROLLBACK_STATE_TEMP="$(mktemp /run/.vagrant-network-rollback-state.XXXXXX)"
printf '%s\n' "$TRANSACTION_DIRECTORY" > "$ROLLBACK_STATE_TEMP"
chmod 0600 "$ROLLBACK_STATE_TEMP"
mv "$ROLLBACK_STATE_TEMP" "$ROLLBACK_STATE"
ROLLBACK_UNIT="vagrant-network-rollback-$$"
# If any later command or signal fails, cancel the timer, restore the exact
# snapshot immediately, and return the original failure status to Vagrant.
rollback_on_exit() {
  local original_status=$?
  trap - EXIT INT TERM HUP
  systemctl stop "${ROLLBACK_UNIT}.timer" "${ROLLBACK_UNIT}.service" \
    > /dev/null 2>&1 || true
  "$ROLLBACK_SCRIPT" || true
  exit "$original_status"
}
trap rollback_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
systemd-run --quiet --unit="$ROLLBACK_UNIT" --on-active=90s "$ROLLBACK_SCRIPT"

# Remove every other YAML file to prevent cloud-init or provider definitions from
# reintroducing addresses and routes that conflict with this declared topology.
find /etc/netplan -maxdepth 1 -type f -name '*.yaml' \
  ! -name "$(basename "$NETPLAN_CONFIG")" -delete

NETPLAN_CANDIDATE="$TRANSACTION_DIRECTORY/$(basename "$NETPLAN_CONFIG")"
cat > "$NETPLAN_CANDIDATE" <<NETPLAN
network:
  version: 2
  renderer: networkd
  ethernets:
    vagrant-shared:
      match:
        macaddress: "$SHARED_MAC"
      dhcp4: true
      dhcp6: true
      accept-ra: true
      dhcp4-overrides:
        route-metric: $SHARED_ROUTE_METRIC
      dhcp6-overrides:
        route-metric: $SHARED_ROUTE_METRIC
      optional-addresses:
        - dhcp6
    vagrant-private:
      match:
        macaddress: "$PRIVATE_MAC"
      addresses:
        - "$PRIVATE_NETWORK_IP/$PRIVATE_NETWORK_PREFIX"
      dhcp6: false
      accept-ra: false
      link-local: []
    vagrant-bridged:
      match:
        macaddress: "$BRIDGED_MAC"
      dhcp4: true
      dhcp6: true
      accept-ra: true
      dhcp4-overrides:
        route-metric: $BRIDGED_ROUTE_METRIC
      dhcp6-overrides:
        route-metric: $BRIDGED_ROUTE_METRIC
      optional-addresses:
        - dhcp6
      optional: true
NETPLAN
install -m 0600 "$NETPLAN_CANDIDATE" "$NETPLAN_CONFIG"

# Ubuntu 26.04's Netplan supports DHCPv6 route metrics but not the equivalent
# Router Advertisement setting. Its systemd-networkd backend does support
# [IPv6AcceptRA] RouteMetric, so install narrowly scoped drop-ins for Netplan's
# two generated .network units. Together, the YAML and these files give IPv4,
# DHCPv6, and RA-learned routes the same per-interface preference.
SHARED_RA_CANDIDATE="$TRANSACTION_DIRECTORY/shared-ra-route-metric.conf"
BRIDGED_RA_CANDIDATE="$TRANSACTION_DIRECTORY/bridged-ra-route-metric.conf"
cat > "$SHARED_RA_CANDIDATE" <<NETWORKD
# Managed by Vagrantfile; manual edits are overwritten.
[IPv6AcceptRA]
RouteMetric=$SHARED_ROUTE_METRIC
NETWORKD
cat > "$BRIDGED_RA_CANDIDATE" <<NETWORKD
# Managed by Vagrantfile; manual edits are overwritten.
[IPv6AcceptRA]
RouteMetric=$BRIDGED_ROUTE_METRIC
NETWORKD
install -d -m 0755 "$(dirname "$SHARED_RA_DROPIN")" \
  "$(dirname "$BRIDGED_RA_DROPIN")"
install -m 0644 "$SHARED_RA_CANDIDATE" "$SHARED_RA_DROPIN"
install -m 0644 "$BRIDGED_RA_CANDIDATE" "$BRIDGED_RA_DROPIN"

# Installing the desktop starts NetworkManager alongside the box's original
# systemd-networkd. Two managers on one NIC produce duplicate DHCP leases,
# addresses, and routes. Keep networkd as the sole owner of the three physical
# adapters, while leaving NetworkManager available for VPN and tunnel devices.
NETWORKMANAGER_CANDIDATE="$TRANSACTION_DIRECTORY/networkmanager-unmanaged.conf"
cat > "$NETWORKMANAGER_CANDIDATE" <<NETWORKMANAGER
# Managed by Vagrantfile; manual edits are overwritten.
[keyfile]
unmanaged-devices=mac:$SHARED_MAC;mac:$PRIVATE_MAC;mac:$BRIDGED_MAC
NETWORKMANAGER
install -d -m 0755 "$(dirname "$NETWORKMANAGER_UNMANAGED_CONFIG")"
install -m 0644 "$NETWORKMANAGER_CANDIDATE" \
  "$NETWORKMANAGER_UNMANAGED_CONFIG"
nmcli general reload conf
for _ in $(seq 1 30); do
  if nmcli --get-values GENERAL.STATE device show "$SHARED_INTERFACE" | \
       grep --quiet '(unmanaged)' && \
     nmcli --get-values GENERAL.STATE device show "$PRIVATE_INTERFACE" | \
       grep --quiet '(unmanaged)' && \
     nmcli --get-values GENERAL.STATE device show "$BRIDGED_INTERFACE" | \
       grep --quiet '(unmanaged)'; then
    break
  fi
  sleep 1
done
for INTERFACE in "$SHARED_INTERFACE" "$PRIVATE_INTERFACE" \
  "$BRIDGED_INTERFACE"; do
  if ! nmcli --get-values GENERAL.STATE device show "$INTERFACE" | \
       grep --quiet '(unmanaged)'; then
    echo "NetworkManager did not release physical interface $INTERFACE." >&2
    exit 1
  fi
done

# Validate YAML before changing the live network. The transient systemd timer is
# an out-of-band recovery path if netplan apply breaks the provisioning SSH
# connection before Bash can run its normal ERR trap.
netplan generate
netplan apply

# A network does not have to provide IPv6. If it does advertise an IPv6 default
# route, however, it must have the same priority as that interface's IPv4 route.
ipv6_default_routes_have_metric() {
  local interface="$1"
  local expected_metric="$2"
  local route

  while IFS= read -r route; do
    [ -n "$route" ] || continue
    case " $route " in
      *" metric $expected_metric "*) ;;
      *) return 1 ;;
    esac
  done < <(ip -6 route show default dev "$interface")
}

# Confirm all invariants that matter to continued operation: private address,
# management SSH route, preferred/fallback IPv4 routes, equivalent IPv6 route
# metrics when IPv6 is available, and no IPv6 route on the host-only adapter.
network_ready=false
for _ in $(seq 1 30); do
  if ip -o -4 address show dev "$PRIVATE_INTERFACE" | \
       grep --quiet " $PRIVATE_NETWORK_IP/" && \
     ip -4 route get "$SSH_CLIENT_IP" | \
       grep --quiet "dev $SHARED_INTERFACE" && \
     ip -4 route show default dev "$SHARED_INTERFACE" | \
       grep --quiet "metric $SHARED_ROUTE_METRIC" && \
     ip -4 route show default dev "$BRIDGED_INTERFACE" | \
       grep --quiet "metric $BRIDGED_ROUTE_METRIC" && \
     ipv6_default_routes_have_metric \
       "$SHARED_INTERFACE" "$SHARED_ROUTE_METRIC" && \
     ipv6_default_routes_have_metric \
       "$BRIDGED_INTERFACE" "$BRIDGED_ROUTE_METRIC" && \
     ! ip -6 route show default dev "$PRIVATE_INTERFACE" | grep --quiet . && \
     ! ip -o -6 address show dev "$PRIVATE_INTERFACE" scope global | grep --quiet .; then
    network_ready=true
    break
  fi
  sleep 1
done
if [ "$network_ready" != true ]; then
  echo "The reconciled network did not become ready within 30 seconds." >&2
  ip -brief address >&2
  ip -4 route >&2
  ip -6 route >&2
  exit 1
fi

# Reconcile only firewall rules tagged as template-owned. Unrelated administrator
# rules remain intact. Descending deletion keeps UFW's changing rule numbers safe.
ufw default deny incoming
ufw default allow outgoing
ufw logging low

# Delete only rules owned by this template, in descending numeric order so a
# changed interface or port list cannot leave stale access behind.
while read -r RULE_NUMBER; do
  [ -n "$RULE_NUMBER" ] || continue
  ufw --force delete "$RULE_NUMBER"
done < <(
  ufw status numbered | sed -n \
    '/# Vagrant \(managed:\|management SSH\|host-only development\)/s/^\[[[:space:]]*\([0-9][0-9]*\)\].*/\1/p' | \
    sort --numeric-sort --reverse
)

ufw allow in on "$SHARED_INTERFACE" to any port 22 proto tcp \
  comment 'Vagrant managed: Shared SSH'
read -r -a PRIVATE_PORTS <<< "$PRIVATE_NETWORK_TCP_PORTS"
for PORT in "${PRIVATE_PORTS[@]}"; do
  ufw allow in on "$PRIVATE_INTERFACE" from "$PRIVATE_NETWORK_CIDR" \
    to any port "$PORT" proto tcp comment 'Vagrant managed: private development'
done

# A full-tunnel client reads packets from a TUN device and writes decrypted
# replies back through that same device. The kernel treats those replies as
# inbound packets; with UFW's default-deny policy they are dropped even though
# the VPN route and remote connection are healthy. Trust every protocol on only
# the explicitly configured local tunnel devices. This does not open Shared,
# Host-only, or Bridged ingress, and the rules are valid before a device exists.
for VPN_INTERFACE in "${VPN_TUNNEL_INTERFACES[@]}"; do
  ufw allow in on "$VPN_INTERFACE" \
    comment 'Vagrant managed: trusted VPN tunnel'
done

# Bridged traffic is closed by default. Enabling Nginx ingress adds only HTTP and
# HTTPS; it does not expose SSH, MongoDB, or arbitrary development ports.
if [ "$NGINX_BRIDGED_INGRESS" = true ]; then
  for PORT in 80 443; do
    ufw allow in on "$BRIDGED_INTERFACE" to any port "$PORT" proto tcp \
      comment 'Vagrant managed: public Nginx'
  done
fi

# Enable UFW noninteractively and print the effective policy for the Vagrant log.
# Do not remove broad untagged rules: those belong to the administrator. If one
# conflicts with this model, remove it explicitly outside template provisioning.
ufw --force enable
UFW_STATUS="$(ufw status verbose)"
printf '%s\n' "$UFW_STATUS"
if ! grep --quiet '^Status: active$' <<< "$UFW_STATUS" || \
   ! grep --quiet 'Vagrant managed: Shared SSH' <<< "$UFW_STATUS" || \
   ! grep --quiet 'Vagrant managed: private development' <<< "$UFW_STATUS" || \
   ! grep --quiet 'Vagrant managed: trusted VPN tunnel' <<< "$UFW_STATUS"; then
  echo "UFW did not report the required template-owned rules." >&2
  exit 1
fi

# Commit only after both network and firewall checks pass. A late timer becomes
# a no-op once the state file is absent; transaction data is then discarded.
systemctl stop "${ROLLBACK_UNIT}.timer" "${ROLLBACK_UNIT}.service" \
  > /dev/null 2>&1 || true
rm -f "$ROLLBACK_STATE"
find "$TRANSACTION_DIRECTORY" -depth -delete
trap - EXIT INT TERM HUP

echo "Shared/NAT interface: $SHARED_INTERFACE ($SHARED_MAC, IPv4/IPv6 route metric $SHARED_ROUTE_METRIC)"
echo "Host-only interface: $PRIVATE_INTERFACE ($PRIVATE_MAC, $PRIVATE_NETWORK_IP)"
echo "Bridged Wi-Fi interface: $BRIDGED_INTERFACE ($BRIDGED_MAC, IPv4/IPv6 route metric $BRIDGED_ROUTE_METRIC)"

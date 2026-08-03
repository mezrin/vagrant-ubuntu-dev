#!/usr/bin/env bash
set -Eeuo pipefail

# Purpose: install exact Docker Engine components from Docker's signed Ubuntu
# repository and configure safe development defaults. Runs as root.
# Inputs: repository/key metadata, exact package versions, development username,
# host-only network, and physical-interface route metrics. Repeat behavior:
# files, packages, and Docker's independent ingress policy converge to inputs.
# Limitation: docker-group membership takes effect in the user's next login;
# explicitly published ports are still limited by the DOCKER-USER policy below.

# `${!VARIABLE:?}` is indirect expansion: it checks each named Vagrant input and
# exits before mutation when that input is unset or empty.
for VARIABLE in \
  DOCKER_APT_KEY_URL DOCKER_APT_REPOSITORY_URL DOCKER_APT_KEY_SHA256 \
  DOCKER_CE_VERSION DOCKER_CONTAINERD_VERSION DOCKER_BUILDX_VERSION \
  DOCKER_COMPOSE_VERSION DOCKER_DEFAULT_NOFILE_LIMIT DEFAULT_USER PRIVATE_NETWORK_IP \
  PRIVATE_NETWORK_CIDR BRIDGED_ROUTE_METRIC SHARED_ROUTE_METRIC; do
  : "${!VARIABLE:?}"
done
if [[ ! "$DOCKER_DEFAULT_NOFILE_LIMIT" =~ ^[1-9][0-9]*$ ]]; then
  echo "DOCKER_DEFAULT_NOFILE_LIMIT must be a positive integer." >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

echo "\n\n###\n### Install Docker\n###\n"

# Download the repository key over modern TLS and verify its exact bytes before
# trusting it for apt metadata. The EXIT trap removes partial temporary data.
install -d -m 0755 /etc/apt/keyrings
DOCKER_KEY_TEMP="$(mktemp)"
trap 'rm -f "$DOCKER_KEY_TEMP"' EXIT
curl --proto '=https' --tlsv1.2 -fsSL "$DOCKER_APT_KEY_URL" \
  -o "$DOCKER_KEY_TEMP"
printf '%s  %s\n' "$DOCKER_APT_KEY_SHA256" "$DOCKER_KEY_TEMP" | sha256sum --check -
install -m 0644 "$DOCKER_KEY_TEMP" /etc/apt/keyrings/docker.asc
rm -f "$DOCKER_KEY_TEMP"
trap - EXIT

# Remove legacy source/key formats so apt has one authoritative Docker source.
rm -f /etc/apt/keyrings/docker.gpg /etc/apt/sources.list.d/docker.list

# Deb822 source files make architecture and signing-key scope explicit. Ubuntu's
# codename comes from the guest rather than being duplicated in this script.
. /etc/os-release
printf '%s\n' \
  'Types: deb' \
  "URIs: $DOCKER_APT_REPOSITORY_URL" \
  "Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}" \
  'Components: stable' \
  "Architectures: $(dpkg --print-architecture)" \
  'Signed-By: /etc/apt/keyrings/docker.asc' \
  > /etc/apt/sources.list.d/docker.sources

# A pin priority above 1000 allows apt to converge to the exact requested
# versions, including a deliberate downgrade during a reviewed version change.
cat > /etc/apt/preferences.d/docker <<APT_PREFERENCES
Package: docker-ce docker-ce-cli
Pin: version $DOCKER_CE_VERSION
Pin-Priority: 1001

Package: containerd.io
Pin: version $DOCKER_CONTAINERD_VERSION
Pin-Priority: 1001

Package: docker-buildx-plugin
Pin: version $DOCKER_BUILDX_VERSION
Pin-Priority: 1001

Package: docker-compose-plugin
Pin: version $DOCKER_COMPOSE_VERSION
Pin-Priority: 1001
APT_PREFERENCES

# Record package state so the service restart decision below is based on an
# actual version transition, not merely on running this provisioner again.
docker_package_state() {
  local package
  for package in \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin; do
    if dpkg-query --show --showformat='${Status} ${Version}' "$package" \
         2> /dev/null; then
      printf '\n'
    else
      printf '%s missing\n' "$package"
    fi
  done
}
DOCKER_PACKAGE_STATE_BEFORE="$(docker_package_state)"

# Install every Docker component at its configured version. Provisioning fails
# rather than silently selecting a newer package when a pin is unavailable.
apt-get update
apt-get install --assume-yes \
  "docker-ce=$DOCKER_CE_VERSION" \
  "docker-ce-cli=$DOCKER_CE_VERSION" \
  "containerd.io=$DOCKER_CONTAINERD_VERSION" \
  "docker-buildx-plugin=$DOCKER_BUILDX_VERSION" \
  "docker-compose-plugin=$DOCKER_COMPOSE_VERSION"

# Verify dpkg's actual result independently of apt's success exit status.
verify_package_version() {
  PACKAGE="$1"
  EXPECTED_VERSION="$2"
  INSTALLED_VERSION="$(dpkg-query --show --showformat='${Version}' "$PACKAGE")"
  if [ "$INSTALLED_VERSION" != "$EXPECTED_VERSION" ]; then
    echo "$PACKAGE version $INSTALLED_VERSION does not match $EXPECTED_VERSION." >&2
    exit 1
  fi
}
verify_package_version docker-ce "$DOCKER_CE_VERSION"
verify_package_version docker-ce-cli "$DOCKER_CE_VERSION"
verify_package_version containerd.io "$DOCKER_CONTAINERD_VERSION"
verify_package_version docker-buildx-plugin "$DOCKER_BUILDX_VERSION"
verify_package_version docker-compose-plugin "$DOCKER_COMPOSE_VERSION"
DOCKER_PACKAGE_STATE_AFTER="$(docker_package_state)"
DOCKER_PACKAGES_CHANGED=false
if [ "$DOCKER_PACKAGE_STATE_BEFORE" != "$DOCKER_PACKAGE_STATE_AFTER" ]; then
  DOCKER_PACKAGES_CHANGED=true
fi

# Docker socket access is intentionally granted to the development user. This
# is effectively root-equivalent access inside the guest and is suitable only
# for the trusted development VM described in README.md.
if ! getent group docker > /dev/null; then
  groupadd docker
fi
usermod -aG docker "$DEFAULT_USER"

# Bind ports that omit an explicit host address to Adapter 2 instead of all NICs.
# Build and validate a candidate before atomically replacing the live file. The
# local log driver bounds storage; non-blocking delivery protects applications.
install -d -m 0755 /etc/docker
DOCKER_CONFIG_TEMP="$(mktemp /etc/docker/.daemon.json.XXXXXX)"
trap 'rm -f "$DOCKER_CONFIG_TEMP"' EXIT
cat > "$DOCKER_CONFIG_TEMP" <<JSON
{
  "ip": "$PRIVATE_NETWORK_IP",
  "default-network-opts": {
    "bridge": {
      "com.docker.network.bridge.host_binding_ipv4": "$PRIVATE_NETWORK_IP"
    }
  },
  "log-driver": "local",
  "log-opts": {
    "mode": "non-blocking",
    "max-buffer-size": "10m"
  },
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Soft": $DOCKER_DEFAULT_NOFILE_LIMIT,
      "Hard": $DOCKER_DEFAULT_NOFILE_LIMIT
    }
  }
}
JSON

# A malformed candidate must not replace a working daemon configuration.
dockerd --validate --config-file="$DOCKER_CONFIG_TEMP"
DOCKER_CONFIG_CHANGED=false
if [ ! -e /etc/docker/daemon.json ] || \
   ! cmp --silent "$DOCKER_CONFIG_TEMP" /etc/docker/daemon.json; then
  install -m 0644 "$DOCKER_CONFIG_TEMP" /etc/docker/daemon.json
  DOCKER_CONFIG_CHANGED=true
fi
rm -f "$DOCKER_CONFIG_TEMP"
trap - EXIT

# Docker inserts published-port rules before packets reach UFW. Enforce the
# three-adapter trust model in DOCKER-USER, Docker's documented administrator
# chain: Host-only is allowed from its own subnet, while Shared and Bridged
# ingress are denied even when a container explicitly publishes on 0.0.0.0.
install -d -m 0755 /etc/vagrant /usr/local/sbin
cat > /etc/vagrant/docker-ingress.conf <<CONFIG
PRIVATE_NETWORK_IP=$PRIVATE_NETWORK_IP
PRIVATE_NETWORK_CIDR=$PRIVATE_NETWORK_CIDR
BRIDGED_ROUTE_METRIC=$BRIDGED_ROUTE_METRIC
SHARED_ROUTE_METRIC=$SHARED_ROUTE_METRIC
CONFIG
chmod 0600 /etc/vagrant/docker-ingress.conf

cat > /usr/local/sbin/vagrant-docker-ingress <<'FIREWALL'
#!/usr/bin/env bash
set -Eeuo pipefail

# The network provisioner owns interface configuration. Resolve roles from live
# addresses and route metrics each time Docker starts so kernel names may change.
: "${PRIVATE_NETWORK_IP:?}"
: "${PRIVATE_NETWORK_CIDR:?}"
: "${BRIDGED_ROUTE_METRIC:?}"
: "${SHARED_ROUTE_METRIC:?}"

PRIVATE_INTERFACE="$(
  ip -o -4 address show | awk -v address="$PRIVATE_NETWORK_IP" \
    '$4 ~ ("^" address "/") { print $2 }'
)"

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

SHARED_INTERFACE="$(interface_for_default_metric "$SHARED_ROUTE_METRIC")"
BRIDGED_INTERFACE="$(interface_for_default_metric "$BRIDGED_ROUTE_METRIC")"

for ROLE_AND_INTERFACE in \
  "Private:$PRIVATE_INTERFACE" \
  "Shared:$SHARED_INTERFACE" \
  "Bridged:$BRIDGED_INTERFACE"; do
  ROLE="${ROLE_AND_INTERFACE%%:*}"
  INTERFACE="${ROLE_AND_INTERFACE#*:}"
  if [ -z "$INTERFACE" ] || [[ "$INTERFACE" == *$'\n'* ]]; then
    echo "$ROLE network role does not resolve to exactly one interface." >&2
    exit 1
  fi
done

if [ "$PRIVATE_INTERFACE" = "$SHARED_INTERFACE" ] || \
   [ "$PRIVATE_INTERFACE" = "$BRIDGED_INTERFACE" ] || \
   [ "$SHARED_INTERFACE" = "$BRIDGED_INTERFACE" ]; then
  echo "Docker ingress network roles must resolve to distinct interfaces." >&2
  exit 1
fi

reconcile_chain() {
  local command="$1"
  local managed_chain="$2"

  "$command" --wait --list DOCKER-USER > /dev/null
  if ! "$command" --wait --list "$managed_chain" > /dev/null 2>&1; then
    "$command" --wait --new-chain "$managed_chain"
  fi
  while "$command" --wait --check DOCKER-USER --jump "$managed_chain" \
    > /dev/null 2>&1; do
    "$command" --wait --delete DOCKER-USER --jump "$managed_chain"
  done
  "$command" --wait --flush "$managed_chain"
  "$command" --wait --insert DOCKER-USER 1 --jump "$managed_chain"
  "$command" --wait --append "$managed_chain" \
    --match conntrack --ctstate ESTABLISHED,RELATED --jump RETURN
}

reconcile_chain iptables VAGRANT-DOCKER-INGRESS
iptables --wait --append VAGRANT-DOCKER-INGRESS \
  --in-interface "$PRIVATE_INTERFACE" --source "$PRIVATE_NETWORK_CIDR" --jump RETURN
iptables --wait --append VAGRANT-DOCKER-INGRESS \
  --in-interface "$PRIVATE_INTERFACE" --jump DROP
iptables --wait --append VAGRANT-DOCKER-INGRESS \
  --in-interface "$SHARED_INTERFACE" --jump DROP
iptables --wait --append VAGRANT-DOCKER-INGRESS \
  --in-interface "$BRIDGED_INTERFACE" --jump DROP
iptables --wait --append VAGRANT-DOCKER-INGRESS --jump RETURN

# Docker may omit its IPv6 administrator chain until IPv6 networking is used.
# Create the conventional hook when absent; the final RETURN leaves unrelated
# forwarding alone while blocking Docker-bound traffic from untrusted NICs.
if ! ip6tables --wait --list DOCKER-USER > /dev/null 2>&1; then
  ip6tables --wait --new-chain DOCKER-USER
fi
if ! ip6tables --wait --check FORWARD --jump DOCKER-USER > /dev/null 2>&1; then
  ip6tables --wait --insert FORWARD 1 --jump DOCKER-USER
fi
reconcile_chain ip6tables VAGRANT-DOCKER-INGRESS
ip6tables --wait --append VAGRANT-DOCKER-INGRESS \
  --in-interface "$SHARED_INTERFACE" --jump DROP
ip6tables --wait --append VAGRANT-DOCKER-INGRESS \
  --in-interface "$BRIDGED_INTERFACE" --jump DROP
ip6tables --wait --append VAGRANT-DOCKER-INGRESS --jump RETURN

# Verify the controlling jumps after reconciliation. These checks make a
# missing or incompatible firewall backend a provisioning failure.
iptables --wait --check FORWARD --jump DOCKER-USER
iptables --wait --check DOCKER-USER --jump VAGRANT-DOCKER-INGRESS
ip6tables --wait --check FORWARD --jump DOCKER-USER
ip6tables --wait --check DOCKER-USER --jump VAGRANT-DOCKER-INGRESS
FIREWALL
chmod 0755 /usr/local/sbin/vagrant-docker-ingress

cat > /etc/systemd/system/vagrant-docker-ingress.service <<'UNIT'
[Unit]
Description=Apply Vagrant Docker ingress policy
Requires=docker.service
After=docker.service network-online.target
PartOf=docker.service

[Service]
Type=oneshot
EnvironmentFile=/etc/vagrant/docker-ingress.conf
ExecStart=/usr/local/sbin/vagrant-docker-ingress
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

# Starting or restarting Docker also starts the policy unit after dockerd has
# created DOCKER-USER. PartOf= above stops the policy with Docker.
install -d -m 0755 /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/vagrant-ingress.conf <<'DROP_IN'
[Unit]
Wants=vagrant-docker-ingress.service
Before=vagrant-docker-ingress.service
DROP_IN

systemctl daemon-reload
systemctl enable docker
systemctl enable vagrant-docker-ingress.service

# Restart dockerd only when package versions or daemon settings changed. If it
# is stopped for an unrelated reason, start it; an unchanged active daemon and
# its running containers are otherwise left untouched.
if systemctl is-active --quiet docker; then
  if [ "$DOCKER_PACKAGES_CHANGED" = true ] || [ "$DOCKER_CONFIG_CHANGED" = true ]; then
    systemctl restart docker
  else
    echo "Docker packages and daemon configuration are unchanged; not restarting."
  fi
else
  systemctl start docker
fi
systemctl restart vagrant-docker-ingress.service
docker version

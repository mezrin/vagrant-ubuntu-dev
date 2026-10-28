#!/usr/bin/env bash
set -Eeuo pipefail

# Purpose: provision an x86_64 Ubuntu 26.04 development server with the same
# provisioners the Vagrantfile runs in the guest, minus the Parallels-specific
# ones, plus a server firewall and SSH hardening.
# Usage: server/setup.sh [--list] [STEP...]   (no STEP runs every step in order)
# Runs as the development user, never as root; privileged steps use sudo.
# Inputs: server/server.env, plus the MongoDB password from MONGODB_PASSWORD or
# .secrets/mongodb-password (generated with mode 0600 when neither exists).
# Repeat behavior: every step converges and is safe to run again.

SERVER_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_DIRECTORY="$(dirname "$SERVER_DIRECTORY")"
PROVISION_DIRECTORY="$REPOSITORY_DIRECTORY/provision/ubuntu-26.04"
SERVER_PROVISION_DIRECTORY="$SERVER_DIRECTORY/provision"
MONGODB_PASSWORD_FILE="$REPOSITORY_DIRECTORY/.secrets/mongodb-password"

if [ "$(id --user)" -eq 0 ]; then
  echo "Run setup.sh as the development user; it uses sudo where needed." >&2
  exit 1
fi
if [ "$(dpkg --print-architecture)" != amd64 ]; then
  echo "server/server.env pins x86_64 (amd64) archives only." >&2
  exit 1
fi

# shellcheck source=server.env
source "$SERVER_DIRECTORY/server.env"

# Each step: name, privilege (root or user), script path, then input names.
# The order matches the Vagrantfile, with the server network steps in place of
# network-security, network-link-recovery, enlarge-hdd, and ubuntu-desktop.
STEPS=(
  "os-package-security-baseline|root|$PROVISION_DIRECTORY/os-package-security-baseline.sh|OS_APT_PACKAGES"
  "development-kernel-limits|root|$PROVISION_DIRECTORY/development-kernel-limits.sh|INOTIFY_MAX_USER_WATCHES INOTIFY_MAX_USER_INSTANCES"
  "ssh-hardening|root|$SERVER_PROVISION_DIRECTORY/ssh-hardening.sh|DEFAULT_USER"
  "firewall|root|$SERVER_PROVISION_DIRECTORY/firewall.sh|SERVER_PUBLIC_TCP_PORTS"
  "general-dev-user|user|$PROVISION_DIRECTORY/general-dev-user.sh|GIT_USER_EMAIL GIT_USER_NAME GIT_CORE_EDITOR GITHUB_SSH_IDENTITY_FILE"
  "github-cli|root|$PROVISION_DIRECTORY/github-cli.sh|GITHUB_CLI_VERSION GITHUB_CLI_ARCHIVE_URL GITHUB_CLI_ARCHIVE_SHA256"
  "docker|root|$PROVISION_DIRECTORY/docker.sh|DOCKER_APT_KEY_URL DOCKER_APT_REPOSITORY_URL DOCKER_APT_KEY_SHA256 DOCKER_CE_VERSION DOCKER_CONTAINERD_VERSION DOCKER_BUILDX_VERSION DOCKER_COMPOSE_VERSION DOCKER_DEFAULT_NOFILE_LIMIT DEFAULT_USER DOCKER_INGRESS_POLICY PRIVATE_NETWORK_IP"
  "rust-for-substrate|user|$PROVISION_DIRECTORY/rust-for-substrate.sh|RUSTUP_VERSION RUSTUP_INIT_URL RUSTUP_INIT_SHA256 RUST_STABLE_TOOLCHAIN RUST_NIGHTLY_TOOLCHAIN"
  "python-uv|root|$PROVISION_DIRECTORY/python-uv.sh|UV_VERSION UV_ARCHIVE_URL UV_ARCHIVE_SHA256"
  "python|user|$PROVISION_DIRECTORY/python.sh|PYTHON_VERSIONS"
  "python-user|user|$PROVISION_DIRECTORY/python-user.sh|"
  "nodejs|user|$PROVISION_DIRECTORY/nodejs.sh|NVM_VERSION NVM_ARCHIVE_URL NVM_ARCHIVE_SHA256 NODE_VERSION NODE_ARCHIVE_URL NODE_ARCHIVE_SHA256 COREPACK_VERSION COREPACK_ARCHIVE_URL COREPACK_ARCHIVE_SHA256"
  "postgresql|root|$PROVISION_DIRECTORY/postgresql.sh|POSTGRESQL_APT_KEY_URL POSTGRESQL_APT_REPOSITORY_URL POSTGRESQL_APT_KEY_SHA256 POSTGRESQL_MAJOR_VERSION POSTGRESQL_PACKAGE_VERSION POSTGRESQL_ALLOW_PACKAGE_DOWNGRADE"
  "mongodb|root|$PROVISION_DIRECTORY/mongodb.sh|MONGODB_PASSWORD_ENVIRONMENT_VARIABLE MONGODB_CONTAINER MONGODB_IMAGE MONGODB_VOLUME MONGODB_PORT MONGODB_SECRETS_DIRECTORY MONGODB_CONFIG_VERSION MONGODB_MANAGED_LABEL MONGODB_CONFIG_LABEL MONGODB_CONFIG_DIGEST_LABEL MONGODB_STOP_TIMEOUT_SECONDS MONGODB_READY_ATTEMPTS MONGODB_HEALTH_ATTEMPTS MONGODB_RETRY_DELAY_SECONDS MONGODB_HEALTH_INTERVAL MONGODB_HEALTH_TIMEOUT MONGODB_HEALTH_START_PERIOD MONGODB_HEALTH_RETRIES MONGODB_DIAGNOSTIC_LOG_LINES MONGODB_NOFILE_LIMIT VM_NAME PRIVATE_NETWORK_IP MONGODB_REPLICA_SET MONGODB_REPLICA_MEMBER MONGODB_USERNAME MONGODB_AUTH_DATABASE"
)

step_names() {
  local step
  for step in "${STEPS[@]}"; do printf '%s\n' "${step%%|*}"; done
}

if [ "${1:-}" = --list ]; then
  step_names
  exit 0
fi
SELECTED_STEPS=("$@")
for SELECTED in "${SELECTED_STEPS[@]}"; do
  if ! step_names | grep --quiet --line-regexp --fixed-strings "$SELECTED"; then
    echo "Unknown step: $SELECTED (see --list)" >&2
    exit 1
  fi
done

# Match the Vagrantfile: an explicit environment value wins over the file. The
# file lives in the gitignored .secrets directory and is created only when
# MongoDB is about to be provisioned.
read_mongodb_password() {
  if [ -n "${MONGODB_PASSWORD:-}" ]; then
    return
  fi
  if [ ! -e "$MONGODB_PASSWORD_FILE" ]; then
    install -d -m 0700 "$(dirname "$MONGODB_PASSWORD_FILE")"
    (umask 077 && openssl rand -hex 24 > "$MONGODB_PASSWORD_FILE")
    echo "Generated a MongoDB password in $MONGODB_PASSWORD_FILE."
  fi
  if [ ! -f "$MONGODB_PASSWORD_FILE" ] || [ -L "$MONGODB_PASSWORD_FILE" ]; then
    echo "$MONGODB_PASSWORD_FILE must be a regular file." >&2
    exit 1
  fi
  MONGODB_PASSWORD="$(< "$MONGODB_PASSWORD_FILE")"
}

run_step() {
  local name="$1" privilege="$2" script="$3" inputs="$4"
  local -a environment=() variables=()
  local variable
  read -r -a variables <<< "$inputs"
  for variable in "${variables[@]}"; do
    environment+=("$variable=${!variable}")
  done

  echo
  echo "=== $name ($privilege) ==="
  if [ "$name" = mongodb ]; then
    # Pass the secret on stdin so it never appears in a process argument list.
    read_mongodb_password
    sudo env "${environment[@]}" bash -c \
      'IFS= read -r MONGODB_PASSWORD; export MONGODB_PASSWORD; exec "$0"' \
      "$script" <<< "$MONGODB_PASSWORD"
  elif [ "$privilege" = root ]; then
    sudo env "${environment[@]}" "$script"
  else
    env "${environment[@]}" "$script"
  fi
}

for STEP in "${STEPS[@]}"; do
  IFS='|' read -r NAME PRIVILEGE SCRIPT INPUTS <<< "$STEP"
  if [ "${#SELECTED_STEPS[@]}" -gt 0 ] && \
     ! printf '%s\n' "${SELECTED_STEPS[@]}" | \
       grep --quiet --line-regexp --fixed-strings "$NAME"; then
    continue
  fi
  run_step "$NAME" "$PRIVILEGE" "$SCRIPT" "$INPUTS"
done

echo
echo "=== Done ==="
if [ -e /run/reboot-required ]; then
  echo "Ubuntu requests a reboot to finish package updates: sudo reboot"
fi
echo "Log out and back in (or reconnect VS Code) to pick up docker group"
echo "membership and the new PATH entries."

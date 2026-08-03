#!/usr/bin/env bash
set -Eeuo pipefail

# Purpose: provide enough Linux inotify capacity for large development
# workspaces and several concurrent VS Code Remote sessions. Runs as root.
# Inputs: per-user maximum watch count and inotify-instance count.
# Repeat behavior: replace one template-owned sysctl file, load only that file,
# and verify the live kernel values. No reboot or desktop restart is required.
# Limitation: these are ceilings, not reservations. Each allocated watch still
# consumes kernel memory, so workspace exclusions and closing unused remote
# sessions remain important.

: "${INOTIFY_MAX_USER_WATCHES:?}"
: "${INOTIFY_MAX_USER_INSTANCES:?}"
for LIMIT_NAME in INOTIFY_MAX_USER_WATCHES INOTIFY_MAX_USER_INSTANCES; do
  if [[ ! "${!LIMIT_NAME}" =~ ^[1-9][0-9]*$ ]]; then
    echo "$LIMIT_NAME must be a positive integer." >&2
    exit 1
  fi
done

echo "\n\n###\n### Configure development file-watcher capacity\n###\n"

SYSCTL_CONFIG="/etc/sysctl.d/90-vagrant-development-inotify.conf"
SYSCTL_CANDIDATE="$(mktemp /etc/sysctl.d/.90-vagrant-development-inotify.conf.XXXXXX)"
trap 'rm -f "$SYSCTL_CANDIDATE"' EXIT

# Ubuntu 26.04 loads /etc/sysctl.d at boot. Keep the two related controls in a
# standalone file so provisioning does not overwrite administrator-owned kernel
# settings. VS Code recommends 524288 watches for large Linux workspaces.
printf '%s\n' \
  '# Managed by Vagrantfile; manual edits are overwritten.' \
  "fs.inotify.max_user_watches=$INOTIFY_MAX_USER_WATCHES" \
  "fs.inotify.max_user_instances=$INOTIFY_MAX_USER_INSTANCES" \
  > "$SYSCTL_CANDIDATE"

if [ ! -e "$SYSCTL_CONFIG" ] || \
   ! cmp --silent "$SYSCTL_CANDIDATE" "$SYSCTL_CONFIG"; then
  install -o root -g root -m 0644 "$SYSCTL_CANDIDATE" "$SYSCTL_CONFIG"
fi
rm -f "$SYSCTL_CANDIDATE"
trap - EXIT

# Loading this one file applies the limits immediately without replaying or
# taking ownership of unrelated sysctl configuration.
sysctl --load "$SYSCTL_CONFIG"
if [ "$(sysctl --values fs.inotify.max_user_watches)" != \
     "$INOTIFY_MAX_USER_WATCHES" ] || \
   [ "$(sysctl --values fs.inotify.max_user_instances)" != \
     "$INOTIFY_MAX_USER_INSTANCES" ]; then
  echo "The live inotify limits do not match the configured values." >&2
  exit 1
fi

echo "Inotify watches per user: $INOTIFY_MAX_USER_WATCHES"
echo "Inotify instances per user: $INOTIFY_MAX_USER_INSTANCES"

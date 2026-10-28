#!/usr/bin/env bash
set -Eeuo pipefail

# Purpose: allow only public-key SSH logins on an internet-facing server, which
# stops password brute-force attempts against root and other accounts. Runs as
# root.
# Input: DEFAULT_USER, the development account that must keep key access.
# Repeat behavior: one drop-in file converges; sshd is reloaded, not restarted,
# so open sessions (including VS Code Remote SSH) are kept.

: "${DEFAULT_USER:?}"

echo "\n\n###\n### Restrict SSH to public-key authentication\n###\n"

# Refuse to disable passwords unless the development user can already log in
# with a key. This is the main protection against locking the owner out.
USER_HOME="$(getent passwd "$DEFAULT_USER" | cut -d: -f6)"
if [ ! -s "$USER_HOME/.ssh/authorized_keys" ]; then
  echo "$DEFAULT_USER has no authorized_keys; refusing to disable passwords." >&2
  exit 1
fi

# Files in sshd_config.d are read in lexical order and the first value wins, so
# 00- takes precedence over the provider's 50-cloud-init.conf.
SSHD_DROP_IN="/etc/ssh/sshd_config.d/00-server-key-only.conf"
SSHD_CANDIDATE="$(mktemp /etc/ssh/sshd_config.d/.00-server-key-only.conf.XXXXXX)"
trap 'rm -f "$SSHD_CANDIDATE"' EXIT
printf '%s\n' \
  '# Managed by server/provision/ssh-hardening.sh; manual edits are overwritten.' \
  'PasswordAuthentication no' \
  'KbdInteractiveAuthentication no' \
  'PermitRootLogin prohibit-password' \
  > "$SSHD_CANDIDATE"
chmod 0644 "$SSHD_CANDIDATE"

SSHD_CHANGED=false
if [ ! -e "$SSHD_DROP_IN" ] || ! cmp --silent "$SSHD_CANDIDATE" "$SSHD_DROP_IN"; then
  mv "$SSHD_CANDIDATE" "$SSHD_DROP_IN"
  SSHD_CHANGED=true
fi
rm -f "$SSHD_CANDIDATE"
trap - EXIT

# Validate the complete configuration before sshd sees it, and remove the
# drop-in again if the result is invalid.
if ! sshd -t; then
  rm -f "$SSHD_DROP_IN"
  echo "sshd rejected the configuration; the drop-in was removed." >&2
  exit 1
fi
if [ "$SSHD_CHANGED" = true ]; then
  systemctl reload ssh
fi

SSHD_EFFECTIVE="$(sshd -T)"
for EXPECTED in 'passwordauthentication no' 'kbdinteractiveauthentication no' \
                'permitrootlogin prohibit-password' 'pubkeyauthentication yes'; do
  if ! grep --quiet --line-regexp "$EXPECTED" <<< "$SSHD_EFFECTIVE"; then
    echo "sshd does not report: $EXPECTED" >&2
    exit 1
  fi
done
echo "SSH accepts public-key logins only."

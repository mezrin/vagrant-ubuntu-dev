#!/usr/bin/env bash
set -Eeuo pipefail

# Purpose: install the single combined Ubuntu package set, configure daily
# unattended security upgrades, and apply currently available upgrades.
# Runs as: root.
# Input: OS_APT_PACKAGES, a space-separated list assembled by the Vagrantfile.
# Repeat behavior: apt and the written configuration files converge safely.

# The : expansion exits immediately with a useful error if Vagrant omitted the
# required environment variable. read converts the validated string to argv so
# apt receives one argument per package rather than one large string.
: "${OS_APT_PACKAGES:?}"

export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none
# Automatic needrestart mode can restart ssh.service or the active network
# backend inside this Vagrant SSH session. List affected services instead; the
# post-provision hook performs one provider-aware reboot when Ubuntu requests it.
export NEEDRESTART_MODE=l

read -r -a PACKAGES <<< "$OS_APT_PACKAGES"

# Background update jobs are stopped below to avoid competing for apt's locks.
# An EXIT trap restores them after both success and failure. It preserves the
# original provisioning error, but makes restoration failure fatal when the apt
# work itself succeeded.
restore_automatic_updates() {
  local original_status=$?
  trap - EXIT

  # Development boxes commonly mask apt's triggered services so packaging
  # cannot run in the background while a box is being built. This VM's policy
  # is different: daily maintenance must work after provisioning. Remove both
  # persistent and runtime masks, reload the unit graph, then enable/start the
  # two timers and the unattended-upgrade shutdown service. The apt services
  # themselves are static and are started later by their timers.
  if systemctl unmask apt-daily.service apt-daily-upgrade.service \
       apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service &&
     systemctl daemon-reload; then
    # reset-failed reports an error for a valid static unit that systemd has not
    # loaded into memory yet. Clear known failures when possible, but let the
    # strict enable/start and postcondition checks below decide restoration.
    local update_unit
    for update_unit in \
      apt-daily.service apt-daily-upgrade.service \
      apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service; do
      systemctl reset-failed "$update_unit" > /dev/null 2>&1 || true
    done

    if systemctl enable --now apt-daily.timer apt-daily-upgrade.timer \
         unattended-upgrades.service &&
       systemctl is-enabled --quiet apt-daily.timer apt-daily-upgrade.timer \
         unattended-upgrades.service &&
       systemctl is-active --quiet apt-daily.timer apt-daily-upgrade.timer \
         unattended-upgrades.service; then
      exit "$original_status"
    fi
  fi

  echo "Failed to restore automatic Ubuntu update services." >&2
  if [ "$original_status" -ne 0 ]; then
    exit "$original_status"
  fi
  exit 1
}
trap restore_automatic_updates EXIT

# Stop background apt jobs before taking dpkg's lock. Failure is tolerated
# because a minimal box may not have started every timer or service yet.
systemctl stop apt-daily.timer apt-daily-upgrade.timer \
  apt-daily.service apt-daily-upgrade.service \
  unattended-upgrades.service > /dev/null 2>&1 || true

cat > /etc/apt/apt.conf.d/99-vagrant-lock-timeout <<'APT_CONFIG'
DPkg::Lock::Timeout "300";
APT_CONFIG

# This is the only general Ubuntu package installation transaction. Optional
# features contribute their prerequisites to PACKAGES in the Vagrantfile.
apt-get update
apt-get install --assume-yes "${PACKAGES[@]}"

# Enable daily index refreshes and unattended security upgrades, but leave
# reboot timing under Vagrant's final conditional-reboot provisioner.
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'APT_CONFIG'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT_CONFIG
cat > /etc/apt/apt.conf.d/52-vagrant-unattended-upgrades <<'APT_CONFIG'
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
APT_CONFIG

# Apply available upgrades during provisioning. The EXIT trap restores normal
# timers for ongoing maintenance after the VM is handed to the developer.
unattended-upgrade --verbose

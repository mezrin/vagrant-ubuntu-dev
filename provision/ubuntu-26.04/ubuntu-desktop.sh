#!/usr/bin/env bash
set -Eeuo pipefail

# Purpose: make the already-installed Ubuntu desktop start by default.
# Runs as: root.
# Prerequisite: ubuntu-desktop-minimal and gdm3 were installed by the shared apt
# baseline. This script does not install packages or start an interactive GUI in
# the current provisioning session.

systemctl enable gdm3
systemctl set-default graphical.target

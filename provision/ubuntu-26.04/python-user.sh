#!/usr/bin/env bash
set -Eeuo pipefail

# Purpose: protect the development user's Python installations from accidental
# global pip changes. Runs without sudo and modifies only the user's Bash setup.
# Repeated provisioning does not add a duplicate line.

# pip exits unless a virtual environment is active. Tools such as uv can still
# create and manage environments normally.
if ! grep -Fqx 'export PIP_REQUIRE_VIRTUALENV=1' ~/.bashrc; then
  printf '\n# Require a virtual environment for Python packages\nexport PIP_REQUIRE_VIRTUALENV=1\n' >> ~/.bashrc
fi

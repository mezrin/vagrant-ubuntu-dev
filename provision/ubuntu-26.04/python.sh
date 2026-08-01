#!/usr/bin/env bash
set -Eeuo pipefail

# Purpose: install exact uv-managed Python interpreters for the development user.
# Runs without sudo so interpreters, shims, and environments remain user-owned.
# Input: PYTHON_VERSIONS, a space-separated list of full patch versions.
# Limitation: these are uv-managed interpreters, not Ubuntu's system Python.

# Reject a missing or empty version list before changing the user's home.
: "${PYTHON_VERSIONS:?}"

echo "\n\n###\n### Install pinned managed Python interpreters\n###\n"

export UV_PYTHON_INSTALL_DIR="$HOME/.local/share/uv/python"
export UV_PYTHON_BIN_DIR="$HOME/.local/bin"
install -d -m 0755 "$UV_PYTHON_INSTALL_DIR" "$UV_PYTHON_BIN_DIR"

# Ask uv for exact patch releases and avoid progress animation in Vagrant logs.
read -r -a VERSIONS <<< "$PYTHON_VERSIONS"
uv python install --managed-python --no-progress "${VERSIONS[@]}"

# Verify each versioned shim, reported interpreter version, and standard venv
# support rather than trusting only uv's exit status.
for PYTHON_VERSION in "${VERSIONS[@]}"; do
  PYTHON_MINOR="${PYTHON_VERSION%.*}"
  PYTHON_BINARY="$UV_PYTHON_BIN_DIR/python$PYTHON_MINOR"
  test -x "$PYTHON_BINARY"
  test "$("$PYTHON_BINARY" --version)" = "Python $PYTHON_VERSION"
  "$PYTHON_BINARY" -m venv --help > /dev/null
done

# Login shells need ~/.local/bin to find python3.x and other user-managed tools.
if ! grep -Fqx 'export PATH="$HOME/.local/bin:$PATH"' ~/.profile; then
  printf '\n# User-managed development tools\nexport PATH="$HOME/.local/bin:$PATH"\n' >> ~/.profile
fi

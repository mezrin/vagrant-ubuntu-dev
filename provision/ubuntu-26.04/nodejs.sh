#!/usr/bin/env bash
set -Eeuo pipefail

# Purpose: install exact NVM, ARM64 Node.js, and Corepack releases for the
# development user without executing remote installer scripts. Runs unprivileged.
# Inputs: versioned archive URLs and SHA-256 digests for all three components.
# Repeat behavior: NVM files converge, an exact Node tree is reused when valid,
# and Corepack is replaced only when its reported version differs.

# Validate every Vagrant-supplied input before downloading or changing user files.
for VARIABLE in \
  NVM_VERSION NVM_ARCHIVE_URL NVM_ARCHIVE_SHA256 NODE_VERSION \
  NODE_ARCHIVE_URL NODE_ARCHIVE_SHA256 COREPACK_VERSION \
  COREPACK_ARCHIVE_URL COREPACK_ARCHIVE_SHA256; do
  : "${!VARIABLE:?}"
done

echo "\n\n###\n### Install Node.js\n###\n"

# All downloads and extraction happen in one temporary directory that is removed
# on success or failure.
export NVM_DIR="$HOME/.nvm"
NODEJS_TEMP_DIRECTORY="$(mktemp -d)"
NVM_ARCHIVE="$NODEJS_TEMP_DIRECTORY/nvm.tar.gz"
NODE_ARCHIVE="$NODEJS_TEMP_DIRECTORY/node.tar.gz"
COREPACK_ARCHIVE="$NODEJS_TEMP_DIRECTORY/corepack.tgz"
trap 'rm -rf "$NODEJS_TEMP_DIRECTORY"' EXIT

# Install NVM from a verified source archive. Copy only runtime and completion
# files needed by this template instead of running NVM's network installer.
curl --proto '=https' --tlsv1.2 -fsSL "$NVM_ARCHIVE_URL" -o "$NVM_ARCHIVE"
printf '%s  %s\n' "$NVM_ARCHIVE_SHA256" "$NVM_ARCHIVE" | sha256sum --check -
install -d -m 0755 "$NVM_DIR"
tar --extract --gzip --file "$NVM_ARCHIVE" --directory "$NODEJS_TEMP_DIRECTORY"
NVM_SOURCE_DIRECTORY="$NODEJS_TEMP_DIRECTORY/nvm-${NVM_VERSION#v}"
install -m 0644 "$NVM_SOURCE_DIRECTORY/nvm.sh" "$NVM_DIR/nvm.sh"
install -m 0755 "$NVM_SOURCE_DIRECTORY/nvm-exec" "$NVM_DIR/nvm-exec"
install -m 0644 "$NVM_SOURCE_DIRECTORY/bash_completion" "$NVM_DIR/bash_completion"

# Load NVM in future interactive Bash shells without duplicating startup lines.
if ! grep -Fqx 'export NVM_DIR="$HOME/.nvm"' ~/.bashrc; then
  printf '\nexport NVM_DIR="$HOME/.nvm"\n[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"\n' >> ~/.bashrc
fi

if [ -s "$NVM_DIR/nvm.sh" ]; then
  source "$NVM_DIR/nvm.sh"
else
  echo "NVM installation did not create $NVM_DIR/nvm.sh." >&2
  exit 1
fi

# Completion is optional at runtime; source it when the verified archive supplied
# the file so the current shell matches future interactive shells.
if [ -s "$NVM_DIR/bash_completion" ]; then
  source "$NVM_DIR/bash_completion"
fi

# Install the verified vendor binary archive directly into NVM's normal version
# layout. Reuse it only when an executable reports the exact requested version.
NODE_INSTALL_DIRECTORY="$NVM_DIR/versions/node/$NODE_VERSION"
if [ ! -x "$NODE_INSTALL_DIRECTORY/bin/node" ] || \
   [ "$("$NODE_INSTALL_DIRECTORY/bin/node" --version)" != "$NODE_VERSION" ]; then
  curl --proto '=https' --tlsv1.2 -fsSL "$NODE_ARCHIVE_URL" -o "$NODE_ARCHIVE"
  printf '%s  %s\n' "$NODE_ARCHIVE_SHA256" "$NODE_ARCHIVE" | sha256sum --check -
  tar --extract --gzip --file "$NODE_ARCHIVE" --directory "$NODEJS_TEMP_DIRECTORY"
  install -d -m 0755 "$(dirname "$NODE_INSTALL_DIRECTORY")"
  rm -rf "$NODE_INSTALL_DIRECTORY"
  mv "$NODEJS_TEMP_DIRECTORY/node-$NODE_VERSION-linux-arm64" "$NODE_INSTALL_DIRECTORY"
fi

# Make the exact version NVM's default for new shells and select it now so npm's
# global installation target is the intended Node tree.
nvm alias default "$NODE_VERSION"
nvm use default

# Install the already-downloaded, checksum-verified Corepack package with lifecycle
# scripts disabled. This avoids resolving a moving npm registry version.
if ! command -v corepack > /dev/null 2>&1 || \
   [ "$(corepack --version)" != "$COREPACK_VERSION" ]; then
  curl --proto '=https' --tlsv1.2 -fsSL "$COREPACK_ARCHIVE_URL" -o "$COREPACK_ARCHIVE"
  printf '%s  %s\n' "$COREPACK_ARCHIVE_SHA256" "$COREPACK_ARCHIVE" | sha256sum --check -
  npm install --global --ignore-scripts "$COREPACK_ARCHIVE"
fi

# Record and enforce the final versions before removing temporary artifacts.
test "$(nvm --version)" = "${NVM_VERSION#v}"
test "$(node --version)" = "$NODE_VERSION"
test "$(corepack --version)" = "$COREPACK_VERSION"

rm -rf "$NODEJS_TEMP_DIRECTORY"
trap - EXIT

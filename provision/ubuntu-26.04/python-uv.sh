#!/usr/bin/env bash
set -Eeuo pipefail

# Purpose: install verified uv and uvx binaries system-wide for later user-level
# Python provisioning. Runs as root.
# Inputs: exact uv version plus ARM64 archive URL and SHA-256 digest.
# Repeat behavior: verified binaries replace the same /usr/local/bin paths.

# Require all release metadata before downloading or replacing system binaries.
: "${UV_VERSION:?}"
: "${UV_ARCHIVE_URL:?}"
: "${UV_ARCHIVE_SHA256:?}"

echo "\n\n###\n### Install the pinned uv binary\n###\n"

# A private temporary directory contains both the archive and extracted tree.
# The trap removes partial data if download, verification, or extraction fails.
UV_TEMP_DIRECTORY="$(mktemp -d)"
UV_ARCHIVE="$UV_TEMP_DIRECTORY/uv.tar.gz"
trap 'rm -rf "$UV_TEMP_DIRECTORY"' EXIT

curl --proto '=https' --tlsv1.2 -fsSL "$UV_ARCHIVE_URL" -o "$UV_ARCHIVE"
printf '%s  %s\n' "$UV_ARCHIVE_SHA256" "$UV_ARCHIVE" | sha256sum --check -
tar --extract --gzip --file "$UV_ARCHIVE" --directory "$UV_TEMP_DIRECTORY"

# Install only the two expected executables, not arbitrary archive contents.
install -m 0755 \
  "$UV_TEMP_DIRECTORY/uv-aarch64-unknown-linux-gnu/uv" \
  /usr/local/bin/uv
install -m 0755 \
  "$UV_TEMP_DIRECTORY/uv-aarch64-unknown-linux-gnu/uvx" \
  /usr/local/bin/uvx

rm -rf "$UV_TEMP_DIRECTORY"
trap - EXIT

# Confirm both executables report the configured release. Newer uv releases add
# a parenthesized target triple, while older releases return only name/version;
# accept either format but never a different version or unexpected prefix.
verify_uv_version() {
  local command="$1"
  local reported_version
  reported_version="$($command --version)"
  if [ "$reported_version" != "$command $UV_VERSION" ] && \
     [[ "$reported_version" != "$command $UV_VERSION "* ]]; then
    echo "$command reported an unexpected version: $reported_version" >&2
    exit 1
  fi
}
verify_uv_version uv
verify_uv_version uvx

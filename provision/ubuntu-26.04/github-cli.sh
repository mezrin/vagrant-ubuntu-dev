#!/usr/bin/env bash
set -Eeuo pipefail

# Purpose: install GitHub's official `gh` command-line interface system-wide.
# Runs as root so every guest user resolves the same /usr/local/bin/gh binary.
# Inputs: an exact release version plus its immutable ARM64 archive URL and
# SHA-256 digest.
# Repeat behavior: download and verify the configured release, then atomically
# replace only the `gh` executable. Authentication and tokens remain user-owned.

: "${GITHUB_CLI_VERSION:?}"
: "${GITHUB_CLI_ARCHIVE_URL:?}"
: "${GITHUB_CLI_ARCHIVE_SHA256:?}"

if [[ ! "$GITHUB_CLI_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "GITHUB_CLI_VERSION must be an exact semantic version." >&2
  exit 1
fi
if [[ ! "$GITHUB_CLI_ARCHIVE_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "GITHUB_CLI_ARCHIVE_SHA256 must be a lowercase SHA-256 digest." >&2
  exit 1
fi
if [ "$(dpkg --print-architecture)" != arm64 ]; then
  echo "The configured GitHub CLI archive supports only an ARM64 guest." >&2
  exit 1
fi

echo "\n\n###\n### Install the pinned GitHub CLI\n###\n"

GITHUB_CLI_TEMP_DIRECTORY="$(mktemp --directory)"
GITHUB_CLI_ARCHIVE="$GITHUB_CLI_TEMP_DIRECTORY/gh.tar.gz"
GITHUB_CLI_ARCHIVE_ROOT="gh_${GITHUB_CLI_VERSION}_linux_arm64"
trap 'rm -rf "$GITHUB_CLI_TEMP_DIRECTORY"' EXIT

# GitHub release assets are served through redirects. Restrict the original and
# redirected requests to HTTPS, then verify the exact bytes before extraction.
curl --proto '=https' --proto-redir '=https' --tlsv1.2 \
  --fail --silent --show-error --location \
  --retry 5 --retry-all-errors \
  "$GITHUB_CLI_ARCHIVE_URL" -o "$GITHUB_CLI_ARCHIVE"
printf '%s  %s\n' "$GITHUB_CLI_ARCHIVE_SHA256" "$GITHUB_CLI_ARCHIVE" | \
  sha256sum --check --strict -

# Extract inside a disposable directory without adopting archive ownership.
# Install only the expected executable rather than copying the entire release.
tar --extract --gzip --file "$GITHUB_CLI_ARCHIVE" \
  --directory "$GITHUB_CLI_TEMP_DIRECTORY" --no-same-owner
GITHUB_CLI_CANDIDATE="$GITHUB_CLI_TEMP_DIRECTORY/$GITHUB_CLI_ARCHIVE_ROOT/bin/gh"
if [ ! -f "$GITHUB_CLI_CANDIDATE" ] || [ -L "$GITHUB_CLI_CANDIDATE" ]; then
  echo "The GitHub CLI archive does not contain the expected regular file." >&2
  exit 1
fi
install -o root -g root -m 0755 "$GITHUB_CLI_CANDIDATE" /usr/local/bin/gh

rm -rf "$GITHUB_CLI_TEMP_DIRECTORY"
trap - EXIT

# The first line includes a release date after the semantic version. Match the
# stable prefix while rejecting an unexpected executable or version.
IFS= read -r GITHUB_CLI_REPORTED_VERSION < <(/usr/local/bin/gh --version)
if [[ "$GITHUB_CLI_REPORTED_VERSION" != \
      "gh version $GITHUB_CLI_VERSION "* ]]; then
  echo "gh reported an unexpected version: $GITHUB_CLI_REPORTED_VERSION" >&2
  exit 1
fi
/usr/local/bin/gh help > /dev/null
echo "$GITHUB_CLI_REPORTED_VERSION"

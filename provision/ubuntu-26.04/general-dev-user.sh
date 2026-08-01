#!/usr/bin/env bash
set -Eeuo pipefail

# Purpose: configure Git and reference a GitHub SSH identity for the development
# user. Runs without sudo so global Git configuration means "this user's config."
# Inputs: Git identity/editor values and a path to an existing guest private key.
# Limitation: the SSH key and any GPG signing key are not created or copied.

# Require every personal setting before writing any user configuration.
: "${GIT_USER_EMAIL:?}"
: "${GIT_USER_NAME:?}"
: "${GIT_CORE_EDITOR:?}"
: "${GITHUB_SSH_IDENTITY_FILE:?}"

echo "\n\n###\n### Set up Git\n###\n"

# Repeated git config commands replace the same keys rather than appending them.
git config --global user.email "$GIT_USER_EMAIL"
git config --global user.name "$GIT_USER_NAME"
git config --global core.editor "$GIT_CORE_EDITOR"
git config --global fetch.prune true

echo "\n\n###\n### Add the GitHub identity to SSH config\n###\n"
echo "https://docs.github.com/authentication/connecting-to-github-with-ssh\n"

# Preserve unrelated SSH configuration. Add the GitHub stanza only when the
# exact configured IdentityFile line is not already present anywhere in it.
install -d -m 0700 ~/.ssh
touch ~/.ssh/config
chmod 0600 ~/.ssh/config
if ! grep -Fqx "    IdentityFile $GITHUB_SSH_IDENTITY_FILE" ~/.ssh/config; then
  printf '\n\nHost github.com\n    IdentityFile %s\n' \
    "$GITHUB_SSH_IDENTITY_FILE" >> ~/.ssh/config
fi

# These links are informational. Commit-signing setup is intentionally left to
# the user because it requires creating and registering personal key material.
echo "\n\n###\n### GitHub PGP key documentation\n###\n"
echo "https://docs.github.com/en/authentication/managing-commit-signature-verification/generating-a-new-gpg-key\n"
echo "https://docs.github.com/en/authentication/managing-commit-signature-verification/adding-a-gpg-key-to-your-github-account\n"

#!/usr/bin/env bash
set -Eeuo pipefail

# Purpose: install reproducible Rust toolchains for Substrate-style native and
# WebAssembly development. Runs as the unprivileged development user.
# Inputs: a verified ARM64 rustup-init archive, one exact stable toolchain, and
# one dated nightly toolchain. Toolchains live under the user's home directory.

# Validate every Vagrant-supplied input before downloading or changing user files.
for VARIABLE in \
  RUSTUP_VERSION RUSTUP_INIT_URL RUSTUP_INIT_SHA256 \
  RUST_STABLE_TOOLCHAIN RUST_NIGHTLY_TOOLCHAIN; do
  : "${!VARIABLE:?}"
done

# Keep partial downloads out of the home directory and remove them on failure.
# rustup selects proxy behavior from argv[0], so the verified executable must
# retain the canonical `rustup-init` basename even while stored temporarily.
RUSTUP_TEMP_DIRECTORY="$(mktemp --directory)"
RUSTUP_INIT="$RUSTUP_TEMP_DIRECTORY/rustup-init"
trap 'rm -f "$RUSTUP_INIT"; rmdir "$RUSTUP_TEMP_DIRECTORY"' EXIT

echo "\n\n###\n### Install rustup\n###\n"
curl --proto '=https' --tlsv1.2 -fsSL "$RUSTUP_INIT_URL" -o "$RUSTUP_INIT"
printf '%s  %s\n' "$RUSTUP_INIT_SHA256" "$RUSTUP_INIT" | sha256sum --check -
chmod 0755 "$RUSTUP_INIT"

# Install rustup itself without choosing a moving default toolchain. Exact
# toolchains are selected explicitly below.
"$RUSTUP_INIT" -y --profile default --default-toolchain none
rm -f "$RUSTUP_INIT"
rmdir "$RUSTUP_TEMP_DIRECTORY"
trap - EXIT

source "$HOME/.cargo/env"

# Ensure future login shells can find rustup and Cargo without adding duplicates.
if ! grep -Fqx 'export PATH=$PATH:$HOME/.cargo/bin' ~/.profile; then
  printf '\n# Add Rust and Cargo to PATH\nexport PATH=$PATH:$HOME/.cargo/bin\n' >> ~/.profile
fi

# Stable is the default general-purpose compiler. The dated nightly and its wasm
# target are separate because Substrate workflows can depend on nightly features.
rustup toolchain install "$RUST_STABLE_TOOLCHAIN" --profile default
rustup default "$RUST_STABLE_TOOLCHAIN"
rustup toolchain install "$RUST_NIGHTLY_TOOLCHAIN" --profile minimal
rustup target add wasm32-unknown-unknown --toolchain "$RUST_NIGHTLY_TOOLCHAIN"

# Print the resolved state into the provisioning log for later diagnosis.
rustup show
rustup +"$RUST_NIGHTLY_TOOLCHAIN" show

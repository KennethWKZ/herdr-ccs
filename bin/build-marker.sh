#!/bin/sh
# herdr-plugin.toml's [[build]] step: build the Rust marker when cargo is available. Never fails the install:
# without cargo, or if the build fails, the marker hook uses its shell version instead.
cd "$(dirname "$0")/.." || exit 0
# herdr's server may not have the login shell's PATH, so also look where rustup and Homebrew put cargo.
CARGO=$(command -v cargo 2>/dev/null || true)
for c in "$HOME/.cargo/bin/cargo" /opt/homebrew/opt/rustup/bin/cargo /usr/local/opt/rustup/bin/cargo \
         /opt/homebrew/bin/cargo /usr/local/bin/cargo; do
  [ -n "$CARGO" ] && break
  [ -x "$c" ] && CARGO=$c
done
if [ -z "$CARGO" ]; then
  echo "herdr-ccs: cargo not found; the marker hook will use its shell version (install Rust for the fast one)"
  exit 0
fi
# cargo runs rustc (a rustup proxy next to it) from PATH, so put cargo's folder first.
PATH="${CARGO%/*}:$PATH"; export PATH
if "$CARGO" build --release --locked --manifest-path marker/Cargo.toml; then
  echo "herdr-ccs: built marker/target/release/herdr-ccs-marker"
else
  echo "herdr-ccs: marker build failed; the marker hook will use its shell version"
fi
exit 0

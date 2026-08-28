#!/bin/sh
# Non-plugin bootstrap: copy the herdr-ccs CLI onto PATH, then tell you how to activate.
# Usage: ./install.sh [dest_bin_dir]   (default: ~/.local/bin)
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
dest="${1:-$HOME/.local/bin}"

mkdir -p "$dest"
install -m 0755 "$here/bin/herdr-ccs" "$dest/herdr-ccs"
echo "installed: $dest/herdr-ccs"

case ":$PATH:" in
  *":$dest:"*) ;;
  *) echo "note: '$dest' is not on PATH — add it, e.g.  export PATH=\"$dest:\$PATH\"" ;;
esac

echo "now run:  herdr-ccs install"

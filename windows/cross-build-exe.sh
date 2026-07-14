#!/usr/bin/env bash
# Cross-compile the patched lan-mouse for Windows. RUN THIS ON THE ARCH BOX.
# Produces a daemon-only, no-GTK lan-mouse.exe (the Windows side never shows the
# GTK GUI). Optionally scp it to the Windows machine — pass its ssh host as $1:
#     ./cross-build-exe.sh            # just build
#     ./cross-build-exe.sh win-pc     # build + copy to win-pc:C:/Tools/lan-mouse/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$SCRIPT_DIR")"
TARGET=x86_64-pc-windows-gnu

command -v cargo >/dev/null || { echo "[!] cargo/rust not found — install rustup."; exit 1; }
command -v x86_64-w64-mingw32-gcc >/dev/null || { echo "[!] mingw-w64 linker not found — pacman -S mingw-w64-gcc"; exit 1; }
rustup target list --installed 2>/dev/null | grep -qx "$TARGET" || rustup target add "$TARGET"

echo "==> Cross-compiling lan-mouse for $TARGET (daemon-only, --no-default-features) ..."
cargo build --release --manifest-path "$REPO/lan-mouse/Cargo.toml" \
  --target "$TARGET" --no-default-features

EXE="$REPO/lan-mouse/target/$TARGET/release/lan-mouse.exe"
echo "==> Built: $EXE"
file "$EXE" 2>/dev/null || true

if [ "${1:-}" != "" ]; then
  HOST="$1"
  echo "==> Stopping any running daemon on $HOST and copying the new exe ..."
  ssh "$HOST" 'taskkill /im lan-mouse.exe /f' 2>/dev/null || true
  scp "$EXE" "$HOST:C:/Tools/lan-mouse/lan-mouse.exe"
  echo "==> Copied. Restarting the daemon (hidden, interactive session) via LanMouseRestart ..."
  # The task launches into the interactive desktop session; a direct ssh launch
  # would land in a non-interactive session and couldn't inject input.
  ssh "$HOST" 'schtasks /run /tn LanMouseRestart' 2>/dev/null \
    || echo "[!] Could not trigger LanMouseRestart (run install.ps1 once to create it, or log out/in)."
fi

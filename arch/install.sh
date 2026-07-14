#!/usr/bin/env bash
# Arch (arch-pc) setup for the HDMI software switcher + lan-mouse KVM.
# Builds the patched lan-mouse, installs the binary + scripts + config, and
# wires the Hyprland keybind/autostart. Non-destructive: existing configs are
# backed up and hypr snippets are only appended if missing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$SCRIPT_DIR")"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
BIN="$HOME/.local/bin"

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }

# 1. dependencies
say "Checking dependencies ..."
command -v cargo >/dev/null || { warn "cargo/rust not found — install rustup, then re-run."; exit 1; }
command -v ddcutil >/dev/null || warn "ddcutil not found — pacman -S ddcutil (and ensure the i2c-dev module is loaded + your user is in the i2c group)."
command -v notify-send >/dev/null || warn "notify-send not found (libnotify) — monitor-switch notifications won't show."

# 2. build + install the patched lan-mouse fork
say "Building patched lan-mouse (release) — this takes ~1-2 min ..."
cargo build --release --manifest-path "$REPO/lan-mouse/Cargo.toml"
mkdir -p "$BIN"
install -m755 "$REPO/lan-mouse/target/release/lan-mouse" "$BIN/lan-mouse"
say "Installed lan-mouse -> $BIN/lan-mouse"
case ":$PATH:" in *":$BIN:"*) : ;; *) warn "$BIN is not on PATH — add it to your shell profile." ;; esac

# 3. monitor-switch + helper scripts
say "Installing hypr scripts -> $CONFIG/hypr/scripts ..."
mkdir -p "$CONFIG/hypr/scripts"
install -m755 "$SCRIPT_DIR/hypr/scripts/"*.sh "$CONFIG/hypr/scripts/"

# 4. lan-mouse config
say "Installing lan-mouse config ..."
mkdir -p "$CONFIG/lan-mouse"
if [ -e "$CONFIG/lan-mouse/config.toml" ]; then
  cp -a "$CONFIG/lan-mouse/config.toml" "$CONFIG/lan-mouse/config.toml.bak.$(date +%s)"
  warn "Existing lan-mouse config backed up alongside the new one."
fi
cp "$SCRIPT_DIR/lan-mouse/config.toml" "$CONFIG/lan-mouse/config.toml"
warn "EDIT $CONFIG/lan-mouse/config.toml: set the peer's IP under [[clients]] and its"
warn "cert fingerprint under [authorized_fingerprints] for your machines (see README)."

# 5. hypr snippets (append only if missing)
add_snippet() {
  local target="$1" marker="$2" file="$3"
  if [ ! -e "$target" ]; then warn "Hypr config $target not found — add the snippet from $file manually."; return; fi
  if grep -qF "$marker" "$target"; then
    say "Snippet already present in $(basename "$target") — skipping."
  else
    { printf '\n'; cat "$file"; } >> "$target"
    say "Appended snippet to $(basename "$target")."
  fi
}
add_snippet "$CONFIG/hypr/bindings.conf"  "switch-to-windows.sh"        "$SCRIPT_DIR/hypr/bindings.snippet.conf"
add_snippet "$CONFIG/hypr/autostart.conf" "lan-mouse --capture-backend" "$SCRIPT_DIR/hypr/autostart.snippet.conf"

say "Done. Reload Hyprland (or re-login) to pick up the keybind + autostart."
say "Verify the peer link with:  lan-mouse cli list"

#!/usr/bin/env bash
# ── lan-mouse KVM lock ────────────────────────────────────────────────────
# Freeze the pointer to whichever machine physically has the mouse, and bring
# the link back on demand.
#
#   lanmouse-kvm.sh toggle    # lock <-> unlock (default; the hotkey)
#   lanmouse-kvm.sh lock      # freeze the pointer where the mouse is
#   lanmouse-kvm.sh unlock    # re-enable crossing on both machines
#   lanmouse-kvm.sh restart   # force a clean re-arm of the whole link
#   lanmouse-kvm.sh status    # is the KVM live or frozen?
#
# Why "stop", not a soft hold: lan-mouse's crossing is driven by the machine the
# mouse is plugged into — it grabs at its screen edge and forwards to the peer.
# To keep the pointer on that machine you have to stop *that* daemon from
# crossing, and the mouse can be on either box, so we act on BOTH ends:
#
#   • Arch daemon   — deactivate the peer client over the Unix-socket CLI. This
#     destroys Arch's capture barrier instantly, in-process, daemon stays up.
#   • Windows daemon — its CLI's fire-and-forget requests (activate/deactivate)
#     don't survive the TCP socket close on Windows (only request/response calls
#     like `list` do), so those can't reliably stop it. Instead we stop the
#     daemon outright (taskkill) and relaunch it via the LanMouseRestart task.
#     ("lan-mouse can shut off for all I care and just restart whenever I want.")
#
# Both machines' hotkeys run THIS script on Arch — Hyprland runs it locally,
# Windows runs it over ssh — and it drives the Windows daemon back over the
# existing arch->windows ssh link. So one script is the single source of truth.
set -uo pipefail

# The lan-mouse CLI reaches the Arch daemon over $XDG_RUNTIME_DIR/lan-mouse-socket.sock
# and notify-send needs the session bus. Hyprland sets these; a bare ssh shell
# does not, so derive them from the uid.
uid="$(id -u)"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$uid}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"

LM="${LAN_MOUSE_BIN:-$HOME/.local/bin/lan-mouse}"
[ -x "$LM" ] || LM="$(command -v lan-mouse 2>/dev/null || echo "$LM")"
CLIENT_ID="${LAN_MOUSE_CLIENT:-0}"

# Windows side (over the existing arch->windows ssh link).
WIN_HOST="${LAN_MOUSE_WIN_HOST:-win-pc}"   # ssh alias of your Windows box
WIN_EXE='C:\Tools\lan-mouse\lan-mouse.exe'
WIN_TASK='\LanMouseRestart'
win() { ssh -o BatchMode=yes -o ConnectTimeout=6 "$WIN_HOST" "$@" 2>/dev/null; }

notify() { command -v notify-send >/dev/null 2>&1 && notify-send -a "lan-mouse KVM" "$@" >/dev/null 2>&1 || true; }
cli()    { timeout 5 "$LM" cli "$@" 2>/dev/null; }

# Is the Windows daemon up? That's the authoritative "the KVM is live" signal:
# lock kills it, unlock relaunches it, so its presence == unlocked.
win_up() { win 'tasklist /FI "IMAGENAME eq lan-mouse.exe" /fo csv /nh' | grep -qi 'lan-mouse.exe'; }

lock() {
    cli deactivate "$CLIENT_ID"                     # Arch: stop crossing, keep daemon alive
    win 'taskkill /IM lan-mouse.exe /F' >/dev/null  # Windows: stop the daemon
    notify "Locked 🔒" "pointer stays on the machine with the mouse"
    echo "locked"
}

unlock() {
    win 'taskkill /IM lan-mouse.exe /F' >/dev/null   # ensure a single fresh instance
    win "schtasks /run /tn \"$WIN_TASK\"" >/dev/null  # relaunch the Windows daemon
    cli enable-capture; cli enable-emulation          # Arch: re-arm + re-activate
    cli activate "$CLIENT_ID"
    notify "Unlocked 🔓" "crossing re-enabled on both machines"
    echo "unlocked"
}

case "${1:-toggle}" in
    lock)           lock ;;
    unlock|restart) unlock ;;
    toggle)         if win_up; then lock; else unlock; fi ;;
    status)
        if win_up; then echo "unlocked (KVM live)"; else echo "locked (KVM frozen)"; fi
        printf 'arch: '; cli list | head -n1 ;;
    *) echo "usage: ${0##*/} {toggle|lock|unlock|restart|status}" >&2; exit 2 ;;
esac

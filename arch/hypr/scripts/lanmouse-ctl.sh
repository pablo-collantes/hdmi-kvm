#!/usr/bin/env bash
# ── lan-mouse status + restart panel ──────────────────────────────────────
# One place to answer "which machine's daemon is off?" and put it back.
#
#   lanmouse-ctl.sh gui              # zenity panel: live status + restart buttons (the hotkey)
#   lanmouse-ctl.sh status           # human-readable status of both machines
#   lanmouse-ctl.sh probe            # machine-readable: "arch=<STATE>" + "windows=<STATE>"
#   lanmouse-ctl.sh arch-state       # just this machine's state token
#   lanmouse-ctl.sh windows-state    # just the Windows box's state token
#   lanmouse-ctl.sh restart-arch | restart-windows | restart-both
#   lanmouse-ctl.sh windows-session  # is the Windows box signed in / locked?
#   lanmouse-ctl.sh signin-windows   # get it to an unlocked desktop from here
#
# States
#   ACTIVE       daemon up, peer client armed  → crossing works
#   INACTIVE     daemon up, peer deactivated   → locked, or never armed after a restart
#   DOWN         daemon not running
#   NOSOCK       process alive but its CLI socket isn't answering (wedged)
#   UNREACHABLE  (Windows only) ssh failed — box off, asleep, or off the tailnet
#
# Session states (Windows only, `windows-session`)
#   UNLOCKED     signed in, desktop up   → lan-mouse can actually inject
#   LOCKED       signed in but at the lock screen
#   SIGNEDOUT    nobody signed in (the state a fresh reboot leaves behind)
#
# Why the session matters at all: lan-mouse injects on WinSta0\Default, but the
# lock and sign-in screens are a SEPARATE secure desktop (WinSta0\Winlogon) that
# nothing on Default may touch — that isolation is what stops malware typing into
# the password box. So crossing is dead until the box reaches a real desktop, no
# matter how healthy both daemons look. `signin-windows` is what gets it there.
#
# Why this exists alongside lanmouse-kvm.sh: that script *locks* the pointer
# (and deliberately kills the Windows daemon to do it). This one *reports and
# repairs*. Crucially it tells "off because you locked it" apart from "off
# because it died" — kvm.sh's status can't, since both look like a dead daemon.
#
# Both machines drive this same script: Hyprland runs it locally, the Windows
# AHK panel runs it over ssh. One source of truth for the Arch side.
set -uo pipefail

# The lan-mouse CLI reaches the daemon over $XDG_RUNTIME_DIR/lan-mouse-socket.sock,
# hyprctl needs the instance signature, and zenity/notify-send need the session
# bus + Wayland socket. Hyprland sets all of these; a bare ssh shell does not, so
# derive them from the uid — this script must work identically over ssh.
uid="$(id -u)"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$uid}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
if [ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
    HYPRLAND_INSTANCE_SIGNATURE="$(ls -t "$XDG_RUNTIME_DIR/hypr" 2>/dev/null | head -n1)"
    export HYPRLAND_INSTANCE_SIGNATURE
fi
if [ -z "${WAYLAND_DISPLAY:-}" ]; then
    WAYLAND_DISPLAY="$(cd "$XDG_RUNTIME_DIR" 2>/dev/null && ls -1d wayland-[0-9]* 2>/dev/null | head -n1)"
    export WAYLAND_DISPLAY
fi

LM="${LAN_MOUSE_BIN:-$HOME/.local/bin/lan-mouse}"
[ -x "$LM" ] || LM="$(command -v lan-mouse 2>/dev/null || echo "$LM")"
LM_ARGS="${LAN_MOUSE_ARGS:---capture-backend layer-shell}"
CLIENT_ID="${LAN_MOUSE_CLIENT:-0}"

# Windows side, over the existing arch->windows ssh link. NOTE: the .exe path is
# passed UNQUOTED on purpose — ssh hands the line to `cmd /c`, whose quote
# stripping mangles a quoted program path mid-line ("The system cannot find the
# path specified."). There are no spaces in the path, so bare is correct here.
WIN_HOST="${LAN_MOUSE_WIN_HOST:-win-pc}"   # ssh alias of your Windows box
WIN_EXE='C:\Tools\lan-mouse\lan-mouse.exe'
WIN_TASK='\LanMouseRestart'
WIN_USER="${LAN_MOUSE_WIN_USER:-$USER}"    # the Windows interactive account
WIN_CONSOLE_TASK='\LanMouseConsoleConnect'
WIN_STATE='C:\Tools\lan-mouse\console-connect.state'
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new)

# Only needed to sign in from COLD (nobody logged on). A locked box needs none of
# this. The password is read from the secrets store at the moment of use and is
# never exported, logged, or placed on a command line — see rdp_signin().
RDP_BIN="${LAN_MOUSE_RDP_BIN:-xfreerdp3}"
SECRET_FILE="${LAN_MOUSE_WIN_SECRET:-$HOME/.config/secrets/win_pc_password}"

win()    { timeout 15 ssh "${SSH_OPTS[@]}" "$WIN_HOST" "$@" 2>/dev/null; }
cli()    { timeout 5 "$LM" cli "$@" 2>/dev/null; }
notify() { command -v notify-send >/dev/null 2>&1 && notify-send -a "lan-mouse" "$@" >/dev/null 2>&1 || true; }

# ── status ───────────────────────────────────────────────────────────────
arch_state() {
    pgrep -x lan-mouse >/dev/null 2>&1 || { echo DOWN; return; }
    local out; out="$(cli list)"
    [ -z "$out" ] && { echo NOSOCK; return; }
    case "$out" in *"active: true"*) echo ACTIVE ;; *) echo INACTIVE ;; esac
}

windows_state() {
    local out rc
    out="$(win "tasklist /FI \"IMAGENAME eq lan-mouse.exe\" /fo csv /nh | findstr /i lan-mouse.exe >nul && (echo DAEMON_UP & $WIN_EXE cli list) || echo DAEMON_DOWN")"
    rc=$?
    [ $rc -ne 0 ] && { echo UNREACHABLE; return; }
    case "$out" in
        *DAEMON_DOWN*)     echo DOWN ;;
        *"active: true"*)  echo ACTIVE ;;
        *DAEMON_UP*)       echo INACTIVE ;;
        *)                 echo UNREACHABLE ;;
    esac
}

# Human-readable one-liner for a state token.
describe() {
    case "$1" in
        ACTIVE)      echo "running — crossing armed" ;;
        INACTIVE)    echo "running — crossing OFF (locked, or not armed since restart)" ;;
        DOWN)        echo "daemon NOT running" ;;
        NOSOCK)      echo "process alive but wedged (no CLI socket)" ;;
        UNREACHABLE) echo "unreachable over ssh (box off / asleep / off tailnet)" ;;
        *)           echo "unknown" ;;
    esac
}

icon()  { case "$1" in ACTIVE) echo "✅" ;; INACTIVE) echo "⚠️" ;; *) echo "❌" ;; esac; }
sicon() { case "$1" in UNLOCKED) echo "✅" ;; LOCKED) echo "⚠️" ;; *) echo "❌" ;; esac; }

# ── restart ──────────────────────────────────────────────────────────────
restart_arch() {
    pkill -x lan-mouse 2>/dev/null
    # Relaunch INSIDE the Hyprland session: the layer-shell capture backend needs
    # the compositor's own env, and `hyprctl dispatch exec` inherits it — which is
    # what makes this work when invoked over ssh from the Windows panel too.
    local i
    for i in $(seq 1 20); do pgrep -x lan-mouse >/dev/null 2>&1 || break; sleep 0.1; done
    if command -v hyprctl >/dev/null 2>&1 && hyprctl dispatch exec "$LM $LM_ARGS daemon" >/dev/null 2>&1; then
        :
    else
        setsid -f "$LM" $LM_ARGS daemon >/dev/null 2>&1
    fi
    # Wait for the CLI socket, then arm the link. enable-capture/enable-emulation
    # clear a wedged backend; activate re-arms the edge barrier (the live config
    # may lack activate_on_startup, in which case the client comes up INACTIVE).
    for i in $(seq 1 40); do cli list >/dev/null 2>&1 && break; sleep 0.25; done
    cli enable-capture >/dev/null; cli enable-emulation >/dev/null
    cli activate "$CLIENT_ID" >/dev/null
    echo "arch: $(arch_state)"
}

restart_windows() {
    win 'taskkill /IM lan-mouse.exe /F' >/dev/null   # ensure a single fresh instance
    win "schtasks /run /tn \"$WIN_TASK\"" >/dev/null # relaunch hidden, elevated, in session 1
    local i st
    for i in $(seq 1 12); do
        sleep 1; st="$(windows_state)"
        [ "$st" = ACTIVE ] || [ "$st" = INACTIVE ] && break
    done
    echo "windows: $(windows_state)"
}

# ── sign-in ──────────────────────────────────────────────────────────────
# Both facts in one ssh round trip. LogonUI.exe is alive exactly while the secure
# desktop is on top and exits when the session unlocks — the standard remote lock
# probe. Note a LOCKED session still reports Active/console in `query user`, so
# the session table alone cannot tell locked from usable; LogonUI is the tell.
windows_session() {
    local out rc
    out="$(win "(query user $WIN_USER 2>nul | findstr /i \"$WIN_USER\" >nul && echo HAVE || echo NONE) & (tasklist /FI \"IMAGENAME eq LogonUI.exe\" /fo csv /nh | findstr /i LogonUI.exe >nul && echo LOCKUI || echo NOUI)")"
    rc=$?
    [ $rc -ne 0 ] && { echo UNREACHABLE; return; }
    case "$out" in
        *NONE*)        echo SIGNEDOUT ;;
        *HAVE*LOCKUI*) echo LOCKED ;;
        *HAVE*NOUI*)   echo UNLOCKED ;;
        *)             echo UNREACHABLE ;;
    esac
}

describe_session() {
    case "$1" in
        UNLOCKED)    echo "signed in — desktop up" ;;
        LOCKED)      echo "LOCKED — crossing blocked until it's unlocked" ;;
        SIGNEDOUT)   echo "SIGNED OUT — nobody logged on since the last boot" ;;
        UNREACHABLE) echo "unreachable over ssh (box off / asleep / off tailnet)" ;;
        *)           echo "unknown" ;;
    esac
}

# Ask the SYSTEM task to reattach the session to the console. Polls the state
# file it leaves behind, because `schtasks /run` gives the caller no access to a
# task's stdout. Reattaching measured ~10s on this box, hence the patient loop.
console_connect() {
    win "del /q \"$WIN_STATE\"" >/dev/null 2>&1
    win "schtasks /run /tn \"$WIN_CONSOLE_TASK\"" >/dev/null 2>&1
    local i out
    for i in $(seq 1 25); do
        sleep 2
        out="$(win "type \"$WIN_STATE\"" 2>/dev/null | tr -d '\r\n')"
        case "$out" in OK*|ALREADY|NOSESSION|FAIL*) echo "$out"; return 0 ;; esac
    done
    echo TIMEOUT
}

# Cold sign-in. RDP's only job is to CREATE the interactive session; the SYSTEM
# task then pulls it onto the console, which is what leaves the desktop unlocked
# and usable. Connecting over RDP alone would just park the session on rdp-tcp
# and leave the physical console locked — strictly worse than before.
rdp_signin() {
    if [ ! -r "$SECRET_FILE" ]; then
        echo "no password file at $SECRET_FILE" >&2
        echo "  nobody is signed in, so authenticating is unavoidable. Create it with:" >&2
        echo "    printf %s 'THE_PASSWORD' > $SECRET_FILE && chmod 600 $SECRET_FILE" >&2
        return 1
    fi
    command -v "$RDP_BIN" >/dev/null 2>&1 || { echo "$RDP_BIN not installed" >&2; return 1; }

    # /from-stdin keeps the password off the process command line, where any
    # local `ps` would expose it — and the prompt wants a newline, which the
    # secrets store deliberately does not include. -grab-keyboard stops FreeRDP
    # stealing the keyboard from the Arch desktop while it connects.
    local pw; pw="$(cat "$SECRET_FILE")"
    printf '%s\n' "$pw" | timeout 90 "$RDP_BIN" /v:"$WIN_HOST" /u:"$WIN_USER" \
        /from-stdin /cert:ignore /size:640x480 -grab-keyboard /log-level:ERROR \
        >/dev/null 2>&1 &
    local rdp_pid=$!
    unset pw

    local i st
    for i in $(seq 1 30); do
        sleep 2
        st="$(windows_session)"
        [ "$st" = UNLOCKED ] || [ "$st" = LOCKED ] && break
    done
    # The RDP window has served its purpose the moment a session exists; drop it
    # so it isn't holding the session on rdp-tcp when console_connect runs.
    kill "$rdp_pid" 2>/dev/null; wait "$rdp_pid" 2>/dev/null
    [ "$st" = UNLOCKED ] || [ "$st" = LOCKED ]
}

signin_windows() {
    local st tok
    st="$(windows_session)"
    case "$st" in
        UNREACHABLE) echo "windows: $(describe_session UNREACHABLE)"; return 1 ;;
        UNLOCKED)    echo "windows: already signed in"; return 0 ;;
    esac

    if [ "$st" = SIGNEDOUT ]; then
        echo "windows: signed out — authenticating over RDP…"
        rdp_signin || { echo "windows: RDP sign-in failed"; return 1; }
    fi

    tok="$(console_connect)"
    case "$tok" in
        OK*|ALREADY) ;;
        NOSESSION)   echo "windows: still nobody signed in"; return 1 ;;
        *)           echo "windows: could not reach the desktop ($tok)"; return 1 ;;
    esac

    # A fresh logon starts lan-mouse via its AtLogOn task, but an unlock does not
    # — and the daemon may have been dead before any of this. Make sure.
    [ "$(windows_state)" = ACTIVE ] || restart_windows >/dev/null
    echo "windows: $(describe_session "$(windows_session)") / $(describe "$(windows_state)")"
}

status_text() {
    local a w s
    a="$(arch_state)"; w="$(windows_state)"; s="$(windows_session)"
    printf '%s  %-21s %s\n' "$(icon "$a")" "Arch (this machine)"  "$(describe "$a")"
    printf '%s  %-21s %s\n' "$(icon "$w")" "Windows ($WIN_HOST)"    "$(describe "$w")"
    # A healthy daemon on a locked box still can't move the pointer, so the
    # session gets its own line rather than being folded into the daemon state.
    [ "$s" = UNLOCKED ] || printf '%s  %-21s %s\n' "$(sicon "$s")" "Windows session" "$(describe_session "$s")"
}

# ── gui ──────────────────────────────────────────────────────────────────
gui() {
    command -v zenity >/dev/null 2>&1 || { status_text; return 1; }
    local sel rc
    while :; do
        sel="$(zenity --list \
            --title="lan-mouse" \
            --width=560 --height=330 \
            --text="$(status_text)"$'\n\nPick an action, or Close.' \
            --column=id --column="Action" --column="What it does" \
            --hide-column=1 --print-column=1 \
            restart-windows "Restart Windows daemon" "kill + relaunch on $WIN_HOST (LanMouseRestart task)" \
            restart-arch    "Restart Arch daemon"    "kill + relaunch here, then re-arm crossing" \
            restart-both    "Restart both"           "Arch first, then $WIN_HOST" \
            refresh         "Refresh"                "re-check both machines" \
            2>/dev/null)"
        rc=$?
        [ $rc -ne 0 ] && return 0          # Cancel / Esc / window closed
        case "${sel%%|*}" in
            refresh|"") continue ;;
            restart-arch)    (restart_arch)    | zenity --progress --pulsate --auto-close --no-cancel --title="lan-mouse" --text="Restarting the Arch daemon…" 2>/dev/null ;;
            restart-windows) (restart_windows) | zenity --progress --pulsate --auto-close --no-cancel --title="lan-mouse" --text="Restarting the Windows daemon…" 2>/dev/null ;;
            restart-both)    ( restart_arch; restart_windows ) | zenity --progress --pulsate --auto-close --no-cancel --title="lan-mouse" --text="Restarting both daemons…" 2>/dev/null ;;
        esac
        notify "lan-mouse" "$(status_text)"
    done
}

case "${1:-gui}" in
    gui)             gui ;;
    status)          status_text ;;
    probe)           printf 'arch=%s\nwindows=%s\nsession=%s\n' "$(arch_state)" "$(windows_state)" "$(windows_session)" ;;
    arch-state)      arch_state ;;
    windows-state)   windows_state ;;
    restart-arch)    restart_arch ;;
    restart-windows) restart_windows ;;
    restart-both)    restart_arch; restart_windows ;;
    windows-session) windows_session ;;
    signin-windows)  signin_windows ;;
    *) echo "usage: ${0##*/} {gui|status|probe|arch-state|windows-state|windows-session|restart-arch|restart-windows|restart-both|signin-windows}" >&2; exit 2 ;;
esac

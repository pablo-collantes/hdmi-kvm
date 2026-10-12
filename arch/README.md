# Arch side (`arch-pc`)

Hyprland / Wayland. Drives the shared Acer XF243Y over **DisplayPort-1**, and runs
both the monitor-switch hotkey and the lan-mouse daemon.

## Install
```bash
./install.sh
```
This:
1. Builds the patched lan-mouse (`../lan-mouse`) → installs to `~/.local/bin/lan-mouse`.
2. Installs the monitor-switch + helper scripts to `~/.config/hypr/scripts/`.
3. Installs `lan-mouse/config.toml` → `~/.config/lan-mouse/config.toml` (backs up any existing).
4. Appends the keybind + autostart snippets to `~/.config/hypr/{bindings,autostart}.conf` (only if missing).

Reload Hyprland (or re-login) afterwards, then `lan-mouse cli list` to confirm the peer link.

## Files
- `hypr/scripts/switch-to-windows.sh` — `ddcutil --sn <serial> setvcp 60 0x11` (Acer → Windows/HDMI).
- `hypr/scripts/find-hdmi.sh` — diagnostic: sweeps VCP-60 values to discover your monitor's HDMI input code.
- `hypr/scripts/monitors-off.sh` — bonus DDC helper: DPMS-off all detected monitors.
- `hypr/scripts/lanmouse-kvm.sh` — lock/unlock the pointer to the machine with the mouse + restart the link (deactivates the Arch peer over the CLI and stops/relaunches the Windows daemon over ssh).
- `hypr/scripts/lanmouse-ctl.sh` — report and repair: prints the state of BOTH daemons and restarts either side (or both). Backs the bar widget, and the Windows panel calls it over ssh.
- `omarchy/plugins/pablo.lanmouse/` — omarchy-shell bar widget: link status at a glance + one-click restart.
- `hypr/panel.snippet.lua` — `Super+Alt+R` → toggle the bar widget's panel.
- `hypr/bindings.snippet.conf` — `Super+Alt+H` → switch-to-windows; `Super+Alt+P` → lock/unlock crossing; `Super+Alt+\` → restart link.
- `hypr/autostart.snippet.conf` — `exec-once` lan-mouse daemon (layer-shell capture backend).
- `lan-mouse/config.toml` — port, release-bind, the Windows client (position `left`), authorized fingerprint.

## Lock the pointer to one screen

`Super+Alt+P` toggles a **lock**: it freezes the pointer to whichever machine
physically has the mouse — the mouse/keyboard can no longer cross to the other
box. Press again to unlock. `Super+Alt+\` forces a clean restart of the whole
link if it ever wedges. The Windows side binds the same chords (`Win+Alt+P` /
`Win+Alt+\`).

**How it works.** lan-mouse's crossing is driven by the machine the mouse is
plugged into: it grabs at its screen edge and forwards to the peer. So to keep
the pointer put you have to stop *that* daemon from crossing — and the mouse can
be on either box, so `lanmouse-kvm.sh` acts on both ends using stock lan-mouse
(no fork patch required):

- **Arch daemon** — `lan-mouse cli deactivate 0`. Over the Unix socket this
  reliably destroys Arch's capture barrier in-process; the daemon stays up.
- **Windows daemon** — the CLI's fire-and-forget requests (`activate`/
  `deactivate`) don't survive the TCP socket close on Windows (only
  request/response calls like `list` do), so they can't reliably stop it.
  Instead the script *stops the daemon outright* (`taskkill`) and relaunches it
  via the `LanMouseRestart` scheduled task — i.e. lan-mouse simply shuts off on
  that side and restarts on unlock.

Both machines' hotkeys run **this** script on Arch — Hyprland runs it locally,
Windows runs it over SSH (`ssh <user>@<arch-pc> …/lanmouse-kvm.sh toggle`) — and it
reaches back to the Windows daemon over the existing **Arch → Windows** ssh link.
The Windows hotkeys therefore need key-based **Windows → Arch** SSH as well (sshd
on Arch + the Windows user's public key in `~/.ssh/authorized_keys`), the reverse
of the existing access. See `windows/README.md`.

## Which machine is off? (bar widget)

The lan-mouse daemon can be down on either box, and until now the only way to
find out was to ssh over and look — the pointer simply stopped crossing. The
bar widget answers it at a glance:

- **Bar icon** — a mouse glyph in normal bar colour while the link is up, and
  **red** the moment either daemon stops or its crossing is disarmed.
- **Click it** (or `Super+Alt+R`) for a panel naming *which* side is off and
  what exactly is wrong, with a one-click restart per machine plus "Restart
  both". Keyboard: `j`/`k` + Enter, or `a` / `w` / `b` / `s` / `r`.
- **"Windows session" row** — whether the Windows box is signed in, locked, or signed
  out, with a button that fixes it. See below; this is a different failure from
  a dead daemon and the panel reports it separately for that reason.

It is an omarchy-shell plugin (`pablo.lanmouse`) and holds no logic of its own —
it shells out to `hypr/scripts/lanmouse-ctl.sh`, the same script the Windows
side calls over ssh, so both machines report from one source of truth:

```bash
hypr/scripts/lanmouse-ctl.sh status          # human-readable, both machines
hypr/scripts/lanmouse-ctl.sh probe           # arch=<STATE> / windows=<STATE>
hypr/scripts/lanmouse-ctl.sh restart-windows # or restart-arch / restart-both
```

States are `ACTIVE` (crossing armed), `INACTIVE` (daemon up, crossing off —
locked, or not re-armed after a restart), `DOWN` (daemon not running), `NOSOCK`
(process alive but wedged) and `UNREACHABLE` (ssh failed — box off or asleep).
That distinction matters: `lanmouse-kvm.sh status` cannot tell "off because you
locked it" from "off because it died", since a lock *kills* the Windows daemon.

If omarchy-shell isn't running, `lanmouse-ctl.sh gui` puts the same status and
restart actions in a zenity dialog.

## "I rebooted Windows and still can't cross"

This is a *different* fault from a dead daemon, and it used to be invisible:
both daemons report perfectly healthy and the pointer still won't cross.

The reason is that lan-mouse injects input on the `WinSta0\Default` desktop,
while the Windows lock and sign-in screens are a **separate secure desktop**,
`WinSta0\Winlogon`. Nothing running on `Default` may touch `Winlogon` — that
isolation is precisely what stops malware typing into the password box. So
while the Windows box sits at its sign-in screen the daemon is up, connected, and
completely unable to move the pointer.

**No amount of lan-mouse configuration fixes this**, and running it as a service
makes it strictly worse: a service lives in session 0, which has no desktop at
all, so it could not capture or inject anything. The fix is not to drive the
lock screen but to make it go away:

```bash
hypr/scripts/lanmouse-ctl.sh windows-session   # UNLOCKED | LOCKED | SIGNEDOUT
hypr/scripts/lanmouse-ctl.sh signin-windows    # get it to a usable desktop
```

or the **sign-in button** in the widget's "Windows session" row (`s` on the
keyboard). Two cases, and the cheap one covers most reboots:

- **Locked** (signed in, at the lock screen) — costs **no password at all**.
  The Arch box triggers `LanMouseConsoleConnect`, a scheduled task running as
  SYSTEM on the Windows box, which disconnects the session and reattaches it to the
  console. Reattaching lands on the `Default` desktop, which is what clears the
  lock. Measured ~16s end to end.
- **Signed out** (nobody logged on since the last boot) — there is no session to
  reattach, so authenticating is unavoidable. `signin-windows` connects over RDP
  purely to *create* the session, then reattaches it as above. This needs the
  account password in `~/.config/secrets/win_pc_password`; without that file the
  command says so rather than failing obscurely.

Two details that cost real debugging time here:

- `tscon <id> /dest:console` on a session that is **already on the console**
  fails with `7045 "The requested session access is denied"`. A locked session
  still reports `Active`/`console` in `query user`, so the obvious one-liner
  silently does nothing — the session must be **disconnected first**.
- The privileged half has to be a SYSTEM scheduled task because `tscon` refuses
  `/dest:console` even for an elevated administrator. *Triggering* a task needs
  no privilege, so the Arch side drives it over plain ssh with no credentials.

Lock state is detected by whether `LogonUI.exe` is running — it exists exactly
while the secure desktop is on top, and `query user` alone cannot tell a locked
session from a usable one.

### Omarchy 4 ("Quattro") moved Hyprland config to Lua

Quattro no longer sources `~/.config/hypr/*.conf` **at all**. A `bindd =` line in
`bindings.conf` parses without error and is then silently never registered, and
the same goes for `exec-once` in `autostart.conf` — which is worth knowing when
a keybind or the daemon autostart "does nothing after a reboot". On Quattro the
equivalents live in `~/.config/hypr/bindings.lua` and `autostart.lua`; the
`.snippet.conf` files here are kept for pre-Quattro installs, and
`panel.snippet.lua` is the Quattro form.

## Escape hatch: `Ctrl+Shift+Alt+Space` releases the mouse

Hold **Ctrl + Shift + Alt + Space** (left-hand keys, all four at once) to yank the
pointer back to the machine the mouse is physically plugged into. It is not a
Hyprland or AutoHotkey binding — it is lan-mouse's own `release_bind`, checked
**on the capture side before events are forwarded** (`src/capture.rs`, in
`handle_capture_event`), which is exactly why it still works when the pointer is
stuck on the peer: the keystrokes never have to reach the other machine.

It is configured identically on both machines and both daemons print it at
startup:

```
Press [KeyLeftCtrl, KeyLeftShift, KeyLeftAlt, KeySpace] to release the mouse
```

**Why not Meta/Super.** The chord used to be Ctrl+Shift+**Meta**+Alt. Super is a
poor choice for an escape hatch: on Windows the Win key opens the Start menu, and
on Arch it is Hyprland's primary modifier — so the chord had side effects on
whichever box you were trying to escape from. Space is a normal key that
translates cleanly in both directions (`input-event/src/scancode.rs`).

**All four keys must be seen by the capture backend**, and it only tracks keys
pressed *while* capture is active — so press the whole chord after the pointer has
crossed, not before.

If the chord doesn't help because the daemon itself is wedged, escalate:
`Super+Alt+\` (restart the link) → `Super+Alt+R` (status panel, restart either
side) → `hypr/scripts/lanmouse-ctl.sh restart-both`.

**Editing it:** change `release_bind` in `lan-mouse/config.toml` on **both**
machines and restart both daemons. Note the running daemon rewrites
`~/.config/lan-mouse/config.toml` and **strips comments** when it persists state,
so the copy in this repo is the documented source of truth.

## Prerequisites
- `rustup` (to build lan-mouse), `ddcutil` (load the `i2c-dev` module, add your user to the `i2c` group), `libnotify`.
- A wlroots-based compositor (Hyprland here) — needed for the layer-shell capture and the virtual-pointer return-warp.

## Discover your monitor's serial / input codes
```bash
ddcutil detect                  # find the serial number (used to target the right monitor)
./hypr/scripts/find-hdmi.sh     # sweep to discover the HDMI VCP-60 value for your panel
```
Update `ACER_SN` and `HDMI_1` in `switch-to-windows.sh` for your monitor.

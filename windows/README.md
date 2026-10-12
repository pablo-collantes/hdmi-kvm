# Windows side (`win-pc`)

Windows 11. Drives the shared Acer XF243Y over **HDMI-1**, runs the AutoHotkey
monitor-switch hotkey, and the lan-mouse daemon.

## Prerequisites (install first — these binaries are not committed)
- **ControlMyMonitor.exe** (NirSoft, free) → place in `C:\Tools\`.
- **AutoHotkey v2** → <https://www.autohotkey.com> (installs to `C:\Program Files\AutoHotkey\v2`).
- **Microsoft Visual C++ Redistributable (x64)** — lan-mouse needs it.
- **lan-mouse.exe** — cross-built on the Arch box:
  ```bash
  # on Arch, from the repo root:
  ./windows/cross-build-exe.sh win-pc      # builds + scp's to C:\Tools\lan-mouse\
  ```

## Install
From an **elevated** PowerShell in this folder:
```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\install.ps1
```
This copies the Tools scripts + config, enables Mouse Keys, opens inbound UDP 4242, and
creates the Startup launchers (lan-mouse daemon + AutoHotkey hotkey). The daemon is
launched **hidden** — a `lan-mouse-daemon.vbs` runs it with no console window — so there's
no stray cmd prompt sitting open. Log out/in to start them.

## Files
- `Tools/switch-to-arch.bat` — `ControlMyMonitor /SetValue <serial> 60 15` (Acer → Arch/DisplayPort).
- `Tools/switch-hotkey.ahk` — AutoHotkey v2 hotkeys: `Win+Alt+H` → switch monitor to Arch; `Win+Alt+M` → re-show cursor; `Win+Alt+P` → lock/unlock the pointer to this screen; `Win+Alt+\` → restart the lan-mouse link; **`Win+Ctrl+R` → the lan-mouse status / restart panel**.
- `Tools/enable-mousekeys.ps1` — turns on Mouse Keys so the injected cursor is visible.
- `lan-mouse/config.toml` — port, the Arch client (position `right`), authorized fingerprint.
- `lan-mouse/console-connect.ps1` — reattaches the session to the console, unlocking it. Runs as SYSTEM via the `LanMouseConsoleConnect` task; driven from Arch.

## Notes
- The lan-mouse daemon must run in your **interactive logon session** to inject input —
  the Startup launcher handles that on login. (Launching it from a session-0 SSH/service
  context can't reach the desktop's input queue.)
- **No console window:** the daemon is started by `Startup\lan-mouse-daemon.vbs`
  (`WScript.Shell.Run <cmd>, 0, False` — window style 0 = hidden), instead of pointing a
  shortcut straight at the `.exe`. It still runs in the interactive session, just with no
  visible window. To see its logs for debugging, run the `.exe` directly in a terminal.
- `enable_clipboard = true` must be set on **both** machines (it is, in both configs here)
  for clipboard sync to work — never one-sided.
- Mouse Keys is what makes the cursor visible: with no physical mouse installed, Windows
  keeps the static cursor's internal display-count at -1 and never draws it.

## Escape hatch: `Ctrl+Shift+Alt+Space` releases the mouse

Hold **Ctrl + Shift + Alt + Space** (left-hand keys, all four at once) to yank the
pointer back to the machine the mouse is physically plugged into. This is not an
AutoHotkey hotkey — it is lan-mouse's own `release_bind`, checked on the capture
side *before* events are forwarded, so it works even while the pointer is stuck on
the other box. Both daemons print it at startup in `daemon.log`:

```
Press [KeyLeftCtrl, KeyLeftShift, KeyLeftAlt, KeySpace] to release the mouse
```

It must match on **both** machines (`lan-mouse/config.toml` here and on Arch);
restart both daemons after changing it. It deliberately avoids the **Win** key,
which would open the Start menu on the very box you are trying to escape from.

## Which machine is off? (`Win+Ctrl+R`)

`Win+Ctrl+R` opens a small panel — the Windows counterpart of the Arch bar widget —
showing whether **each** machine's lan-mouse daemon is running and whether crossing
is armed, with a restart for either side or both.

```
lan-mouse
This PC: Running, crossing off

✖  This PC (Windows)
     Running, crossing off
●  Arch
     Crossing armed

[Restart this PC] [Restart Arch]
[Restart both]    [Refresh]
```

**This box is probed locally** (`tasklist` + `lan-mouse.exe cli list`), never over
SSH, so the panel still opens — and can still repair this PC — when Arch is off,
asleep, or off the tailnet; the Arch half just reads `Unreachable over SSH`. The
Arch half calls that machine's `lanmouse-ctl.sh arch-state`, the same script its
own bar widget uses, so both machines report from one source of truth.

Worth having even though this box has no keyboard or mouse of its own: the physical
mouse moves between the two machines, so when it's plugged in **here** and the
**Arch** daemon is the one that died, this is the only side that can fix it —
with lan-mouse down, Arch can't send input over to press anything.

### Why "Restart this PC" goes through a scheduled task

The hotkey script starts from the Startup shortcut and therefore runs at **medium
integrity**, while the daemon runs **elevated** (`LanMouseRestart` is RunLevel
Highest — required for input injection). A medium-integrity process cannot
terminate an elevated one: `taskkill /IM lan-mouse.exe /F` returns *"Access is
denied"*, so a naive Restart button silently does nothing.

Triggering a scheduled task, however, **is** allowed from medium integrity. So
`install.ps1` registers **`LanMouseKick`** — RunLevel Highest, action
`cmd /c taskkill /IM lan-mouse.exe /F & wscript.exe …lan-mouse-daemon.vbs` — and the
panel just runs `schtasks /run /tn "\LanMouseKick"`.

### Crossing is dead until someone signs in — and why that can't be fixed here

After a reboot the Windows box sits at its sign-in screen, and the pointer will not
cross to it no matter how healthy both daemons look. This is not a lan-mouse
bug and no lan-mouse setting changes it:

- lan-mouse injects on the **`WinSta0\Default`** desktop.
- The lock and sign-in screens are a **separate secure desktop**,
  `WinSta0\Winlogon`. Nothing on `Default` may touch it — that isolation is
  exactly what stops malware typing into the password box.

Running the daemon as a Windows **service** makes it worse rather than better: a
service runs in **session 0**, which has no desktop at all, so it can neither
capture nor inject on the console. (Tailscale is unaffected and already runs as
a `LocalSystem` service — which is why ssh to this box works at the sign-in
screen even though crossing doesn't.)

So the fix is to make the lock screen go away, from Arch:

```bash
hypr/scripts/lanmouse-ctl.sh signin-windows
```

or the sign-in button in the Arch bar widget. That triggers
**`LanMouseConsoleConnect`** (registered by `install.ps1`), which runs as
**SYSTEM** — `tscon.exe` refuses `/dest:console` even for an elevated
administrator, while *triggering* a task needs no privilege at all, so the Arch
side needs no credentials for a merely-locked box.

The non-obvious part: `tscon <id> /dest:console` **fails with `7045 "The
requested session access is denied"` when the session is already on the
console**, and a locked session still reports `Active`/`console` in
`query user`. The session must therefore be **disconnected first**
(`tsdiscon`) and then reattached; the reattach is what puts `Default` back on
top and clears the lock. Budget ~10s for the switch — checking too early reports
failure on what is actually a success in progress.

If nobody has signed in since boot there is no session to reattach, and
authenticating really is unavoidable; the Arch side then connects over RDP first
purely to create the session. Lock state is detected via `LogonUI.exe`, which
runs exactly while the secure desktop is displayed.

## Lock the pointer to this screen (`Win+Alt+P`)

`Win+Alt+P` freezes the pointer to whichever machine physically has the mouse — so while
you're using this box with the mouse plugged in here, lan-mouse can't cross to Arch. Press
again to unlock. `Win+Alt+\` forces a clean restart of the link if it wedges.

lan-mouse's crossing is driven by the machine the mouse is plugged into, so locking means
stopping *that* daemon from crossing. When the mouse is on Windows that's the Windows
daemon, which is stopped outright (`taskkill`) and relaunched on unlock via the
`LanMouseRestart` task (the CLI's `deactivate` isn't reliable over the Windows TCP socket).
The lock logic lives in one place — the Arch-side control script — so both machines' hotkeys
run it, this box **over SSH**, and it reaches back to the Windows daemon over the existing
Arch → Windows ssh link:
```
ssh <arch> ~/.config/hypr/scripts/lanmouse-kvm.sh toggle   # or: restart
```

### One-time setup: Windows → Arch SSH
The build/deploy flow already uses **Arch → Windows** SSH; these hotkeys need the reverse.
On the Windows box:
1. Generate a key if none: `ssh-keygen -t ed25519` (→ `%USERPROFILE%\.ssh\id_ed25519`).
2. Add its `.pub` to the Arch user's `~/.ssh/authorized_keys` (ensure `sshd` runs on Arch).
3. Set `ArchSSH := "user@arch-host"` at the top of `switch-hotkey.ahk` (hostname or tailscale IP).

### Reloading the hotkeys without a reboot
`switch-hotkey.ahk` starts from the Startup shortcut at logon. `install.ps1` registers
**`LanMouseAhkReload`** for reloading it after an edit (this box is headless):

```
taskkill /IM AutoHotkey64.exe /F
schtasks /run /tn "\LanMouseAhkReload"
```

The task runs a **detached `wscript` `.vbs`** launcher — the same trick the lan-mouse
daemon uses to reach the desktop session, because a direct `schtasks`-launched `.exe`
doesn't persist in session 1. It is deliberately RunLevel **Limited**, matching the
Startup shortcut's medium integrity, so a reloaded script behaves exactly like the one
that starts at logon.

Validate before reloading — a syntax error would pop a modal dialog on a box with no
keyboard to dismiss it:
```
"C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" /validate C:\Tools\switch-hotkey.ahk
```

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
- `Tools/switch-hotkey.ahk` — `Win+Alt+H` → switch-to-arch (AutoHotkey v2).
- `Tools/enable-mousekeys.ps1` — turns on Mouse Keys so the injected cursor is visible.
- `lan-mouse/config.toml` — port, the Arch client (position `right`), authorized fingerprint.

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

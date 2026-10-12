<#
  Windows (win-pc) setup for the HDMI software switcher + lan-mouse KVM.
  Run from the repo's windows\ folder in an ELEVATED PowerShell:

      Set-ExecutionPolicy -Scope Process Bypass -Force
      .\install.ps1

  Prerequisites you must provide first (binaries are NOT committed — see README):
    * C:\Tools\ControlMyMonitor.exe        (NirSoft, free)
    * AutoHotkey v2                          (https://www.autohotkey.com)
    * Microsoft Visual C++ Redistributable x64
    * C:\Tools\lan-mouse\lan-mouse.exe       (cross-built on Arch via
      windows\cross-build-exe.sh, then copied over — or let that script scp it)
#>
$ErrorActionPreference = 'Stop'
$Here  = $PSScriptRoot
$Tools = 'C:\Tools'
$Lm    = Join-Path $Tools 'lan-mouse'

function Say($m){  Write-Host "==> $m" -ForegroundColor Green }
function Warn($m){ Write-Host "[!] $m"  -ForegroundColor Yellow }

Say "Creating $Tools ..."
New-Item -ItemType Directory -Force -Path $Tools, $Lm | Out-Null

Say "Copying Tools scripts (.bat / .ahk / .ps1) ..."
Copy-Item (Join-Path $Here 'Tools\*') $Tools -Force -Recurse

Say "Installing lan-mouse config ..."
$cfgDst = Join-Path $Lm 'config.toml'
if (Test-Path $cfgDst) { Copy-Item $cfgDst "$cfgDst.bak" -Force; Warn "Existing config backed up to config.toml.bak" }
Copy-Item (Join-Path $Here 'lan-mouse\config.toml') $cfgDst -Force
# ${cfgDst} must be brace-delimited: a bare "$cfgDst:" is parsed as a scope
# qualifier (as in $env:PATH), and since PowerShell refuses to run a file that
# fails to parse, that one colon aborts the whole installer before line 1.
Warn "EDIT ${cfgDst}: set the peer IP under [[clients]] and its cert fingerprint under [authorized_fingerprints]."


Say "Installing console-connect helper ..."
Copy-Item (Join-Path $Here 'lan-mouse\console-connect.ps1') (Join-Path $Lm 'console-connect.ps1') -Force

Say "Enabling Mouse Keys (makes the injected cursor visible with no physical mouse) ..."
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Tools 'enable-mousekeys.ps1')
# The SPI_SETMOUSEKEYS effect is per-session and does NOT reliably survive a reboot,
# so re-apply it on every logon via a hidden AtLogOn task (no delay). Without this,
# the Windows cursor goes invisible again after each restart. Kept at RunLevel
# Limited (medium integrity) on purpose: SystemParametersInfo applies to the
# current user session, and an elevated process's setting-change broadcast can be
# filtered (UIPI) before it reaches the medium-integrity desktop.
$meMK        = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$mkVbs       = Join-Path $Tools 'enable-mousekeys.vbs'
$mkAction    = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"{0}"' -f $mkVbs)
$mkTrigger   = New-ScheduledTaskTrigger -AtLogOn
$mkPrincipal = New-ScheduledTaskPrincipal -UserId $meMK -LogonType Interactive -RunLevel Limited
$mkSettings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName 'LanMouseMouseKeys' -Action $mkAction -Trigger $mkTrigger -Principal $mkPrincipal -Settings $mkSettings -Force `
  -Description 'Re-enable Mouse Keys at logon so the lan-mouse cursor stays visible' | Out-Null
Say "Registered Mouse Keys logon task: LanMouseMouseKeys (re-applies at logon)."

# ── Keep the session unlocked so lan-mouse can keep injecting ────────────────
# A normal program cannot inject mouse/keyboard into the Windows lock screen (it is an
# isolated SYSTEM-owned secure desktop), so an idle auto-lock silently breaks lan-mouse
# until you unlock. Disable the idle lock and prevent sleep on AC so the interactive
# session stays alive. Conservative: password-on-wake + screensaver are left untouched.
# (Security trade-off: the desktop stays unlocked when idle. Comment out to keep locking.)
Say "Disabling idle auto-lock + AC sleep so lan-mouse keeps working ..."
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v InactivityTimeoutSecs /t REG_DWORD /d 0 /f | Out-Null
powercfg -change standby-timeout-ac 0
powercfg -change hibernate-timeout-ac 0

Say "Adding firewall rule (inbound UDP 4242) ..."
if (-not (Get-NetFirewallRule -DisplayName 'lan-mouse UDP 4242' -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -DisplayName 'lan-mouse UDP 4242' -Direction Inbound -Protocol UDP -LocalPort 4242 -Action Allow | Out-Null
} else { Say "Firewall rule already present." }

# ── Startup shortcuts ────────────────────────────────────────────────────
$Startup = [Environment]::GetFolderPath('Startup')
$ws = New-Object -ComObject WScript.Shell
function New-StartupShortcut($name, $target, $args, $workdir) {
  $lnk = $ws.CreateShortcut((Join-Path $Startup $name))
  $lnk.TargetPath = $target; $lnk.Arguments = $args; $lnk.WorkingDirectory = $workdir
  $lnk.Save(); Say "Startup shortcut created: $name"
}

# lan-mouse daemon — launched HIDDEN (no console window) but still in your
# interactive logon session, which input injection requires. A .vbs runs the exe
# via wscript with window style 0 = no window at all. Autostart is an AtLogOn
# scheduled task (NOT a Startup-folder item): it runs in the interactive session
# with a short delay so the desktop/input queue is ready, and the same task can be
# (re)triggered manually or over SSH — where a direct launch would land in a
# non-interactive session that can't reach the desktop. cross-build-exe.sh runs it
# after pushing a new .exe.
$exe = Join-Path $Lm 'lan-mouse.exe'
if (Test-Path $exe) {
  $pem = Join-Path $Lm 'lan-mouse.pem'   # generated on first run if absent
  $logPath = Join-Path $Lm 'daemon.log'
  # The daemon runs HIDDEN (no console) in the interactive session. We go through a
  # tiny .cmd so stdout/stderr can be redirected to a log file: this box is headless
  # (no physical keyboard/mouse — only reachable via lan-mouse), so daemon.log is the
  # only practical way to see what it's doing. The .vbs runs the .cmd window-style 0.
  $runCmd = @"
@echo off
"$exe" --config "$cfgDst" --cert-path "$pem" daemon > "$logPath" 2>&1
"@
  $runCmdPath = Join-Path $Lm 'lan-mouse-run.cmd'
  Set-Content -Path $runCmdPath -Value $runCmd -Encoding ASCII
  $launch    = 'cmd /c "{0}"' -f $runCmdPath
  $launchEsc = $launch -replace '"', '""'   # VBS escapes a literal " by doubling it
  $vbs = @"
' Auto-generated by install.ps1 — runs lan-mouse-run.cmd (the daemon, output to
' daemon.log) with NO console window, in the interactive session (Run style 0).
CreateObject("WScript.Shell").Run "$launchEsc", 0, False
"@
  $vbsPath = Join-Path $Lm 'lan-mouse-daemon.vbs'
  Set-Content -Path $vbsPath -Value $vbs -Encoding ASCII
  Say "Hidden daemon launcher created: $vbsPath (logs to $logPath)"
  # Remove older Startup-folder launchers a previous install may have created —
  # autostart is the AtLogOn task now, and a leftover Startup copy would race it and
  # spawn a second daemon.
  foreach ($old in 'lan-mouse-daemon.vbs','lan-mouse-daemon.lnk') {
    $p = Join-Path $Startup $old
    if (Test-Path $p) { Remove-Item $p -Force; Warn "Removed old Startup item: $old" }
  }

  # Autostart + on-demand restart, INTERACTIVE: starts the hidden daemon into the
  # interactive desktop session at every logon (no delay — start as early as possible),
  # and can also be triggered manually / over SSH:  schtasks /run /tn LanMouseRestart
  $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
  $action    = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"{0}"' -f $vbsPath)
  $trigger   = New-ScheduledTaskTrigger -AtLogOn
  # RunLevel MUST be Highest (elevated / high integrity). A medium-integrity
  # daemon (RunLevel Limited) is on the correct WinSta0\Default desktop, but the
  # OS SILENTLY denies its input: SetCursorPos returns FALSE and SendInput is
  # accepted (returns 1) yet has no effect — the peer connects + acknowledges but
  # not one keystroke/mouse move reaches the screen. Elevated, injection works.
  # (Scheduled tasks run elevated with no UAC prompt; the logon user must be an admin.)
  $principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Highest
  $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
  Register-ScheduledTask -TaskName 'LanMouseRestart' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force `
    -Description 'Start/restart lan-mouse daemon hidden in the interactive session (autostart at logon)' | Out-Null
  Say "Registered autostart task: LanMouseRestart (AtLogOn, elevated; manual run:  schtasks /run /tn LanMouseRestart)"
  # LanMouseKick - "restart the daemon NOW" (kill + relaunch), same elevated
  # principal. The Win+Ctrl+R status panel runs at MEDIUM integrity, because it
  # starts from the Startup shortcut, and a medium-integrity process CANNOT
  # taskkill the elevated daemon: taskkill returns "Access is denied" and the
  # Restart button would silently do nothing. Triggering a scheduled task *is*
  # allowed from medium integrity, so the panel calls this task instead.
  $kickAction = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument ('/c taskkill /IM lan-mouse.exe /F & wscript.exe "{0}"' -f $vbsPath)
  Register-ScheduledTask -TaskName 'LanMouseKick' -Action $kickAction -Principal $principal -Settings $settings -Force `
    -Description 'Restart the lan-mouse daemon now: kill it and relaunch hidden in the interactive session. Triggerable from a medium-integrity process (the status panel).' | Out-Null
  Say "Registered restart task: LanMouseKick (manual run:  schtasks /run /tn LanMouseKick)"

  # LanMouseConsoleConnect - get this box from a lock / sign-in screen to a
  # usable desktop, on request from the Arch side. It exists because lan-mouse
  # fundamentally CANNOT drive the sign-in screen: that is a separate secure
  # desktop (WinSta0\Winlogon), while lan-mouse's hooks and SendInput live on
  # WinSta0\Default, and nothing on Default may touch Winlogon. So rather than
  # trying to type into the lock screen, this makes the lock screen go away by
  # reattaching the session to the console.
  #
  # Principal is SYSTEM rather than $principal: tscon.exe refuses /dest:console
  # even for an elevated administrator token. *Triggering* a task needs no
  # privilege, so the Arch box drives this over plain ssh with no credentials.
  #
  # No trigger - it only ever runs on demand (schtasks /run).
  $ccScript    = Join-Path $Lm 'console-connect.ps1'
  $ccAction    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                   -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $ccScript)
  $ccPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  Register-ScheduledTask -TaskName 'LanMouseConsoleConnect' -Action $ccAction -Principal $ccPrincipal -Settings $settings -Force `
    -Description 'Reattach the interactive session to the physical console, unlocking it. Lets the Arch box recover pointer crossing after a reboot or lock without anyone touching this machine.' | Out-Null
  Say "Registered console task: LanMouseConsoleConnect (manual run:  schtasks /run /tn LanMouseConsoleConnect)"
} else {
  Warn "lan-mouse.exe not found at $exe — cross-build it on Arch (windows\cross-build-exe.sh), copy it over, then re-run."
}

# AutoHotkey HDMI hotkey (Win+Alt+H -> switch monitor back to Arch)
$ahk = 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe'
if (Test-Path $ahk) {
  New-StartupShortcut 'hdmi-switch-hotkey.lnk' $ahk "`"$(Join-Path $Tools 'switch-hotkey.ahk')`"" $Tools
  # Reloading the hotkeys after an edit needs a launch INTO the interactive
  # session - this box is headless, and a direct schtasks-launched .exe does not
  # persist in session 1 (the detached wscript -> .vbs trick does). RunLevel
  # Limited deliberately matches the Startup shortcut's medium integrity, so the
  # reloaded script behaves identically to the one that starts at logon.
  $launchVbs = Join-Path $Tools 'launch-ahk.vbs'
  $launchVbsBody = @"
' Auto-generated by install.ps1 - launch the AutoHotkey hotkeys detached, in the
' interactive session. wscript exits immediately; AutoHotkey persists.
CreateObject("WScript.Shell").Run """$ahk"" ""$(Join-Path $Tools 'switch-hotkey.ahk')""", 0, False
"@
  Set-Content -Path $launchVbs -Value $launchVbsBody -Encoding ASCII
  $ahkAction    = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"{0}"' -f $launchVbs)
  $ahkPrincipal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited
  Register-ScheduledTask -TaskName 'LanMouseAhkReload' -Action $ahkAction -Principal $ahkPrincipal -Settings $settings -Force `
    -Description 'Reload switch-hotkey.ahk in the interactive session after editing it (headless box).' | Out-Null
  Say "Registered hotkey-reload task: LanMouseAhkReload (after editing the .ahk:  taskkill /IM AutoHotkey64.exe /F; schtasks /run /tn LanMouseAhkReload)"
} else {
  Warn "AutoHotkey v2 not found at $ahk — install it, then re-run to create the hotkey shortcut."
}

Say "Done. Log out/in (or launch the Startup shortcuts) to start the daemon + hotkey."
Say "Verify:  Get-Process lan-mouse   then press Win+Alt+H to switch the monitor to Arch."
Say "Win+Ctrl+R opens the lan-mouse status / restart panel for both machines."

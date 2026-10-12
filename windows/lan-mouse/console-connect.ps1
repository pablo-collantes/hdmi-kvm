# ── Hand the user's session back to the physical console, unlocked ────────
# Registered as the SYSTEM scheduled task \LanMouseConsoleConnect. It exists so
# the Arch box can get this machine from a lock/sign-in screen to a usable
# desktop without anyone touching it - handy for a box with no keyboard attached.
#
# Why lan-mouse can't just do this itself: the sign-in screen is a separate
# secure desktop (WinSta0\Winlogon), while lan-mouse's low-level hooks and
# SendInput live on WinSta0\Default. Nothing on Default can reach Winlogon -
# that isolation is what stops malware typing into the password box. So instead
# of driving the lock screen we make it go away, by reattaching the session.
#
# Why SYSTEM: tscon.exe refuses /dest:console for an ordinary administrator
# token. *Triggering* a scheduled task is allowed from a plain ssh shell, so the
# Arch side needs neither elevation nor credentials.
#
# THE KEY DETAIL, found the hard way: `tscon <id> /dest:console` on a session
# that is already ON the console fails with 7045 "The requested session access
# is denied" - and a LOCKED console session is still Active/console, so the
# obvious one-liner does nothing. The session must be DISCONNECTED first; a
# reattach then lands on the Default desktop, which is what clears the lock.
#
# `schtasks /run` gives the caller no access to a task's stdout, so the result
# token is also written to console-connect.state. lanmouse-ctl.sh deletes that
# file before triggering and polls for it, so a stale result from an earlier run
# can't be mistaken for this one's.
#
# Prints ONE token line (and writes it to .state), parsed by lanmouse-ctl.sh:
#   OK <id>     session <id> is on the console and unlocked
#   ALREADY     already on the console and unlocked - nothing to do
#   NOSESSION   nobody signed in; the caller must authenticate (RDP) first
#   FAIL <why>  still not usable; <why> is the last observed state

$ErrorActionPreference = 'Continue'
$target = $env:LANMOUSE_USER
if (-not $target) { $target = $env:USERNAME }

$stateFile = Join-Path $PSScriptRoot 'console-connect.state'
$logFile   = Join-Path $PSScriptRoot 'console-connect.log'

function Log($m) {
    try { Add-Content -LiteralPath $logFile -Value ("{0}  {1}" -f (Get-Date -Format s), $m) } catch { }
}
function Finish($token, $code) {
    Log "=> $token"
    # -NoNewline keeps the token a clean single line for the shell-side parser.
    try { Set-Content -LiteralPath $stateFile -Value $token -Encoding ASCII -NoNewline -Force } catch { }
    Write-Output $token
    exit $code
}

# `query user` is fixed-width text with two parsing traps: the CURRENT session is
# prefixed with '>', and a DISCONNECTED session leaves the SESSIONNAME column
# BLANK. Both shift whitespace-split token positions, which is why the obvious
# `for /f "tokens=2"` parse silently grabs the wrong field. Anchor on the
# (id, state) pair instead - that adjacency holds in every variant.
function Get-Session {
    $r = [pscustomobject]@{ Id = $null; Name = ''; State = '' }
    foreach ($line in (query user 2>$null)) {
        if ($line -notmatch "^[>\s]*$([regex]::Escape($target))\s") { continue }
        if ($line -match '\s(\d+)\s+(Active|Disc)\b') {
            $r.Id = $matches[1]; $r.State = $matches[2]
            if ($line -match '\s(console|rdp-tcp#\d+)\s') { $r.Name = $matches[1] }
        }
        break
    }
    return $r
}

# LogonUI.exe is alive exactly while the secure desktop (lock or sign-in screen)
# is on top, and exits once the session unlocks - the standard remote lock probe.
function Test-Locked { [bool](Get-Process -Name LogonUI -ErrorAction SilentlyContinue) }

# Success is judged by observation, not by exit codes: tscon reports failure on
# stdout while still exiting 0, so its return value can't be trusted.
function Test-Usable {
    $s = Get-Session
    return ($s.Id -and $s.Name -eq 'console' -and $s.State -eq 'Active' -and -not (Test-Locked))
}

$s = Get-Session
Log ("start: id=$($s.Id) name='$($s.Name)' state=$($s.State) locked=" + (Test-Locked))
if (-not $s.Id) { Finish 'NOSESSION' 2 }
if (Test-Usable) { Finish 'ALREADY' 0 }

# A session sitting ON the console (locked) must be disconnected before it can be
# reattached; one already Disc or parked on rdp-tcp can be reattached directly.
if ($s.Name -eq 'console' -and $s.State -eq 'Active') {
    Log "tsdiscon $($s.Id)"
    & tsdiscon.exe $s.Id 2>&1 | ForEach-Object { Log "  tsdiscon: $_" }
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 250
        if ((Get-Session).State -eq 'Disc') { break }
    }
}

Log "tscon $($s.Id) /dest:console"
& tscon.exe $s.Id /dest:console 2>&1 | ForEach-Object { Log "  tscon: $_" }

# Reattaching the console is NOT instant - the desktop switch and LogonUI
# teardown were measured taking well over 8s on this box, so poll patiently.
# Finishing early here is the difference between "FAIL" and a working desktop.
for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 500
    if (Test-Usable) { Finish "OK $($s.Id) after=$([int](($i + 1) * 500))ms" 0 }
    if ($i % 4 -eq 3) { $p = Get-Session; Log ("  poll $i name='$($p.Name)' state=$($p.State) locked=" + (Test-Locked)) }
}

$f = Get-Session
Finish ("FAIL name='$($f.Name)' state=$($f.State) locked=" + (Test-Locked)) 1

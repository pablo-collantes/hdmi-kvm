#Requires AutoHotkey v2.0
#SingleInstance Force
; ---------------------------------------------------------------------------
;  Software HDMI switcher + lan-mouse helpers - Windows side
;
;  Win+Alt+H  ->  switch the shared Acer XF243Y back to the Arch PC (DisplayPort-1).
;  This mirrors the Arch-side SUPER+ALT+H, which switches the monitor to Windows.
;  "Each side switches the monitor away from itself" - reliable because the DDC
;  write always travels over the currently-active video link.
;
;  Win+Alt+M  ->  re-run the hidden Mouse Keys script to force the cursor visible.
;  Manual recovery for when lan-mouse control works but the cursor is invisible
;  (the post-boot Mouse Keys apply lost its race with the session coming up). It
;  re-invokes the SAME hidden launcher the LanMouseMouseKeys logon task uses, so
;  there's one source of truth. Injected keystrokes count as real input, so this
;  fires even when the combo is sent over lan-mouse from Arch. Non-blocking; the
;  cursor reappears within ~2s (and the launcher keeps re-asserting for ~20s).
;
;  Win+Alt+P  ->  lock / unlock the pointer to the CURRENT screen. While locked,
;  lan-mouse won't cross back to Arch AND won't drag you off Windows — you stay
;  put. Press again to unlock. Win+Alt+\  ->  unlock + restart the link if it
;  gets stuck. Both drive the ONE Arch daemon over SSH (Arch owns the pointer
;  grab); the toggle is the patched fork's "hold" mode. Injected keystrokes count
;  as real input, so these fire even while you're being controlled from Arch.
; ---------------------------------------------------------------------------

; Arch SSH target for the lan-mouse KVM lock/restart hotkeys below. Change to
; your Arch user@host (or its tailscale IP) if different.
ArchSSH := "YOUR_USER@arch-pc"   ; <-- your Arch box: ssh user@host

#!h:: {
    RunWait('"C:\Tools\switch-to-arch.bat"', "C:\Tools", "Hide")
}

#!m:: {
    Run('wscript.exe "C:\Tools\enable-mousekeys.vbs"', "C:\Tools", "Hide")
}

; Win+Alt+P -> lock/unlock the pointer to the CURRENT screen (stay on Windows).
; Win+Alt+\ -> unlock + restart the lan-mouse link. Both drive the Arch daemon
; over SSH; the daemon itself pops the on-screen lock/unlock notification.
#!p:: LanMouseKvm("toggle", "Lock / unlock this screen")
#!\:: LanMouseKvm("restart", "Restarting lan-mouse link...")

LanMouseKvm(action, label) {
    global ArchSSH
    ; -o BatchMode=yes: never prompt (headless); accept-new trusts Arch's host
    ; key on first use. Window hidden; runs the Arch-side control script.
    Run('ssh -o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=accept-new ' . ArchSSH . ' ~/.config/hypr/scripts/lanmouse-kvm.sh ' . action, , "Hide")
    TrayTip(label, "lan-mouse KVM")
}

; ---------------------------------------------------------------------------
;  Win+Ctrl+R  ->  lan-mouse status / restart panel
;
;  The Windows counterpart of the Arch bar widget: it says WHICH machine's
;  lan-mouse daemon is off and restarts either side.
;
;  This box is probed LOCALLY (tasklist + the lan-mouse CLI), never over SSH, so
;  the panel still opens - and can still repair THIS PC - when Arch is off,
;  asleep, or off the tailnet. Only the Arch half needs SSH, and it degrades to
;  "Unreachable" instead of hanging the panel.
;
;  Worth having even though this box has no keyboard/mouse of its own: the
;  physical mouse moves between the two machines, so when it is plugged in HERE
;  and the ARCH daemon is the one that died, this is the only side that can fix
;  it (with lan-mouse down, Arch can't send input over here to press anything).
; ---------------------------------------------------------------------------

; Script-level state. NOTE: AutoHotkey v2 removed super-globals - a function
; sees its OWN unassigned local unless it declares `global`, and reading that
; local throws "This local variable has not been assigned a value". So every
; function below re-declares what it touches; do not drop those lines.
LmExe   := "C:\Tools\lan-mouse\lan-mouse.exe"
LmKick  := "\LanMouseKick"   ; elevated "restart the daemon now" task
LmArch  := "~/.config/hypr/scripts/lanmouse-ctl.sh"
LmPanel := ""                 ; the Gui while open, "" while closed
LmUi    := Map()              ; control references, keyed by name

^#r:: LanMouseTogglePanel()

LanMouseTogglePanel() {
    global LmPanel, LmUi
    if (LmPanel != "") {
        LanMouseClosePanel()
        return
    }
    LmPanel := Gui("+AlwaysOnTop -MaximizeBox -MinimizeBox", "lan-mouse")
    LmPanel.MarginX := 16
    LmPanel.MarginY := 14
    LmPanel.BackColor := "1A1B26"
    LmPanel.OnEvent("Close", (*) => LanMouseClosePanel())
    LmPanel.OnEvent("Escape", (*) => LanMouseClosePanel())

    ; Position with y+N (below the previous control), never yp+N (relative to its
    ; TOP) - yp left each machine's state line floating nearer the NEXT machine's
    ; name than its own, which is exactly the thing this panel exists to make clear.
    LmPanel.SetFont("s13 bold cA9B1D6", "Segoe UI")
    LmPanel.Add("Text", "w330", "lan-mouse")

    LmPanel.SetFont("s9 norm c707880", "Segoe UI")
    LmUi["summary"] := LmPanel.Add("Text", "xm y+2 w330", "Checking both machines...")

    ; --- this PC -----------------------------------------------------------
    LmPanel.SetFont("s10 bold cA9B1D6", "Segoe UI")
    LmUi["winTitle"] := LmPanel.Add("Text", "xm y+16 w330", "This PC (Windows)")
    LmPanel.SetFont("s9 norm c707880", "Segoe UI")
    LmUi["winState"] := LmPanel.Add("Text", "xm y+1 w330", "Checking...")

    ; --- the Arch box ------------------------------------------------------
    LmPanel.SetFont("s10 bold cA9B1D6", "Segoe UI")
    LmUi["archTitle"] := LmPanel.Add("Text", "xm y+16 w330", "Arch")
    LmPanel.SetFont("s9 norm c707880", "Segoe UI")
    LmUi["archState"] := LmPanel.Add("Text", "xm y+1 w330", "Checking...")

    ; --- actions -----------------------------------------------------------
    LmPanel.SetFont("s9 norm", "Segoe UI")
    bWin  := LmPanel.Add("Button", "xm y+18 w160", "Restart this PC")
    bArch := LmPanel.Add("Button", "x+10 yp w160", "Restart Arch")
    bBoth := LmPanel.Add("Button", "xm y+8 w160", "Restart both")
    bRef  := LmPanel.Add("Button", "x+10 yp w160", "Refresh")

    bWin.OnEvent("Click",  (*) => LanMouseAction("windows"))
    bArch.OnEvent("Click", (*) => LanMouseAction("arch"))
    bBoth.OnEvent("Click", (*) => LanMouseAction("both"))
    bRef.OnEvent("Click",  (*) => LanMouseAction("refresh"))

    LmPanel.SetFont("s8 norm c707880", "Segoe UI")
    LmUi["status"] := LmPanel.Add("Text", "xm y+12 w330", "")

    LmPanel.Show("AutoSize")
    ; Let the window paint before the (blocking) probe runs.
    SetTimer(LanMouseRefresh, -60)
}

LanMouseClosePanel() {
    global LmPanel, LmUi
    if (LmPanel = "")
        return
    try LmPanel.Destroy()
    LmPanel := ""
    LmUi := Map()
}

; Run a command hidden and return {code, out}. Output goes via a temp file
; rather than WScript.Shell.Exec, which flashes a console window.
LanMouseRun(cmd) {
    tmp := A_Temp "\lanmouse-panel-" A_TickCount ".out"
    code := RunWait(A_ComSpec ' /c ' cmd ' > "' tmp '" 2>&1', , "Hide")
    out := ""
    try out := FileRead(tmp)
    try FileDelete(tmp)
    return { code: code, out: out }
}

; This PC, checked locally: ACTIVE | INACTIVE | DOWN.
; Two plain commands instead of one `&&`/`||` chain - compound cmd lines get
; mangled once they are wrapped in `cmd /c ... > file`.
LanMouseWindowsState() {
    global LmExe
    r := LanMouseRun('tasklist /FI "IMAGENAME eq lan-mouse.exe" /fo csv /nh')
    if !InStr(r.out, "lan-mouse.exe")
        return "DOWN"
    c := LanMouseRun('"' LmExe '" cli list')
    return InStr(c.out, "active: true") ? "ACTIVE" : "INACTIVE"
}

; The Arch box, over SSH. Its own script is the source of truth for that side;
; a non-zero ssh exit means the box is unreachable, not that the daemon is down.
LanMouseArchState() {
    global ArchSSH, LmArch
    r := LanMouseRun('ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new ' ArchSSH ' ' LmArch ' arch-state')
    if (r.code != 0)
        return "UNREACHABLE"
    ; Compare the whole token, never InStr - "ACTIVE" is a substring of "INACTIVE",
    ; so a substring test reports a disarmed link as a healthy one.
    state := Trim(r.out, " `t`r`n")
    if (state = "ACTIVE" || state = "INACTIVE" || state = "DOWN" || state = "NOSOCK")
        return state
    return "UNREACHABLE"
}

LanMouseStateText(state) {
    switch state {
        case "ACTIVE":      return "Crossing armed"
        case "INACTIVE":    return "Running, crossing off"
        case "DOWN":        return "Daemon not running"
        case "NOSOCK":      return "Wedged, no CLI socket"
        case "UNREACHABLE": return "Unreachable over SSH"
    }
    return "Unknown"
}

LanMouseRefresh() {
    global LmPanel, LmUi
    if (LmPanel = "")
        return
    win  := LanMouseWindowsState()
    arch := LanMouseArchState()
    if (LmPanel = "")           ; closed while we were probing
        return

    ok   := Chr(0x25CF)   ; filled circle
    bad  := Chr(0x2716)   ; heavy multiplication x
    LmUi["winTitle"].Value  := (win = "ACTIVE" ? ok : bad) . "  This PC (Windows)"
    LmUi["archTitle"].Value := (arch = "ACTIVE" ? ok : bad) . "  Arch"
    LmUi["winState"].Value  := "     " . LanMouseStateText(win)
    LmUi["archState"].Value := "     " . LanMouseStateText(arch)
    LmUi["winState"].SetFont(win = "ACTIVE" ? "c707880" : "cF7768E")
    LmUi["archState"].SetFont(arch = "ACTIVE" ? "c707880" : "cF7768E")

    if (win = "ACTIVE" && arch = "ACTIVE")
        LmUi["summary"].Value := "Link up - both daemons running"
    else if (win != "ACTIVE" && arch != "ACTIVE")
        LmUi["summary"].Value := "Link down on both machines"
    else if (win != "ACTIVE")
        LmUi["summary"].Value := "This PC: " . LanMouseStateText(win)
    else
        LmUi["summary"].Value := "Arch: " . LanMouseStateText(arch)
}

; Restart this PC locally (no SSH - that is the whole point), Arch over SSH.
LanMouseAction(which) {
    global LmPanel, LmUi
    if (LmPanel = "")
        return
    labels := Map("windows", "Restarting this PC...", "arch", "Restarting Arch...",
                  "both", "Restarting both...", "refresh", "Checking...")
    LmUi["status"].Value := labels[which]
    SetTimer(() => LanMouseDoAction(which), -60)
}

LanMouseDoAction(which) {
    global ArchSSH, LmArch, LmKick, LmPanel, LmUi
    if (which = "windows" || which = "both") {
        ; Deliberately NOT taskkill from here. This script runs at MEDIUM
        ; integrity (it starts from the Startup shortcut) while the daemon runs
        ; elevated, so a direct taskkill returns "Access is denied" and the
        ; button would silently do nothing. LanMouseKick is a RunLevel-Highest
        ; task that does the kill + relaunch, and *triggering* a task is allowed
        ; from medium integrity. (install.ps1 registers it.)
        LanMouseRun('schtasks /run /tn "' LmKick '"')
        Sleep(3000)
    }
    if (which = "arch" || which = "both")
        LanMouseRun('ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new ' ArchSSH ' ' LmArch ' restart-arch')
    if (LmPanel = "")
        return
    LmUi["status"].Value := which = "refresh" ? "" : "Done"
    LanMouseRefresh()
}

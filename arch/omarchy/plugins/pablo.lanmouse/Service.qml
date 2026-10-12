import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// State for the lan-mouse bar widget.
//
// All the actual logic — probing both daemons, restarting either one — lives in
// the shell script this drives (`hypr/scripts/lanmouse-ctl.sh`), which the
// Windows box also calls over ssh. Keeping it there means one source of truth
// for "is the link up" instead of a second implementation in QML.
Item {
  id: root

  property var settings: ({})

  readonly property string home: Quickshell.env("HOME")
  readonly property string ctlPath: home + "/.config/hypr/scripts/lanmouse-ctl.sh"

  // ACTIVE | INACTIVE | DOWN | NOSOCK | UNREACHABLE, or CHECKING before the
  // first probe lands. See lanmouse-ctl.sh for what each one means.
  property string archState: "CHECKING"
  property string windowsState: "CHECKING"
  // UNLOCKED | LOCKED | SIGNEDOUT | UNREACHABLE. Tracked separately from the
  // daemon state because the two fail independently: after a reboot the Windows
  // daemon is usually fine and the box is simply sitting at the sign-in screen.
  property string windowsSession: "CHECKING"
  property bool refreshing: false
  property string actionStatus: ""
  property string lastError: ""
  property string pendingAction: ""

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 30, 5, 3600)
  readonly property string peerName: String(setting("peerName", "Windows"))
  readonly property bool busy: probeProcess.running || actionProcess.running

  // The link only carries the pointer when BOTH daemons are up, the peer client
  // is armed on each side, AND the Windows box is at a real desktop — anything
  // less is a degraded state worth colouring the bar icon for.
  //
  // That last condition is easy to miss: lan-mouse injects on WinSta0\Default,
  // but the lock and sign-in screens are a separate secure desktop it may not
  // touch. A locked box therefore swallows the pointer no matter how healthy
  // both daemons look — the session is part of "is the link up", not a footnote.
  readonly property bool sessionReady: windowsSession === "UNLOCKED"
  readonly property bool needsSignIn: windowsSession === "LOCKED" || windowsSession === "SIGNEDOUT"
  readonly property bool linkUp: archState === "ACTIVE" && windowsState === "ACTIVE" && sessionReady
  readonly property bool known: archState !== "CHECKING" && windowsState !== "CHECKING" && windowsSession !== "CHECKING"
  readonly property bool degraded: known && !linkUp

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    if (n < min) n = min
    if (n > max) n = max
    return n
  }

  function stateLabel(state) {
    switch (state) {
      case "ACTIVE":      return "Crossing armed"
      case "INACTIVE":    return "Running, crossing off"
      case "DOWN":        return "Daemon not running"
      case "NOSOCK":      return "Wedged, no CLI socket"
      case "UNREACHABLE": return "Unreachable over SSH"
      case "CHECKING":    return "Checking…"
    }
    return "Unknown"
  }

  function sessionLabel(state) {
    switch (state) {
      case "UNLOCKED":    return "Signed in"
      case "LOCKED":      return "Locked"
      case "SIGNEDOUT":   return "Signed out"
      case "UNREACHABLE": return "Unreachable over SSH"
      case "CHECKING":    return "Checking…"
    }
    return "Unknown"
  }

  // One line for the panel hero: name the thing that is actually wrong, since
  // "which side is off?" is the whole question this widget exists to answer.
  // The session is reported FIRST when it's the blocker, because a locked box
  // shows two healthy daemons and is otherwise indistinguishable from a working
  // link — that ambiguity is exactly what used to cost a debugging session.
  function summary() {
    if (!known) return "Checking…"
    if (windowsSession === "SIGNEDOUT") return peerName + " is signed out since its last reboot"
    if (windowsSession === "LOCKED") return peerName + " is at the lock screen"
    if (linkUp) return "Link up — both daemons running"
    if (archState !== "ACTIVE" && windowsState !== "ACTIVE") return "Link down on both machines"
    if (archState !== "ACTIVE") return "This machine: " + stateLabel(archState).toLowerCase()
    return peerName + ": " + stateLabel(windowsState).toLowerCase()
  }

  function healthy(state) { return state === "ACTIVE" }

  function refresh() {
    if (probeProcess.running) return
    refreshing = true
    probeProcess.command = [ctlPath, "probe"]
    probeProcess.running = true
  }

  function applyProbe(raw) {
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].replace(/^\s+|\s+$/g, "")
      if (line.indexOf("arch=") === 0) archState = line.substring(5)
      else if (line.indexOf("windows=") === 0) windowsState = line.substring(8)
      else if (line.indexOf("session=") === 0) windowsSession = line.substring(8)
    }
    lastError = ""
  }

  function elide(text) {
    var value = String(text || "").replace(/\s+/g, " ").replace(/^\s+|\s+$/g, "")
    return value.length > 120 ? value.substring(0, 117) + "…" : value
  }

  function restart(which) {
    if (actionProcess.running) return
    pendingAction = which
    actionStatus = which === "both" ? "Restarting both daemons…"
                 : which === "arch" ? "Restarting this machine…"
                 : "Restarting " + peerName + "…"
    // Show the affected side as in-flight straight away rather than leaving a
    // stale ACTIVE/DOWN on screen for the several seconds a restart takes.
    if (which === "arch" || which === "both") archState = "CHECKING"
    if (which === "windows" || which === "both") windowsState = "CHECKING"
    actionProcess.command = [ctlPath, "restart-" + which]
    actionProcess.running = true
  }

  // Unlocking reattaches the session to the console and takes ~16s end to end;
  // signing in from cold adds an RDP authentication on top. Either way the same
  // subcommand does whatever that box currently needs.
  function signIn() {
    if (actionProcess.running) return
    pendingAction = "signin"
    actionStatus = windowsSession === "SIGNEDOUT"
                 ? "Signing in to " + peerName + "…"
                 : "Unlocking " + peerName + "…"
    windowsSession = "CHECKING"
    actionProcess.command = [ctlPath, "signin-windows"]
    actionProcess.running = true
  }

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: actionStatusTimer
    interval: 3200
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  Process {
    id: probeProcess
    running: false
    command: []
    stdout: StdioCollector { id: probeOut; waitForEnd: true }
    stderr: StdioCollector { id: probeErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.refreshing = false
      if (exitCode === 0) root.applyProbe(probeOut.text)
      else root.lastError = root.elide(probeErr.text || probeOut.text || "Could not read lan-mouse status")
    }
  }

  Process {
    id: actionProcess
    running: false
    command: []
    stdout: StdioCollector { id: actionOut; waitForEnd: true }
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.lastError = root.elide(actionErr.text || actionOut.text || "Restart failed")
        root.actionStatus = root.lastError
      } else {
        root.lastError = ""
        root.actionStatus = root.pendingAction === "signin" ? "Desktop unlocked" : "Restarted"
      }
      root.pendingAction = ""
      actionStatusTimer.restart()
      root.refresh()
    }
  }
}

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// lan-mouse link status in the bar, with a restart for either machine.
//
// The bar icon answers the question at a glance — normal when the pointer can
// actually cross, urgent when it can't — and the panel says WHICH side is off,
// which is the part that used to require ssh'ing into the other box to find out.
Panel {
  id: root
  moduleName: "pablo.lanmouse"
  ipcTarget: "pablo.lanmouse"
  manageIpc: false

  // Cursor rows: 0 = this machine, 1 = the peer, 2 = the peer's session,
  // 3 = restart both.
  readonly property int rowCount: 4
  property int rowIndex: 0
  property bool cursorActive: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Nerd Font glyphs addressed by codepoint rather than pasted as literals —
  // the private-use points above U+FFFF do not survive every editor/shell
  // round-trip, and a silently truncated glyph renders as a stray letter.
  readonly property string glyphMouse: String.fromCodePoint(0xF037D)    // md-mouse
  readonly property string glyphArch: String.fromCodePoint(0xF303)      // linux-archlinux
  readonly property string glyphWindows: String.fromCodePoint(0xF17A)   // fa-windows
  readonly property string glyphRestart: String.fromCodePoint(0xF0709)  // md-restart
  // Deliberately the BMP Font Awesome set rather than the 5-hex-digit Material
  // ones above: these survive any round-trip, and a lock is worth being certain
  // about since it's the glyph shown when the link is unusable.
  readonly property string glyphLock: String.fromCodePoint(0xF023)      // fa-lock
  readonly property string glyphUnlock: String.fromCodePoint(0xF09C)    // fa-unlock
  readonly property string glyphSignIn: String.fromCodePoint(0xF090)    // fa-sign-in

  // Dim while the first probe is still in flight, urgent the moment we know the
  // link can't carry the pointer.
  readonly property color barIconColor: !link.known ? Qt.darker(barForeground, 1.55)
                                      : link.linkUp ? barForeground
                                      : root.urgent

  function moveCursor(dx, dy) {
    cursorActive = true
    if (dy === 0) return
    rowIndex = Math.max(0, Math.min(rowCount - 1, rowIndex + dy))
  }

  function activateCursor() {
    if (link.busy) return
    if (rowIndex === 0) link.restart("arch")
    else if (rowIndex === 1) link.restart("windows")
    else if (rowIndex === 2) { if (link.needsSignIn) link.signIn() }
    else link.restart("both")
  }

  function setCursor(index) {
    cursorActive = true
    rowIndex = index
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    rowIndex = 0
    link.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Service {
    id: link
    settings: root.settings
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { link.refresh(); return "ok" }
    function status(): string { return "arch=" + link.archState + " windows=" + link.windowsState + " session=" + link.windowsSession }
    function signIn(): string { link.signIn(); return "ok" }
    function restartArch(): string { link.restart("arch"); return "ok" }
    function restartWindows(): string { link.restart("windows"); return "ok" }
    function restartBoth(): string { link.restart("both"); return "ok" }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Item {
        Text {
          anchors.centerIn: parent
          text: root.glyphMouse
          color: root.barIconColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.icon
          opacity: link.busy ? 0.6 : 1.0
          Behavior on opacity { NumberAnimation { duration: 160 } }
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) link.refresh()
      else if (buttonCode === Qt.MiddleButton) link.restart("both")
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(520))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") link.refresh()
        else if (t === "a" || t === "A") link.restart("arch")
        else if (t === "w" || t === "W") link.restart("windows")
        else if (t === "b" || t === "B") link.restart("both")
        else if (t === "s" || t === "S") link.signIn()
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(12)

        PanelHero {
          id: hero
          width: parent.width
          title: "lan-mouse"
          meta: link.summary()
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconOpacity: link.linkUp ? 1.0 : 0.5
          iconComponent: Component {
            Text {
              text: root.glyphMouse
              color: link.linkUp ? root.foreground : root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
        }

        Text {
          visible: link.actionStatus !== "" || link.lastError !== ""
          width: parent.width
          text: link.actionStatus !== "" ? link.actionStatus : link.lastError
          color: link.lastError !== "" && link.actionStatus === "" ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        PanelSeparator { foreground: root.foreground }

        Column {
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "MACHINES"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Column {
            width: parent.width
            spacing: Style.space(6)

            MachineRow {
              width: parent.width
              glyph: root.glyphArch
              title: "This machine"
              state: link.archState
              target: "arch"
              rowId: 0
            }

            MachineRow {
              width: parent.width
              glyph: root.glyphWindows
              title: link.peerName
              state: link.windowsState
              target: "windows"
              rowId: 1
            }

            SessionRow { width: parent.width }
          }
        }

        PanelSeparator { foreground: root.foreground }

        RestartBothRow { width: parent.width }
      }
    }
  }

  // One machine: status dot, name, what its daemon is doing, and a restart.
  component MachineRow: CursorSurface {
    id: machineRow
    property string glyph: ""
    property string title: ""
    property string state: "CHECKING"
    property string target: ""
    property int rowId: 0

    readonly property bool ok: link.healthy(state)
    readonly property bool pending: state === "CHECKING"
    readonly property color statusColor: pending ? root.dim : (ok ? root.foreground : root.urgent)

    hasCursor: root.cursorActive && root.rowIndex === rowId
    foreground: root.foreground
    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: link.busy ? Qt.ArrowCursor : Qt.PointingHandCursor
      onEntered: root.setCursor(machineRow.rowId)
      onClicked: if (!link.busy) link.restart(machineRow.target)
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        text: machineRow.glyph
        color: machineRow.statusColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        id: rowContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: machineRow.title
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          text: link.stateLabel(machineRow.state)
          color: machineRow.pending ? root.dim : (machineRow.ok ? root.dim : root.urgent)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        iconText: root.glyphRestart
        tooltipText: "Restart " + machineRow.title
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: !link.busy
        hasCursor: machineRow.hasCursor
        Layout.alignment: Qt.AlignVCenter
        onClicked: link.restart(machineRow.target)
      }
    }
  }

  // The Windows sign-in state, which fails independently of either daemon: a
  // rebooted box shows a perfectly healthy daemon and still swallows the pointer
  // because it never got past the sign-in screen. Without this row the panel
  // would confidently report "link up" while nothing crossed.
  component SessionRow: CursorSurface {
    id: sessionRow

    readonly property bool ok: link.sessionReady
    readonly property bool pending: link.windowsSession === "CHECKING"
    readonly property bool actionable: link.needsSignIn
    readonly property color statusColor: pending ? root.dim : (ok ? root.foreground : root.urgent)

    hasCursor: root.cursorActive && root.rowIndex === 2
    foreground: root.foreground
    implicitHeight: sessionContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: (link.busy || !sessionRow.actionable) ? Qt.ArrowCursor : Qt.PointingHandCursor
      onEntered: root.setCursor(2)
      onClicked: if (!link.busy && sessionRow.actionable) link.signIn()
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        text: sessionRow.ok ? root.glyphUnlock : root.glyphLock
        color: sessionRow.statusColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        id: sessionContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: link.peerName + " session"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          // Name the consequence, not just the state — "Locked" alone doesn't
          // explain why a healthy-looking link isn't moving the pointer.
          text: sessionRow.actionable
              ? link.sessionLabel(link.windowsSession) + " — pointer can't cross"
              : link.sessionLabel(link.windowsSession)
          color: sessionRow.pending ? root.dim : (sessionRow.ok ? root.dim : root.urgent)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        iconText: root.glyphSignIn
        tooltipText: link.windowsSession === "SIGNEDOUT"
                   ? "Sign in to " + link.peerName
                   : "Unlock " + link.peerName
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: !link.busy && sessionRow.actionable
        hasCursor: sessionRow.hasCursor
        Layout.alignment: Qt.AlignVCenter
        onClicked: link.signIn()
      }
    }
  }

  component RestartBothRow: CursorSurface {
    id: bothRow

    hasCursor: root.cursorActive && root.rowIndex === 3
    foreground: root.foreground
    implicitHeight: bothContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: link.busy ? Qt.ArrowCursor : Qt.PointingHandCursor
      onEntered: root.setCursor(3)
      onClicked: if (!link.busy) link.restart("both")
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        text: root.glyphRestart
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        id: bothContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: "Restart both"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          text: "Re-arm the whole link"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }
}

import QtQuick
import Quickshell
import Quickshell.Hyprland
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Controls popup. It owns no Processes: the widget passes state in and runs
// the commands behind the *Requested signals.
PopupWindow {
  id: root

  required property Item anchorItem
  required property var bar
  property var owner: null
  property bool open: false

  property var status: Model.parseStatus("")
  // Bumped by the widget on every status read, changed or not.
  property int statusSerial: 0
  property real level: 0
  property real holdLevel: 0
  property string levelText: "-∞ dBFS"
  property bool meterAvailable: true
  property bool busy: false
  property string errorText: ""
  property bool resetting: false
  property bool isDragging: false
  // Set when the window was hidden under us, so the fade-out does not re-map it.
  property bool dismissed: false

  signal sourceVolumeRequested(int percent)
  signal sourceMuteRequested(bool muted)
  signal sinkVolumeRequested(int percent)
  signal sinkMuteRequested(bool muted)
  signal setDefaultRequested()
  signal resetRequested()

  readonly property var coordinatorKey: owner || root
  readonly property var anchorWindow: anchorItem ? anchorItem.QsWindow.window : null

  readonly property color bg: Color.popups.background
  property color borderColor: Color.popups.border
  property var borderSpec: Border.localOrSurfaceSpec("popups", "border", borderColor, Color.popups.border, Math.max(1, Style.space(2)))
  readonly property color accent: Color.accent
  readonly property color muted: Color.muted
  readonly property color urgent: Color.urgent

  function luminance(c) { return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b }
  readonly property color fg: luminance(bg) > 0.6 ? "#1a1a1a" : Color.popups.text
  readonly property color safeMuted: luminance(bg) > 0.6 ? "#5a5a5a" : Qt.rgba(fg.r, fg.g, fg.b, 0.72)
  readonly property string fontFamily: bar ? bar.fontFamily : "monospace"

  property int margin: Style.gapsOut
  property int cardPadding: Style.spacing.popupPadding

  implicitWidth: 380
  implicitHeight: mainCol.implicitHeight + card.contentTopInset + card.contentBottomInset

  visible: open || (card.opacity > 0 && !dismissed)
  color: "transparent"

  function close() { root.open = false }

  onOpenChanged: {
    if (open) dismissed = false
    if (!bar) return
    if (open) bar.requestPopout(coordinatorKey)
    else if (bar.activePopout === coordinatorKey) bar.releasePopout(coordinatorKey)
  }

  // The compositor can dismiss the popup, or unmap the bar under it, without
  // touching open. Close for real so the widget stops the meter.
  onVisibleChanged: if (!visible && open) { dismissed = true; close() }

  HyprlandFocusGrab {
    active: root.open
    windows: root.anchorWindow ? [root, root.anchorWindow] : [root]
    onCleared: root.close()
  }

  anchor {
    window: root.anchorWindow
    adjustment: PopupAdjustment.Slide
    edges: Edges.Top | Edges.Left
    gravity: Edges.Bottom | Edges.Right
    rect.width: 1
    rect.height: 1

    onAnchoring: {
      if (!root.anchorItem || !root.bar || !root.anchorWindow) return

      var target = root.anchorItem
      var win = root.anchorWindow
      var w = root.implicitWidth
      var h = root.implicitHeight
      var posX = 0
      var posY = 0

      if (root.bar.position === "bottom") {
        var localX = target.width / 2 - w / 2
        var point = win.contentItem.mapFromItem(target, localX, 0)
        posX = Math.max(root.margin, Math.min(point.x, win.width - w - root.margin))
        posY = -(h + root.margin)
      } else if (root.bar.position === "left") {
        var localY = target.height / 2 - h / 2
        var point = win.contentItem.mapFromItem(target, 0, localY)
        posX = win.width + root.margin
        posY = Math.max(root.margin, Math.min(point.y, win.height - h - root.margin))
      } else if (root.bar.position === "right") {
        var localY = target.height / 2 - h / 2
        var point = win.contentItem.mapFromItem(target, 0, localY)
        posX = -(w + root.margin)
        posY = Math.max(root.margin, Math.min(point.y, win.height - h - root.margin))
      } else {
        var localX = target.width / 2 - w / 2
        var point = win.contentItem.mapFromItem(target, localX, 0)
        posX = Math.max(root.margin, Math.min(point.x, win.width - w - root.margin))
        posY = win.height + root.margin
      }

      root.anchor.rect.x = Math.round(posX)
      root.anchor.rect.y = Math.round(posY)
    }
  }

  component WaveSlider: Column {
    id: ws
    property string label: ""
    // Raw status percent: -1 is unknown, above 100 is shown but not selectable.
    property int percent: -1
    property bool controlEnabled: true
    signal committed(int val)

    // Last committed value, shown until the next status read, so the thumb
    // does not jump back to the old percent on release. Any read clears it,
    // so a set that failed shows the real value again.
    property int pendingVal: -1
    property int liveVal: Model.sliderValue(percent)
    onPercentChanged: if (!slider.dragging) liveVal = Model.sliderValue(percent)

    Connections {
      target: root
      function onStatusSerialChanged() {
        ws.pendingVal = -1
        if (!slider.dragging) ws.liveVal = Model.sliderValue(ws.percent)
      }
    }

    width: parent.width
    spacing: 3

    Timer {
      id: debounceTimer
      interval: 150
      repeat: false
      onTriggered: {
        root.isDragging = false
        ws.pendingVal = ws.liveVal
        ws.committed(ws.liveVal)
      }
    }

    Row {
      width: parent.width

      Text {
        text: ws.label
        color: ws.controlEnabled ? root.fg : root.safeMuted
        font.family: root.fontFamily
        font.pixelSize: 12
        font.bold: true
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - valText.implicitWidth
      }

      Text {
        id: valText
        text: slider.dragging ? ws.liveVal + " %"
          : (ws.pendingVal >= 0 ? ws.pendingVal + " %" : Model.volumeLabel(ws.percent))
        color: root.safeMuted
        font.family: root.fontFamily
        font.pixelSize: 11
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Item {
      width: parent.width
      height: slider.implicitHeight

      PanelSlider {
        id: slider
        anchors.fill: parent
        bar: root.bar
        enabled: ws.controlEnabled
        opacity: ws.controlEnabled ? 1.0 : 0.4
        minimum: 0
        maximum: 100
        step: 1
        integer: true
        value: ws.pendingVal >= 0 ? ws.pendingVal : Model.sliderValue(ws.percent)

        onMoved: function(v) {
          ws.liveVal = Math.round(v)
          root.isDragging = true
          debounceTimer.restart()
        }
        onReleased: function(v) {
          debounceTimer.stop()
          root.isDragging = false
          ws.liveVal = Math.round(v)
          ws.pendingVal = ws.liveVal
          ws.committed(ws.liveVal)
        }
      }
    }
  }

  component WaveToggle: Row {
    id: wt
    property string label: ""
    property bool checked: false
    property bool controlEnabled: true
    signal toggled()

    width: parent.width
    height: Math.max(toggleText.implicitHeight, toggleSwitch.implicitHeight)

    Text {
      id: toggleText
      text: wt.label
      color: wt.controlEnabled ? root.fg : root.safeMuted
      font.family: root.fontFamily
      font.pixelSize: 12
      font.bold: true
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width - toggleSwitch.width
    }

    ToggleSwitch {
      id: toggleSwitch
      checked: wt.checked
      busy: root.busy
      enabled: wt.controlEnabled
      opacity: wt.controlEnabled ? 1.0 : 0.4
      foreground: root.fg
      accent: root.accent
      anchors.verticalCenter: parent.verticalCenter
      onToggled: wt.toggled()
    }
  }

  BorderSurface {
    id: card
    anchors.fill: parent
    radius: Style.cornerRadius
    color: root.bg
    borderSpec: root.borderSpec
    padding: root.cardPadding
    opacity: root.open ? 1 : 0

    Behavior on opacity {
      NumberAnimation { duration: 130; easing.type: Easing.OutCubic }
    }

    Column {
      id: mainCol
      anchors.fill: parent
      anchors.topMargin: card.contentTopInset
      anchors.rightMargin: card.contentRightInset
      anchors.bottomMargin: card.contentBottomInset
      anchors.leftMargin: card.contentLeftInset
      spacing: 8

      // Header
      Row {
        spacing: 8

        Text {
          text: root.status.muted ? "󰍭" : "󰍬"
          color: root.status.present ? root.accent : root.safeMuted
          font.family: root.fontFamily
          font.pixelSize: 18
          anchors.verticalCenter: parent.verticalCenter
        }

        Column {
          spacing: 1
          anchors.verticalCenter: parent.verticalCenter

          Text {
            text: "Elgato Wave:3"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: 14
            font.bold: true
          }

          Text {
            text: Model.headerLine(root.status)
            color: root.status.present ? root.safeMuted : root.urgent
            font.family: root.fontFamily
            font.pixelSize: 10
          }
        }
      }

      PanelSeparator {
        foreground: root.fg
      }

      // Microphone
      Column {
        width: parent.width
        spacing: 10
        visible: root.status.present

        PanelSectionHeader {
          text: "MICROPHONE"
          foreground: root.fg
          fontFamily: root.fontFamily
        }

        WaveSlider {
          label: "Gain"
          percent: root.status.volume
          controlEnabled: root.status.volume >= 0
          onCommitted: function(v) { root.sourceVolumeRequested(v) }
        }

        WaveToggle {
          label: "Mute"
          checked: root.status.muted
          onToggled: root.sourceMuteRequested(!root.status.muted)
        }

        // Level meter: peak bar, peak-hold marker and dBFS readout.
        Column {
          width: parent.width
          spacing: 3

          Row {
            width: parent.width

            Text {
              text: "Level"
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: 12
              font.bold: true
              width: parent.width - levelLabel.implicitWidth
            }

            Text {
              id: levelLabel
              text: !root.meterAvailable ? "Level unavailable"
                : (root.status.muted ? "Muted" : root.levelText)
              color: root.safeMuted
              font.family: root.fontFamily
              font.pixelSize: 11
            }
          }

          Rectangle {
            id: meterTrack
            width: parent.width
            height: 6
            radius: height / 2
            color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12)
            opacity: root.meterAvailable ? 1.0 : 0.4

            Rectangle {
              height: parent.height
              radius: parent.radius
              width: parent.width * Model.meterPosition(root.status.muted ? 0 : root.level)
              color: root.level >= 0.99 ? root.urgent : root.accent
            }

            Rectangle {
              visible: !root.status.muted && root.holdLevel > 0
              width: 2
              height: parent.height
              x: Math.max(0, parent.width * Model.meterPosition(root.holdLevel) - width)
              color: root.holdLevel >= 0.99 ? root.urgent : root.fg
            }
          }
        }

        Button {
          text: "Set as default"
          bordered: true
          visible: Model.canSetDefault(root.status)
          enabled: !root.resetting
          foreground: root.fg
          background: root.bg
          accent: root.accent
          fontFamily: root.fontFamily
          fontSize: 11
          onClicked: root.setDefaultRequested()
        }

        PanelSeparator {
          foreground: root.fg
        }
      }

      // Headphones
      Column {
        width: parent.width
        spacing: 10
        visible: Model.headphonesAvailable(root.status)

        PanelSectionHeader {
          text: "HEADPHONES"
          foreground: root.fg
          fontFamily: root.fontFamily
        }

        WaveSlider {
          label: "Volume"
          percent: root.status.sinkVolume
          controlEnabled: root.status.sinkVolume >= 0
          onCommitted: function(v) { root.sinkVolumeRequested(v) }
        }

        WaveToggle {
          label: "Mute"
          checked: root.status.sinkMuted
          onToggled: root.sinkMuteRequested(!root.status.sinkMuted)
        }

        PanelSeparator {
          foreground: root.fg
        }
      }

      Text {
        visible: !root.status.present
        text: "Not connected. Plug in the Wave:3 or run Reset."
        color: root.safeMuted
        font.family: root.fontFamily
        font.pixelSize: 11
        wrapMode: Text.Wrap
        width: parent.width
      }

      // Actions
      Button {
        text: root.resetting ? "Resetting…" : "Reset"
        bordered: true
        enabled: !root.resetting
        foreground: root.fg
        background: root.bg
        accent: root.accent
        fontFamily: root.fontFamily
        fontSize: 11
        onClicked: root.resetRequested()
      }

      Text {
        visible: root.errorText !== ""
        text: root.errorText
        color: root.urgent
        font.family: root.fontFamily
        font.pixelSize: 11
        wrapMode: Text.Wrap
        width: parent.width
      }

      Text {
        text: "Clipguard, low-cut, mic/PC mix and LED need Elgato Wave Link — not available on Linux."
        color: root.safeMuted
        font.family: root.fontFamily
        font.pixelSize: 10
        wrapMode: Text.Wrap
        width: parent.width
      }
    }
  }
}

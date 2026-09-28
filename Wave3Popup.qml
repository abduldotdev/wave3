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
  property var hwStatus: Model.parseHwStatus("")
  readonly property bool hwReady: Boolean(root.hwStatus && root.hwStatus.hwReady)
  readonly property string udevRulePath: Qt.resolvedUrl("udev/70-elgato-wave3.rules").toString().replace(/^file:\/\//, "")
  readonly property string udevInstallCommand: "sudo install -m644 " + root.udevRulePath + " /etc/udev/rules.d/ && sudo udevadm control --reload && sudo udevadm trigger"

  // Bumped by the widget on every status read, changed or not.
  property int statusSerial: 0
  property real level: 0
  property real holdLevel: 0
  property string levelText: "-∞ dBFS"
  property bool meterAvailable: true
  property bool busy: false
  property string errorText: ""
  property string savedHint: ""
  property bool resetting: false
  property bool isDragging: false
  // Set when the window was hidden under us, so the fade-out does not re-map it.
  property bool dismissed: false

  signal sourceVolumeRequested(int percent)
  signal sourceMuteRequested(bool muted)
  signal sinkVolumeRequested(int percent)
  signal sinkMuteRequested(bool muted)
  signal hwSetRequested(string field, var value)
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
    id: waveSliderCtrl
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
        waveSliderCtrl.pendingVal = -1
        if (!slider.dragging) waveSliderCtrl.liveVal = Model.sliderValue(waveSliderCtrl.percent)
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
        waveSliderCtrl.pendingVal = waveSliderCtrl.liveVal
        waveSliderCtrl.committed(waveSliderCtrl.liveVal)
      }
    }

    Row {
      width: parent.width

      Text {
        text: waveSliderCtrl.label
        color: waveSliderCtrl.controlEnabled ? root.fg : root.safeMuted
        font.family: root.fontFamily
        font.pixelSize: 12
        font.bold: true
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - valText.implicitWidth
      }

      Text {
        id: valText
        text: slider.dragging ? waveSliderCtrl.liveVal + " %"
          : (waveSliderCtrl.pendingVal >= 0 ? waveSliderCtrl.pendingVal + " %" : Model.volumeLabel(waveSliderCtrl.percent))
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
        enabled: waveSliderCtrl.controlEnabled
        opacity: waveSliderCtrl.controlEnabled ? 1.0 : 0.4
        minimum: 0
        maximum: 100
        step: 1
        integer: true
        value: waveSliderCtrl.pendingVal >= 0 ? waveSliderCtrl.pendingVal : Model.sliderValue(waveSliderCtrl.percent)

        onMoved: function(v) {
          waveSliderCtrl.liveVal = Math.round(v)
          root.isDragging = true
          debounceTimer.restart()
        }
        onReleased: function(v) {
          debounceTimer.stop()
          root.isDragging = false
          waveSliderCtrl.liveVal = Math.round(v)
          waveSliderCtrl.pendingVal = waveSliderCtrl.liveVal
          waveSliderCtrl.committed(waveSliderCtrl.liveVal)
        }
      }
    }
  }

  component WaveToggle: Row {
    id: waveToggleCtrl
    property string label: ""
    property bool checked: false
    property bool controlEnabled: true
    signal toggled()

    width: parent.width
    height: Math.max(toggleText.implicitHeight, toggleSwitch.implicitHeight)

    Text {
      id: toggleText
      text: waveToggleCtrl.label
      color: waveToggleCtrl.controlEnabled ? root.fg : root.safeMuted
      font.family: root.fontFamily
      font.pixelSize: 12
      font.bold: true
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width - toggleSwitch.width
    }

    ToggleSwitch {
      id: toggleSwitch
      checked: waveToggleCtrl.checked
      busy: root.busy
      enabled: waveToggleCtrl.controlEnabled
      opacity: waveToggleCtrl.controlEnabled ? 1.0 : 0.4
      foreground: root.fg
      accent: root.accent
      anchors.verticalCenter: parent.verticalCenter
      onToggled: waveToggleCtrl.toggled()
    }
  }

  component GainControl: Column {
    id: gainCtrl
    property real gainDb: 0
    property bool controlEnabled: true
    signal committed(real val)

    property real pendingVal: -999
    property real liveVal: gainDb
    onGainDbChanged: if (!slider.dragging) liveVal = gainDb

    Connections {
      target: root
      function onStatusSerialChanged() {
        gainCtrl.pendingVal = -999
        if (!slider.dragging) gainCtrl.liveVal = gainCtrl.gainDb
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
        gainCtrl.pendingVal = gainCtrl.liveVal
        gainCtrl.committed(gainCtrl.liveVal)
      }
    }

    Row {
      width: parent.width

      Text {
        text: "Gain"
        color: gainCtrl.controlEnabled ? root.fg : root.safeMuted
        font.family: root.fontFamily
        font.pixelSize: 12
        font.bold: true
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - gainControlsRow.implicitWidth
      }

      Row {
        id: gainControlsRow
        spacing: 6
        anchors.verticalCenter: parent.verticalCenter

        Text {
          id: gainValText
          text: (slider.dragging ? gainCtrl.liveVal : (gainCtrl.pendingVal >= 0 ? gainCtrl.pendingVal : gainCtrl.gainDb)).toFixed(1) + " dB"
          color: gainCtrl.controlEnabled ? root.fg : root.safeMuted
          font.family: root.fontFamily
          font.pixelSize: 15
          font.bold: true
          anchors.verticalCenter: parent.verticalCenter
        }

        Button {
          text: "−"
          bordered: true
          enabled: gainCtrl.controlEnabled && ((gainCtrl.pendingVal >= 0 ? gainCtrl.pendingVal : gainCtrl.gainDb) > 0)
          foreground: root.fg
          background: root.bg
          accent: root.accent
          fontFamily: root.fontFamily
          fontSize: 11
          horizontalPadding: 6
          verticalPadding: 2
          anchors.verticalCenter: parent.verticalCenter
          onClicked: {
            var cur = gainCtrl.pendingVal >= 0 ? gainCtrl.pendingVal : gainCtrl.gainDb
            var next = Model.quantizeGain(cur - 0.5)
            gainCtrl.liveVal = next
            gainCtrl.pendingVal = next
            gainCtrl.committed(next)
          }
        }

        Button {
          text: "+"
          bordered: true
          enabled: gainCtrl.controlEnabled && ((gainCtrl.pendingVal >= 0 ? gainCtrl.pendingVal : gainCtrl.gainDb) < 40)
          foreground: root.fg
          background: root.bg
          accent: root.accent
          fontFamily: root.fontFamily
          fontSize: 11
          horizontalPadding: 6
          verticalPadding: 2
          anchors.verticalCenter: parent.verticalCenter
          onClicked: {
            var cur = gainCtrl.pendingVal >= 0 ? gainCtrl.pendingVal : gainCtrl.gainDb
            var next = Model.quantizeGain(cur + 0.5)
            gainCtrl.liveVal = next
            gainCtrl.pendingVal = next
            gainCtrl.committed(next)
          }
        }
      }
    }

    Item {
      width: parent.width
      height: slider.implicitHeight

      PanelSlider {
        id: slider
        anchors.fill: parent
        bar: root.bar
        enabled: gainCtrl.controlEnabled
        opacity: gainCtrl.controlEnabled ? 1.0 : 0.4
        minimum: 0
        maximum: 40
        step: 0.5
        integer: false
        value: gainCtrl.pendingVal >= 0 ? gainCtrl.pendingVal : gainCtrl.gainDb

        onMoved: function(v) {
          gainCtrl.liveVal = Model.quantizeGain(v)
          root.isDragging = true
          debounceTimer.restart()
        }
        onReleased: function(v) {
          debounceTimer.stop()
          root.isDragging = false
          gainCtrl.liveVal = Model.quantizeGain(v)
          gainCtrl.pendingVal = gainCtrl.liveVal
          gainCtrl.committed(gainCtrl.liveVal)
        }
      }
    }
  }

  component HwSlider: Column {
    id: hwSliderCtrl
    property string label: ""
    property string sublabel: ""
    property real value: 0
    property real minimum: 0
    property real maximum: 100
    property real step: 1
    property bool integer: false
    property string unit: ""
    property bool controlEnabled: true
    signal committed(real val)

    property real pendingVal: -9999
    property real liveVal: value
    onValueChanged: if (!slider.dragging) liveVal = value

    Connections {
      target: root
      function onStatusSerialChanged() {
        hwSliderCtrl.pendingVal = -9999
        if (!slider.dragging) hwSliderCtrl.liveVal = hwSliderCtrl.value
      }
    }

    function formatVal(v) {
      if (hwSliderCtrl.integer) return Math.round(v) + (hwSliderCtrl.unit ? " " + hwSliderCtrl.unit : "")
      return v.toFixed(1) + (hwSliderCtrl.unit ? " " + hwSliderCtrl.unit : "")
    }

    width: parent.width
    spacing: 3

    Timer {
      id: debounceTimer
      interval: 150
      repeat: false
      onTriggered: {
        root.isDragging = false
        hwSliderCtrl.pendingVal = hwSliderCtrl.liveVal
        hwSliderCtrl.committed(hwSliderCtrl.liveVal)
      }
    }

    Row {
      width: parent.width

      Column {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - valText.implicitWidth

        Text {
          text: hwSliderCtrl.label
          color: hwSliderCtrl.controlEnabled ? root.fg : root.safeMuted
          font.family: root.fontFamily
          font.pixelSize: 12
          font.bold: true
        }

        Text {
          visible: hwSliderCtrl.sublabel !== ""
          text: hwSliderCtrl.sublabel
          color: root.safeMuted
          font.family: root.fontFamily
          font.pixelSize: 10
        }
      }

      Text {
        id: valText
        text: slider.dragging ? hwSliderCtrl.formatVal(hwSliderCtrl.liveVal)
          : (hwSliderCtrl.pendingVal !== -9999 ? hwSliderCtrl.formatVal(hwSliderCtrl.pendingVal) : hwSliderCtrl.formatVal(hwSliderCtrl.value))
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
        enabled: hwSliderCtrl.controlEnabled
        opacity: hwSliderCtrl.controlEnabled ? 1.0 : 0.4
        minimum: hwSliderCtrl.minimum
        maximum: hwSliderCtrl.maximum
        step: hwSliderCtrl.step
        integer: hwSliderCtrl.integer
        value: hwSliderCtrl.pendingVal !== -9999 ? hwSliderCtrl.pendingVal : hwSliderCtrl.value

        onMoved: function(v) {
          if (hwSliderCtrl.integer) hwSliderCtrl.liveVal = Math.round(v)
          else hwSliderCtrl.liveVal = Math.round(v * 2) / 2
          root.isDragging = true
          debounceTimer.restart()
        }
        onReleased: function(v) {
          debounceTimer.stop()
          root.isDragging = false
          if (hwSliderCtrl.integer) hwSliderCtrl.liveVal = Math.round(v)
          else hwSliderCtrl.liveVal = Math.round(v * 2) / 2
          hwSliderCtrl.pendingVal = hwSliderCtrl.liveVal
          hwSliderCtrl.committed(hwSliderCtrl.liveVal)
        }
      }
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
          text: (root.status.muted || (root.hwReady && root.hwStatus.mute)) ? "󰍭" : "󰍬"
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

      // Hardware setup notice (shown when mic is connected but hardware controls need udev rules)
      Column {
        width: parent.width
        spacing: 4
        visible: root.status.present && !root.hwReady

        Text {
          text: "Hardware controls need setup:"
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: 11
          font.bold: true
        }

        Rectangle {
          width: parent.width
          implicitHeight: setupCmdText.implicitHeight + 8
          color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)
          radius: Style.cornerRadius
          border.width: 1
          border.color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.3)

          TextEdit {
            id: setupCmdText
            anchors.fill: parent
            anchors.margins: 4
            text: root.udevInstallCommand
            readOnly: true
            selectByMouse: true
            wrapMode: TextEdit.Wrap
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: 9
          }
        }

        PanelSeparator {
          foreground: root.fg
        }
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

        // Hardware Gain control (0..40 dB) when hwReady; hidden when !hwReady
        GainControl {
          visible: root.hwReady
          gainDb: root.hwStatus.gainDb
          onCommitted: function(v) { root.hwSetRequested("gain_db", v) }
        }

        // Mute mic via hw mute when hwReady, fallback to pactl mute when !hwReady
        WaveToggle {
          label: "Mute"
          checked: root.hwReady ? root.hwStatus.mute : root.status.muted
          onToggled: {
            if (root.hwReady) root.hwSetRequested("mute", !root.hwStatus.mute)
            else root.sourceMuteRequested(!root.status.muted)
          }
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
                : ((root.status.muted || (root.hwReady && root.hwStatus.mute)) ? "Muted" : root.levelText)
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
              width: parent.width * Model.meterPosition((root.status.muted || (root.hwReady && root.hwStatus.mute)) ? 0 : root.level)
              color: root.level >= 0.99 ? root.urgent : root.accent

              Behavior on width { NumberAnimation { duration: 70 } }
            }

            Rectangle {
              visible: !(root.status.muted || (root.hwReady && root.hwStatus.mute)) && root.holdLevel > 0
              width: 2
              height: parent.height
              x: Math.max(0, parent.width * Model.meterPosition(root.holdLevel) - width)
              color: root.holdLevel >= 0.99 ? root.urgent : root.fg

              Behavior on x { NumberAnimation { duration: 70 } }
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

      // Monitoring (Hardware mode)
      Column {
        width: parent.width
        spacing: 10
        visible: root.status.present && root.hwReady

        PanelSectionHeader {
          text: "MONITORING"
          foreground: root.fg
          fontFamily: root.fontFamily
        }

        HwSlider {
          label: "Headphones"
          value: root.hwStatus.hpDb
          minimum: -60
          maximum: 0
          step: 0.5
          integer: false
          unit: "dB"
          onCommitted: function(v) { root.hwSetRequested("hp_db", Model.quantizeHp(v)) }
        }

        WaveToggle {
          label: "Mute headphones"
          checked: root.hwStatus.hpMute
          onToggled: root.hwSetRequested("hp_mute", !root.hwStatus.hpMute)
        }

        HwSlider {
          label: "Monitor blend"
          sublabel: "Mic ↔ Computer"
          value: root.hwStatus.directMonitor
          minimum: 0
          maximum: 100
          step: 5
          integer: true
          unit: "%"
          onCommitted: function(v) { root.hwSetRequested("direct_monitor", Model.quantizeDirectMonitor(v)) }
        }

        PanelSeparator {
          foreground: root.fg
        }
      }

      // Headphones (Fallback mode when not hwReady)
      Column {
        width: parent.width
        spacing: 10
        visible: root.status.present && !root.hwReady && Model.headphonesAvailable(root.status)

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

      // Onboard processing (Hardware mode)
      Column {
        width: parent.width
        spacing: 10
        visible: root.status.present && root.hwReady

        PanelSectionHeader {
          text: "ONBOARD PROCESSING"
          foreground: root.fg
          fontFamily: root.fontFamily
        }

        WaveToggle {
          label: "Clipguard"
          checked: root.hwStatus.clipguard
          onToggled: root.hwSetRequested("clipguard", !root.hwStatus.clipguard)
        }

        WaveToggle {
          label: "Low cut"
          checked: root.hwStatus.lowcut
          onToggled: root.hwSetRequested("lowcut", !root.hwStatus.lowcut)
        }

        PanelSeparator {
          foreground: root.fg
        }
      }

      // Device (Hardware mode)
      Column {
        width: parent.width
        spacing: 10
        visible: root.status.present && root.hwReady

        PanelSectionHeader {
          text: "DEVICE"
          foreground: root.fg
          fontFamily: root.fontFamily
        }

        Column {
          width: parent.width
          spacing: 2

          WaveToggle {
            label: "Gain lock"
            checked: root.hwStatus.gainLock
            onToggled: root.hwSetRequested("gain_lock", !root.hwStatus.gainLock)
          }

          Text {
            text: "Locks gain from OS and apps; dial and this panel still work."
            color: root.safeMuted
            font.family: root.fontFamily
            font.pixelSize: 10
            wrapMode: Text.Wrap
            width: parent.width
          }
        }

        WaveToggle {
          label: "LEDs off"
          checked: root.hwStatus.ledsOff
          onToggled: root.hwSetRequested("leds_off", !root.hwStatus.ledsOff)
        }

        WaveToggle {
          label: "Flip LEDs"
          checked: root.hwStatus.ledsFlip
          onToggled: root.hwSetRequested("leds_flip", !root.hwStatus.ledsFlip)
        }

        Row {
          width: parent.width
          height: Math.max(dialModeText.implicitHeight, dialBtnRow.implicitHeight)

          Text {
            id: dialModeText
            text: "Dial mode"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: 12
            font.bold: true
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - dialBtnRow.implicitWidth
          }

          Row {
            id: dialBtnRow
            spacing: 4
            anchors.verticalCenter: parent.verticalCenter

            Button {
              text: "MIC"
              bordered: true
              selected: root.hwStatus.volumeSelect === 1
              foreground: root.fg
              background: root.bg
              accent: root.accent
              fontFamily: root.fontFamily
              fontSize: 10
              horizontalPadding: 6
              verticalPadding: 2
              onClicked: root.hwSetRequested("volume_select", 1)
            }

            Button {
              text: "HEADPHONE"
              bordered: true
              selected: root.hwStatus.volumeSelect === 2
              foreground: root.fg
              background: root.bg
              accent: root.accent
              fontFamily: root.fontFamily
              fontSize: 10
              horizontalPadding: 6
              verticalPadding: 2
              onClicked: root.hwSetRequested("volume_select", 2)
            }

            Button {
              text: "MIX"
              bordered: true
              selected: root.hwStatus.volumeSelect === 3
              foreground: root.fg
              background: root.bg
              accent: root.accent
              fontFamily: root.fontFamily
              fontSize: 10
              horizontalPadding: 6
              verticalPadding: 2
              onClicked: root.hwSetRequested("volume_select", 3)
            }
          }
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
        visible: root.savedHint !== ""
        text: root.savedHint
        color: root.safeMuted
        font.family: root.fontFamily
        font.pixelSize: 11
        wrapMode: Text.Wrap
        width: parent.width
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
    }
  }
}

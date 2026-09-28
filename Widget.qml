import QtQuick
import Quickshell.Io
import qs.Ui
import "Model.js" as Model

BarWidget {
  id: root

  // Run the plugin's own copy so the widget works without ~/.local/bin links.
  readonly property string resetScript: Qt.resolvedUrl("bin/wave3-reset").toString().replace(/^file:\/\//, "")
  readonly property string meterScript: Qt.resolvedUrl("bin/wave3-meter").toString().replace(/^file:\/\//, "")

  property var status: Model.parseStatus("")
  readonly property string level: Model.statusLevel(root.status)
  property bool resetting: false
  property string errorText: ""
  // A read asked for while one is running; it may predate a set, so run again.
  property bool refreshAgain: false

  // Set commands waiting for setProc, keyed by control; the latest value wins.
  property var pendingSets: ({})

  // Meter state, only meaningful while the popup is open.
  property bool meterAvailable: true
  property real meterLevel: 0
  property var meterHold: null
  property string meterText: Model.formatDb(-Infinity)

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function refresh() {
    if (statusProc.running) root.refreshAgain = true
    else statusProc.running = true
  }

  function runReset(args) {
    if (resetProc.running) return
    root.errorText = ""
    root.resetting = true
    resetProc.command = [root.resetScript].concat(args)
    resetProc.running = true
  }

  function reset() { runReset([]) }
  function setDefault() { runReset(["--default-only"]) }

  function open() {
    root.meterAvailable = true
    popup.open = true
    refresh()
  }

  function close() {
    popup.open = false
    root.meterLevel = 0
    root.meterHold = null
    root.meterText = Model.formatDb(-Infinity)
  }

  function toggle() {
    if (popup.open) close()
    else open()
  }

  // Queues a command built by Model.set*Command; null (no matching name) is dropped.
  function queueSet(key, command) {
    if (!command) return
    var pending = root.pendingSets
    pending[key] = command
    root.pendingSets = pending
    pumpSets()
  }

  function pumpSets() {
    if (setProc.running) return
    for (var key in root.pendingSets) {
      setProc.command = root.pendingSets[key]
      delete root.pendingSets[key]
      setProc.running = true
      return
    }
    refresh()
  }

  IpcHandler {
    target: "abduldotdev.wave3"

    function reset(): void { root.reset() }
    function refresh(): void { root.refresh() }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
  }

  Process {
    id: statusProc
    command: [root.resetScript, "--status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var next = Model.parseStatus(text)
        // A mic that comes back while the popup is open gets a fresh meter try.
        if (next.present && !root.status.present) root.meterAvailable = true
        root.status = next
      }
    }
    onExited: {
      if (!root.refreshAgain) return
      root.refreshAgain = false
      statusProc.running = true
    }
  }

  Process {
    id: resetProc
    command: [root.resetScript]
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim()) root.errorText = text.trim().split("\n").pop()
    }
    onExited: function(exitCode) {
      root.resetting = false
      if (exitCode === 0) root.errorText = ""
      else errorTimer.restart()
      root.refresh()
    }
  }

  Process {
    id: setProc
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.errorText = "Could not apply the change"
        errorTimer.restart()
      }
      root.pumpSets()
    }
  }

  Process {
    id: meterProc
    command: [root.meterScript]
    running: popup.open && root.status.present && root.meterAvailable
    stdout: SplitParser {
      onRead: function(data) {
        var m = Model.parseMeterLine(data)
        if (!m) return
        root.meterLevel = m.peak
        root.meterHold = Model.holdPeak(root.meterHold, m.peak, Date.now(), 1500)
        root.meterText = Model.formatDb(m.db)
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && popup.open) root.meterAvailable = false
      root.meterLevel = 0
    }
  }

  Timer {
    id: errorTimer
    interval: 6000
    onTriggered: root.errorText = ""
  }

  Timer {
    interval: 10000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: 3000
    repeat: true
    running: popup.open && !popup.isDragging
    onTriggered: root.refresh()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.status.muted ? "󰍭" : "󰍬"
    dimmed: root.level === "absent"
    active: root.level === "warn" || root.errorText !== ""
    tooltipText: root.resetting ? "Resetting Wave:3…"
      : (root.errorText !== "" ? root.errorText : Model.statusSummary(root.status))
    onPressed: function(b) {
      if (b === Qt.RightButton) root.reset()
      else root.toggle()
    }
  }

  Wave3Popup {
    id: popup
    // The widget itself, reached as an Item: qmllint cannot resolve BarWidget.
    anchorItem: button.parent
    bar: root.bar
    owner: root
    status: root.status
    level: root.meterLevel
    holdLevel: root.meterHold ? root.meterHold.value : 0
    levelText: root.meterText
    meterAvailable: root.meterAvailable
    busy: setProc.running
    errorText: root.errorText
    resetting: root.resetting
    onSourceVolumeRequested: function(percent) { root.queueSet("srcVol", Model.setSourceVolumeCommand(root.status, percent)) }
    onSourceMuteRequested: function(muted) { root.queueSet("srcMute", Model.setSourceMuteCommand(root.status, muted)) }
    onSinkVolumeRequested: function(percent) { root.queueSet("sinkVol", Model.setSinkVolumeCommand(root.status, percent)) }
    onSinkMuteRequested: function(muted) { root.queueSet("sinkMute", Model.setSinkMuteCommand(root.status, muted)) }
    onSetDefaultRequested: root.setDefault()
    onResetRequested: root.reset()
    // An outside click closes the popup directly; clear the meter state too.
    onOpenChanged: if (!popup.open) root.close()
  }
}

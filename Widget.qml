import QtQuick
import Quickshell.Io
import Quickshell.Services.Pipewire
import qs.Ui
import "Model.js" as Model

BarWidget {
  id: root

  // Run the plugin's own copy so the widget works without ~/.local/bin links.
  readonly property string resetScript: Qt.resolvedUrl("bin/wave3-reset").toString().replace(/^file:\/\//, "")
  readonly property string hwScript: Qt.resolvedUrl("bin/wave3-hw").toString().replace(/^file:\/\//, "")

  readonly property var pwNodes: Pipewire.nodes ? Pipewire.nodes.values : []
  readonly property var wave3SourceNode: Model.findWave3Source(root.pwNodes, Model.sourceName(root.status))

  property var status: Model.parseStatus("")
  property var hwStatus: Model.parseHwStatus("")
  readonly property bool isMuted: Model.isMuted(root.status, root.hwStatus)
  readonly property string level: Model.statusLevel(root.status, root.hwStatus)
  property bool resetting: false
  property string errorText: ""
  property string savedHint: ""
  // A read asked for while one is running; it may predate a set, so run again.
  property bool statusRefreshAgain: false
  property bool hwRefreshAgain: false
  property bool hwRefreshForce: false
  property real lastHwPollTime: 0
  property int statusSerial: 0

  // Set commands waiting for setProc, keyed by control; the latest value wins.
  property var pendingSets: ({})
  property var pendingHwSets: ({})

  // Meter state, only meaningful while the popup is open.
  readonly property bool meterAvailable: !root.status.present || Boolean(root.wave3SourceNode)
  property real meterLevel: 0
  property var meterHold: null
  property string meterText: Model.formatDb(-Infinity)

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function hasPendingHwSets() {
    for (var k in root.pendingHwSets) return true
    return false
  }

  function refreshStatus() {
    if (statusProc.running) root.statusRefreshAgain = true
    else statusProc.running = true
  }

  function refreshHw(force) {
    if (hwSetProc.running || hasPendingHwSets()) return
    if (!Model.hwPollDue(Date.now(), root.lastHwPollTime, force || popup.open)) return
    if (hwStatusProc.running) {
      root.hwRefreshAgain = true
      root.hwRefreshForce = root.hwRefreshForce || Boolean(force)
      return
    }
    root.lastHwPollTime = Date.now()
    hwStatusProc.running = true
  }

  function refresh(force) {
    refreshStatus()
    refreshHw(Boolean(force || popup.open))
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
    popup.open = true
    refresh(true)
  }

  function close() {
    popup.open = false
    root.meterLevel = 0
    root.meterHold = null
    root.meterText = Model.formatDb(-Infinity)
    holdDecayTimer.stop()
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

  // Queues a hardware set command for bin/wave3-hw set <field> <value>.
  function queueHwSet(field, value) {
    var cmd = Model.hwSetCommand(root.hwScript, field, value)
    if (!cmd) return
    var pending = root.pendingHwSets
    pending[field] = cmd
    root.pendingHwSets = pending
    pumpHwSets()
  }

  function pumpHwSets() {
    if (hwSetProc.running) return
    for (var field in root.pendingHwSets) {
      hwSetProc.lastStdout = ""
      hwSetProc.command = root.pendingHwSets[field]
      delete root.pendingHwSets[field]
      hwSetProc.running = true
      return
    }
    refresh(true)
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
        root.status = next
        root.statusSerial++
      }
    }
    onExited: {
      if (root.statusRefreshAgain) {
        root.statusRefreshAgain = false
        statusProc.running = true
      }
    }
  }

  Process {
    id: hwStatusProc
    command: [root.hwScript, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.hwStatus = Model.mergeHwStatus(root.hwStatus, Model.parseHwStatus(text))
        root.statusSerial++
      }
    }
    onExited: {
      if (root.hwRefreshAgain) {
        var forceAgain = root.hwRefreshForce
        root.hwRefreshAgain = false
        root.hwRefreshForce = false
        root.refreshHw(forceAgain || popup.open)
      }
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
    id: hwSetProc
    property string lastStdout: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: hwSetProc.lastStdout = text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim()) {
        root.errorText = text.trim().split("\n").pop()
        errorTimer.restart()
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.savedHint = ""
        if (!root.errorText) root.errorText = "Could not apply hardware setting"
        errorTimer.restart()
      } else {
        var res = Model.parseHwSetOutput(hwSetProc.lastStdout)
        if (res.saved === "yes") {
          root.savedHint = Model.SAVED_HINT
          savedHintTimer.restart()
        } else if (res.saved === "error") {
          root.savedHint = ""
          root.errorText = "Changed, but could not save it for reconnect"
          errorTimer.restart()
        }
      }
      root.pumpHwSets()
    }
  }

  PwObjectTracker {
    objects: root.wave3SourceNode ? [root.wave3SourceNode] : []
  }

  PwNodePeakMonitor {
    id: peakMonitor
    node: root.wave3SourceNode
    enabled: Model.meterRunning(popup.open, popup.visible, root.status.present, root.meterAvailable)
    onPeakChanged: {
      var p = peakMonitor.peak
      root.meterLevel = p
      var prevHold = root.meterHold
      root.meterHold = Model.holdPeak(prevHold, p, Date.now(), 1500)
      if (!prevHold || p >= prevHold.value) {
        holdDecayTimer.restart()
      }
    }
    onEnabledChanged: {
      if (!enabled) {
        root.meterLevel = 0
        root.meterHold = null
        root.meterText = Model.formatDb(-Infinity)
        holdDecayTimer.stop()
      }
    }
  }

  Timer {
    interval: 150
    repeat: true
    running: peakMonitor.enabled
    onTriggered: root.meterText = Model.formatPeakDb(peakMonitor.peak)
  }

  Timer {
    id: holdDecayTimer
    interval: 1500
    repeat: false
    onTriggered: {
      var curPeak = peakMonitor.enabled ? peakMonitor.peak : 0
      root.meterHold = Model.holdPeak(root.meterHold, curPeak, Date.now(), 1500)
      if (root.meterHold && root.meterHold.value > 0) {
        holdDecayTimer.restart()
      }
    }
  }

  Timer {
    id: savedHintTimer
    interval: 4000
    onTriggered: root.savedHint = ""
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
    text: root.isMuted ? "󰍭" : "󰍬"
    dimmed: root.level === "absent"
    active: root.level === "warn" || root.errorText !== ""
    tooltipText: root.resetting ? "Resetting Wave:3…"
      : (root.errorText !== "" ? root.errorText : Model.statusSummary(root.status, root.hwStatus))
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
    hwStatus: root.hwStatus
    statusSerial: root.statusSerial
    level: root.meterLevel
    holdLevel: root.meterHold ? root.meterHold.value : 0
    levelText: root.meterText
    meterAvailable: root.meterAvailable
    busy: setProc.running || hwSetProc.running
    errorText: root.errorText
    savedHint: root.savedHint
    resetting: root.resetting
    onSourceVolumeRequested: function(percent) { root.queueSet("srcVol", Model.setSourceVolumeCommand(root.status, percent)) }
    onSourceMuteRequested: function(muted) { root.queueSet("srcMute", Model.setSourceMuteCommand(root.status, muted)) }
    onSinkVolumeRequested: function(percent) { root.queueSet("sinkVol", Model.setSinkVolumeCommand(root.status, percent)) }
    onSinkMuteRequested: function(muted) { root.queueSet("sinkMute", Model.setSinkMuteCommand(root.status, muted)) }
    onHwSetRequested: function(field, value) { root.queueHwSet(field, value) }
    onSetDefaultRequested: root.setDefault()
    onResetRequested: root.reset()
    // An outside click closes the popup directly; clear the meter state too.
    onOpenChanged: if (!popup.open) root.close()
  }
}

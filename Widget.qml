import QtQuick
import Quickshell.Io
import qs.Ui
import "Model.js" as Model

BarWidget {
  id: root

  // Run the plugin's own copy so the widget works without ~/.local/bin links.
  readonly property string resetScript: Qt.resolvedUrl("bin/wave3-reset").toString().replace(/^file:\/\//, "")

  property var status: Model.parseStatus("")
  readonly property string level: Model.statusLevel(root.status)
  property bool resetting: false
  property string errorText: ""

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  function reset() {
    if (resetProc.running) return
    root.errorText = ""
    root.resetting = true
    resetProc.running = true
  }

  IpcHandler {
    target: "abduldotdev.wave3"

    function reset(): void { root.reset() }
    function refresh(): void { root.refresh() }
  }

  Process {
    id: statusProc
    command: [root.resetScript, "--status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.status = Model.parseStatus(text)
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

  Timer {
    id: errorTimer
    interval: 6000
    onTriggered: root.errorText = ""
  }

  Timer {
    interval: 5000
    running: true
    repeat: true
    triggeredOnStart: true
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
    onPressed: function(b) { root.reset() }
  }
}

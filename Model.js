// Model.js — Pure parsing of `wave3-reset --status` output for the bar widget.
//
// Dual-environment module: loadable directly in Quickshell QML via:
//   import "Model.js" as Model
// and in Node.js unit tests via require("./Model.js").

// Parses key=value lines into a status object. Unknown keys are ignored and
// missing ones fall back to the "absent" shape, so a failed run reads as absent.
function parseStatus(text) {
  var status = {
    present: false,
    isDefault: false,
    muted: false,
    state: "absent",
    profile: "",
    source: ""
  }
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    var eq = line.indexOf("=")
    if (eq <= 0) continue
    var key = line.slice(0, eq)
    var value = line.slice(eq + 1)
    if (key === "present") status.present = value === "yes"
    else if (key === "default") status.isDefault = value === "yes"
    else if (key === "muted") status.muted = value === "yes"
    else if (key === "state") status.state = value || "absent"
    else if (key === "profile") status.profile = value
    else if (key === "source") status.source = value
  }
  if (!status.present) status.state = "absent"
  return status
}

// "absent" (dimmed), "warn" (not default or muted) or "ok".
function statusLevel(status) {
  if (!status || !status.present) return "absent"
  if (!status.isDefault || status.muted) return "warn"
  return "ok"
}

function statusSummary(status) {
  if (!status || !status.present) return "Wave:3 not connected"
  var parts = []
  parts.push(status.isDefault ? "default input" : "not the default input")
  if (status.muted) parts.push("muted")
  if (status.state) parts.push(status.state.toLowerCase())
  return "Wave:3: " + parts.join(", ") + " — click to reset"
}

// Export for Node.js test environment (in QML, top-level functions and vars
// are directly accessible via import namespace).
if (typeof module !== "undefined") {
  module.exports = {
    parseStatus: parseStatus,
    statusLevel: statusLevel,
    statusSummary: statusSummary
  }
}

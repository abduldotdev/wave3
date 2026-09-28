// Model.js — Pure parsing of wave3-reset --status and wave3-hw status,
// and pactl commands and PipeWire node helpers, for the bar widget and its popup.
//
// Dual-environment module: loadable directly in Quickshell QML via:
//   import "Model.js" as Model
// and in Node.js unit tests via require("./Model.js").

// Same name patterns as bin/wave3-reset. The mic's sink monitor is
// alsa_output...monitor, so the source pattern cannot match it.
var SOURCE_PATTERN = /^alsa_input[.]usb-Elgato_Systems_Elgato_Wave_3/
var SINK_PATTERN = /^alsa_output[.]usb-Elgato_Systems_Elgato_Wave_3/

// Integer percent from a status value, -1 when empty or not a number.
function parsePercent(value) {
  if (!/^[0-9]+$/.test(value)) return -1
  return parseInt(value, 10)
}

// Parses key=value lines into a status object. Unknown keys are ignored and
// missing ones fall back to the "absent" shape, so a failed run reads as absent.
function parseStatus(text) {
  var status = {
    present: false,
    isDefault: false,
    isDefaultVirtual: false,
    muted: false,
    state: "absent",
    profile: "",
    source: "",
    volume: -1,
    sink: "",
    sinkVolume: -1,
    sinkMuted: false
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
    else if (key === "default_virtual") status.isDefaultVirtual = value === "yes"
    else if (key === "muted") status.muted = value === "yes"
    else if (key === "state") status.state = value || "absent"
    else if (key === "profile") status.profile = value
    else if (key === "source") status.source = value
    else if (key === "volume") status.volume = parsePercent(value)
    else if (key === "sink") status.sink = value
    else if (key === "sink_volume") status.sinkVolume = parsePercent(value)
    else if (key === "sink_muted") status.sinkMuted = value === "yes"
  }
  if (!status.present) status.state = "absent"
  return status
}

// Parses bin/wave3-hw status key=value output into a hardware status object.
function parseHwStatus(text) {
  var status = {
    present: false,
    access: "",
    device: "",
    api: "",
    supported: false,
    gainDb: 0,
    mute: false,
    clipguard: false,
    lowcut: false,
    hpDb: 0,
    hpMute: false,
    directMonitor: 0,
    volumeSelect: 1,
    ledsOff: false,
    ledsFlip: false,
    gainLock: false,
    raw: "",
    hwReady: false,
    error: "",
    transient: false,
    stale: false
  }
  var hasPresent = false
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    var eq = line.indexOf("=")
    if (eq <= 0) continue
    var key = line.slice(0, eq)
    var value = line.slice(eq + 1)
    if (key === "present") {
      hasPresent = true
      status.present = value === "yes"
    }
    else if (key === "error") status.error = value
    else if (key === "access") status.access = value
    else if (key === "device") status.device = value
    else if (key === "api") status.api = value
    else if (key === "supported") status.supported = value === "yes"
    else if (key === "gain_db") {
      var g = parseFloat(value)
      status.gainDb = isNaN(g) ? 0 : g
    }
    else if (key === "mute") status.mute = value === "1" || value === "yes" || value === "true" || value === "on"
    else if (key === "clipguard") status.clipguard = value === "1" || value === "yes" || value === "true" || value === "on"
    else if (key === "lowcut") status.lowcut = value === "1" || value === "yes" || value === "true" || value === "on"
    else if (key === "hp_db") {
      var h = parseFloat(value)
      status.hpDb = isNaN(h) ? 0 : h
    }
    else if (key === "hp_mute") status.hpMute = value === "1" || value === "yes" || value === "true" || value === "on"
    else if (key === "direct_monitor") {
      var dm = parseInt(value, 10)
      status.directMonitor = isNaN(dm) ? 0 : dm
    }
    else if (key === "volume_select") {
      var vs = parseInt(value, 10)
      status.volumeSelect = isNaN(vs) ? 1 : vs
    }
    else if (key === "leds_off") status.ledsOff = value === "1" || value === "yes" || value === "true" || value === "on"
    else if (key === "leds_flip") status.ledsFlip = value === "1" || value === "yes" || value === "true" || value === "on"
    else if (key === "gain_lock") status.gainLock = value === "1" || value === "yes" || value === "true" || value === "on"
    else if (key === "raw") status.raw = value
  }
  status.transient = Boolean(status.error !== "" && !hasPresent)
  status.hwReady = Boolean(status.present && status.access === "ok" && status.supported)
  if (!status.present) {
    status.access = ""
    status.device = ""
    status.api = ""
    status.supported = false
    status.hwReady = false
  }
  return status
}

// Merges hardware status updates, keeping the last good state on transient errors.
function mergeHwStatus(prev, next) {
  if (!next) next = parseHwStatus("")
  if (next.transient && prev && prev.hwReady) {
    var copy = {}
    for (var k in prev) {
      if (Object.prototype.hasOwnProperty.call(prev, k)) copy[k] = prev[k]
    }
    copy.stale = true
    copy.error = next.error || ""
    return copy
  }
  next.stale = false
  return next
}

// Whether the mic is muted either via pactl or via hardware mute.
function isMuted(status, hwStatus) {
  if (status && status.muted) return true
  if (hwStatus && hwStatus.hwReady && hwStatus.mute) return true
  return false
}

// "absent" (dimmed), "warn" (not default or muted) or "ok".
function statusLevel(status, hwStatus) {
  if (!status || !status.present) return "absent"
  var muted = isMuted(status, hwStatus)
  var effectiveDefault = Boolean(status.isDefault || status.isDefaultVirtual)
  if (!effectiveDefault || muted) return "warn"
  return "ok"
}

function statusSummary(status, hwStatus) {
  if (!status || !status.present) return "Wave:3 not connected"
  var parts = []
  if (status.isDefaultVirtual) parts.push("filter source default")
  else parts.push(status.isDefault ? "default input" : "not the default input")
  if (isMuted(status, hwStatus)) parts.push("muted")
  if (status.state) parts.push(status.state.toLowerCase())
  return "Wave:3: " + parts.join(", ") + " — click for controls, right-click to reset"
}

// Popup header state line.
function headerLine(status) {
  if (!status || !status.present) return "Not connected"
  var parts = []
  if (status.state) parts.push(status.state.toLowerCase())
  if (status.isDefaultVirtual) parts.push("filter source default (e.g. EasyEffects)")
  else parts.push(status.isDefault ? "default input" : "not the default input")
  if (status.profile) parts.push(status.profile)
  return parts.join(" · ")
}

// Integer in 0-100; 0 for anything that is not a number.
function clampPercent(v) {
  var n = Math.round(Number(v))
  if (isNaN(n)) return 0
  return Math.max(0, Math.min(100, n))
}

function sourceName(status) {
  var name = status && status.source ? String(status.source) : ""
  if (!SOURCE_PATTERN.test(name) || /[.]monitor$/.test(name)) return ""
  return name
}

function sinkName(status) {
  var name = status && status.sink ? String(status.sink) : ""
  return SINK_PATTERN.test(name) ? name : ""
}

// Whether a Pipewire node is the Wave:3 input source (non-stream, non-monitor).
// Avoids reading node.properties unbound to prevent destabilizing PipeWire service.
function isWave3SourceNode(node) {
  if (!node || node.isSink || node.isStream) return false
  var name = String(node.name || "")
  if (!SOURCE_PATTERN.test(name) || /[.]monitor$/.test(name)) return false
  return true
}

// Finds the Wave:3 input source node in an array or Pipewire.nodes collection.
// Prefers the node whose name === wanted, else the first prefix match.
function findWave3Source(nodes, wanted) {
  if (!nodes) return null
  var list = (nodes.values && typeof nodes.values !== "function") ? nodes.values : nodes
  var len = list && typeof list.length === "number" ? list.length : 0
  var fallback = null
  var wantedStr = wanted ? String(wanted) : ""
  for (var i = 0; i < len; i++) {
    var n = list[i]
    if (isWave3SourceNode(n)) {
      if (wantedStr && n.name === wantedStr) return n
      if (!fallback) fallback = n
    }
  }
  return fallback
}

// pactl argv arrays by full name, or null when the name is missing or does
// not match its pattern, so nothing is ever sent to another device.
function setSourceVolumeCommand(status, pct) {
  var name = sourceName(status)
  return name ? ["pactl", "set-source-volume", name, clampPercent(pct) + "%"] : null
}

function setSourceMuteCommand(status, muted) {
  var name = sourceName(status)
  return name ? ["pactl", "set-source-mute", name, muted ? "1" : "0"] : null
}

function setSinkVolumeCommand(status, pct) {
  var name = sinkName(status)
  return name ? ["pactl", "set-sink-volume", name, clampPercent(pct) + "%"] : null
}

function setSinkMuteCommand(status, muted) {
  var name = sinkName(status)
  return name ? ["pactl", "set-sink-mute", name, muted ? "1" : "0"] : null
}

function headphonesAvailable(status) {
  return !!(status && status.present && status.sink !== "")
}

function canSetDefault(status) {
  return !!(status && status.present && !status.isDefault)
}

// Slider position for a status percent: unknown reads as 0, boost above the
// hardware maximum is shown as 100.
function sliderValue(v) {
  return v < 0 ? 0 : Math.min(v, 100)
}

function volumeLabel(v) {
  return v === -1 ? "—" : v + " %"
}

// Converts a linear peak (0..1 fraction) into dBFS: 20 * log10(peak).
// Non-positive or invalid peaks return -Infinity.
function peakToDb(peak) {
  var p = Number(peak)
  if (!(p > 0)) return -Infinity
  return 20 * Math.log(p) / Math.LN10
}

function formatDb(db) {
  if (!isFinite(db)) return "-∞ dBFS"
  return Math.round(db) + " dBFS"
}

// Formats a linear peak fraction directly to a dBFS string.
function formatPeakDb(peak) {
  return formatDb(peakToDb(peak))
}

// Meter bar position for a peak fraction on a -60..0 dBFS scale, so speech
// levels use most of the bar.
function meterPosition(peak) {
  var db = peakToDb(peak)
  if (!isFinite(db)) return 0
  return Math.max(0, Math.min(1, (db + 60) / 60))
}

// Peak-hold marker: a higher peak replaces the held value, and after holdMs
// the held value drops to the current peak.
function holdPeak(hold, peak, now, holdMs) {
  if (!hold || peak >= hold.value || now - hold.at >= holdMs) return { value: peak, at: now }
  return hold
}

// Whether the level meter should capture. The popup window can be hidden
// under it (dismissed by the compositor, or its bar window unmapped) while
// open stays true, so the meter needs the popup both open and shown.
function meterRunning(open, shown, present, available) {
  return open === true && shown === true && present === true && available === true
}

// Whether a hardware poll is due. Forced reads always run. Closed-popup
// reads are gated by intervalMs (default 30000); negative elapsed times
// from backwards wall-clock jumps are treated as due so polling does not hang.
function hwPollDue(now, last, force, intervalMs) {
  if (force) return true
  var interval = typeof intervalMs === "number" ? intervalMs : 30000
  var n = Number(now)
  var l = Number(last)
  if (isNaN(n) || isNaN(l)) return true
  var dt = n - l
  return dt < 0 || dt >= interval
}


var HW_FIELD_MAP = {
  gain_db: "gain_db",
  mute: "mute",
  clipguard: "clipguard",
  lowcut: "lowcut",
  hp_db: "hp_db",
  hp_mute: "hp_mute",
  direct_monitor: "direct_monitor",
  volume_select: "volume_select",
  leds_off: "leds_off",
  leds_flip: "leds_flip",
  gain_lock: "gain_lock",
  gainDb: "gain_db",
  hpDb: "hp_db",
  hpMute: "hp_mute",
  directMonitor: "direct_monitor",
  volumeSelect: "volume_select",
  ledsOff: "leds_off",
  ledsFlip: "leds_flip",
  gainLock: "gain_lock"
}

// Builds the argv array for bin/wave3-hw set <field> <value>.
// Returns null for unknown fields or missing script.
function hwSetCommand(script, field, value) {
  if (!script || typeof script !== "string") return null
  if (!field || typeof field !== "string") return null
  var cliField = HW_FIELD_MAP[field]
  if (!cliField) return null
  return [script, "set", cliField, String(value)]
}

// Quantize gain to 0..40 dB in 0.5 steps.
function quantizeGain(v) {
  var n = Number(v)
  if (isNaN(n)) return 0
  var clamped = Math.max(0, Math.min(40, n))
  return Math.round(clamped * 2) / 2
}

// Quantize headphone volume to -60..0 dB in 0.5 steps.
function quantizeHp(v) {
  var n = Number(v)
  if (isNaN(n)) return -60
  var clamped = Math.max(-60, Math.min(0, n))
  return Math.round(clamped * 2) / 2
}

// Quantize direct monitor blend to 0..100 in 5 steps.
function quantizeDirectMonitor(v) {
  var n = Number(v)
  if (isNaN(n)) return 0
  var clamped = Math.max(0, Math.min(100, n))
  return Math.round(clamped / 5) * 5
}

var SAVED_HINT = "Saved · restores on reconnect"

// Parses bin/wave3-hw set stdout key=value lines.
function parseHwSetOutput(text) {
  var result = {
    field: "",
    value: "",
    saved: ""
  }
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    var eq = line.indexOf("=")
    if (eq <= 0) continue
    var key = line.slice(0, eq)
    var value = line.slice(eq + 1)
    if (key === "saved") {
      result.saved = value
    } else if (result.field === "") {
      result.field = key
      result.value = value
    }
  }
  return result
}

// Export for Node.js test environment (in QML, top-level functions and vars
// are directly accessible via import namespace).
if (typeof module !== "undefined") {
  module.exports = {
    parseStatus: parseStatus,
    parseHwStatus: parseHwStatus,
    mergeHwStatus: mergeHwStatus,
    parseHwSetOutput: parseHwSetOutput,
    SAVED_HINT: SAVED_HINT,
    isMuted: isMuted,
    statusLevel: statusLevel,
    statusSummary: statusSummary,
    SOURCE_PATTERN: SOURCE_PATTERN,
    SINK_PATTERN: SINK_PATTERN,
    headerLine: headerLine,
    clampPercent: clampPercent,
    setSourceVolumeCommand: setSourceVolumeCommand,
    setSourceMuteCommand: setSourceMuteCommand,
    setSinkVolumeCommand: setSinkVolumeCommand,
    setSinkMuteCommand: setSinkMuteCommand,
    hwSetCommand: hwSetCommand,
    quantizeGain: quantizeGain,
    quantizeGainDb: quantizeGain,
    quantizeHp: quantizeHp,
    quantizeHpDb: quantizeHp,
    quantizeDirectMonitor: quantizeDirectMonitor,
    headphonesAvailable: headphonesAvailable,
    canSetDefault: canSetDefault,
    sliderValue: sliderValue,
    volumeLabel: volumeLabel,
    isWave3SourceNode: isWave3SourceNode,
    findWave3Source: findWave3Source,
    peakToDb: peakToDb,
    formatDb: formatDb,
    formatPeakDb: formatPeakDb,
    meterPosition: meterPosition,
    holdPeak: holdPeak,
    meterRunning: meterRunning,
    hwPollDue: hwPollDue
  }
}

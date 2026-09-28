// Model.js — Pure parsing of wave3-reset --status and wave3-meter output,
// and the pactl set commands, for the bar widget and its popup.
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
  return "Wave:3: " + parts.join(", ") + " — click for controls, right-click to reset"
}

// Popup header state line.
function headerLine(status) {
  if (!status || !status.present) return "Not connected"
  var parts = []
  if (status.state) parts.push(status.state.toLowerCase())
  parts.push(status.isDefault ? "default input" : "not the default input")
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

// One wave3-meter line (peak |sample|, 0-32767) into a peak fraction and
// dBFS. Returns null for anything else.
function parseMeterLine(line) {
  var text = String(line || "").trim()
  if (!/^[0-9]+$/.test(text)) return null
  var n = parseInt(text, 10)
  if (n > 32767) return null
  var peak = n / 32767
  return { peak: peak, db: peak > 0 ? 20 * Math.log(peak) / Math.LN10 : -Infinity }
}

function formatDb(db) {
  if (!isFinite(db)) return "-∞ dBFS"
  return Math.round(db) + " dBFS"
}

// Meter bar position for a peak fraction on a -60..0 dBFS scale, so speech
// levels use most of the bar.
function meterPosition(peak) {
  if (!(peak > 0)) return 0
  var db = 20 * Math.log(peak) / Math.LN10
  return Math.max(0, Math.min(1, (db + 60) / 60))
}

// Peak-hold marker: a higher peak replaces the held value, and after holdMs
// the held value drops to the current peak.
function holdPeak(hold, peak, now, holdMs) {
  if (!hold || peak >= hold.value || now - hold.at >= holdMs) return { value: peak, at: now }
  return hold
}

// Export for Node.js test environment (in QML, top-level functions and vars
// are directly accessible via import namespace).
if (typeof module !== "undefined") {
  module.exports = {
    parseStatus: parseStatus,
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
    headphonesAvailable: headphonesAvailable,
    canSetDefault: canSetDefault,
    sliderValue: sliderValue,
    volumeLabel: volumeLabel,
    parseMeterLine: parseMeterLine,
    formatDb: formatDb,
    meterPosition: meterPosition,
    holdPeak: holdPeak
  }
}

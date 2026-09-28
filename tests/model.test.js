const test = require("node:test")
const assert = require("node:assert/strict")
const Model = require("../Model.js")

// The three `wave3-reset --status` shapes from the plan's contract C1.
const SRC = "alsa_input.usb-Elgato_Systems_Elgato_Wave_3_TEST123-00.mono-fallback"
const SINK = "alsa_output.usb-Elgato_Systems_Elgato_Wave_3_TEST123-00.analog-stereo"

const OK = `present=yes
default=yes
muted=no
state=SUSPENDED
profile=output:analog-stereo+input:mono-fallback
source=${SRC}
volume=100
sink=${SINK}
sink_volume=45
sink_muted=no
`

const MIC_ABSENT = `present=no
default=no
muted=no
state=absent
profile=output:analog-stereo
volume=
sink=${SINK}
sink_volume=45
sink_muted=no
`

const ABSENT = `present=no
default=no
muted=no
state=absent
profile=
volume=
sink=
sink_volume=
sink_muted=no
`

test("parseStatus reads a present, default mic", () => {
  const s = Model.parseStatus(OK)
  assert.equal(s.present, true)
  assert.equal(s.isDefault, true)
  assert.equal(s.muted, false)
  assert.equal(s.state, "SUSPENDED")
  assert.equal(s.profile, "output:analog-stereo+input:mono-fallback")
  assert.match(s.source, /^alsa_input\.usb-Elgato_Systems_Elgato_Wave_3/)
})

test("parseStatus treats empty, garbage and absent output as absent", () => {
  for (const text of ["", undefined, "garbage\n=x\n", ABSENT]) {
    const s = Model.parseStatus(text)
    assert.equal(s.present, false)
    assert.equal(s.state, "absent")
    assert.equal(Model.statusLevel(s), "absent")
  }
})

test("parseStatus keeps '=' inside values", () => {
  assert.equal(Model.parseStatus("present=yes\nsource=a=b\n").source, "a=b")
})

test("statusLevel flags a mic that is not default or is muted", () => {
  assert.equal(Model.statusLevel(Model.parseStatus(OK)), "ok")
  assert.equal(Model.statusLevel(Model.parseStatus(OK.replace("default=yes", "default=no"))), "warn")
  assert.equal(Model.statusLevel(Model.parseStatus(OK.replace("muted=no", "muted=yes"))), "warn")
  assert.equal(Model.statusLevel(null), "absent")
})

test("statusSummary describes each state", () => {
  assert.equal(Model.statusSummary(Model.parseStatus(ABSENT)), "Wave:3 not connected")
  assert.match(Model.statusSummary(Model.parseStatus(OK)), /default input, suspended/)
  const warn = Model.statusSummary(Model.parseStatus(OK.replace("default=yes", "default=no").replace("muted=no", "muted=yes")))
  assert.match(warn, /not the default input, muted/)
  assert.match(warn, /— click for controls, right-click to reset$/)
})

test("parseStatus reads the volume and sink keys", () => {
  const s = Model.parseStatus(OK)
  assert.equal(s.source, SRC)
  assert.equal(s.volume, 100)
  assert.equal(s.sink, SINK)
  assert.equal(s.sinkVolume, 45)
  assert.equal(s.sinkMuted, false)
  assert.equal(Model.parseStatus(OK.replace("sink_muted=no", "sink_muted=yes")).sinkMuted, true)

  const m = Model.parseStatus(MIC_ABSENT)
  assert.equal(m.present, false)
  assert.equal(m.volume, -1)
  assert.equal(m.sink, SINK)
  assert.equal(m.sinkVolume, 45)

  for (const text of [ABSENT, "", "present=yes\nvolume=abc\nsink_volume=-3\n"]) {
    const a = Model.parseStatus(text)
    assert.equal(a.volume, -1)
    assert.equal(a.sinkVolume, -1)
    assert.equal(a.sinkMuted, false)
  }
  assert.equal(Model.parseStatus(ABSENT).sink, "")
})

test("patterns match the Wave:3 names and not its monitor or other devices", () => {
  assert.match(SRC, Model.SOURCE_PATTERN)
  assert.match(SINK, Model.SINK_PATTERN)
  assert.doesNotMatch(SINK + ".monitor", Model.SOURCE_PATTERN)
  assert.doesNotMatch("alsa_output.pci-0000_0d_00.4.analog-stereo", Model.SINK_PATTERN)
})

test("clampPercent returns an integer in 0-100", () => {
  assert.equal(Model.clampPercent(-5), 0)
  assert.equal(Model.clampPercent(150), 100)
  assert.equal(Model.clampPercent(42.6), 43)
  assert.equal(Model.clampPercent("abc"), 0)
  assert.equal(Model.clampPercent(NaN), 0)
})

test("set commands target the full names from the status", () => {
  const s = Model.parseStatus(OK)
  assert.deepEqual(Model.setSourceVolumeCommand(s, 73.4), ["pactl", "set-source-volume", SRC, "73%"])
  assert.deepEqual(Model.setSourceVolumeCommand(s, 140), ["pactl", "set-source-volume", SRC, "100%"])
  assert.deepEqual(Model.setSourceVolumeCommand(s, -1), ["pactl", "set-source-volume", SRC, "0%"])
  assert.deepEqual(Model.setSourceMuteCommand(s, true), ["pactl", "set-source-mute", SRC, "1"])
  assert.deepEqual(Model.setSourceMuteCommand(s, false), ["pactl", "set-source-mute", SRC, "0"])
  assert.deepEqual(Model.setSinkVolumeCommand(s, 45), ["pactl", "set-sink-volume", SINK, "45%"])
  assert.deepEqual(Model.setSinkVolumeCommand(s, 101), ["pactl", "set-sink-volume", SINK, "100%"])
  assert.deepEqual(Model.setSinkMuteCommand(s, true), ["pactl", "set-sink-mute", SINK, "1"])
  assert.deepEqual(Model.setSinkMuteCommand(s, false), ["pactl", "set-sink-mute", SINK, "0"])
})

test("set commands are null without a matching name", () => {
  const absent = Model.parseStatus(ABSENT)
  assert.equal(Model.setSourceVolumeCommand(absent, 50), null)
  assert.equal(Model.setSourceMuteCommand(absent, true), null)
  assert.equal(Model.setSinkVolumeCommand(absent, 50), null)
  assert.equal(Model.setSinkMuteCommand(absent, true), null)
  assert.equal(Model.setSourceVolumeCommand(null, 50), null)

  const other = Model.parseStatus("present=yes\nsource=alsa_input.pci-0000_0d_00.6.analog-stereo\nsink=alsa_output.pci-0000_0d_00.4.analog-stereo\n")
  assert.equal(Model.setSourceVolumeCommand(other, 50), null)
  assert.equal(Model.setSinkMuteCommand(other, true), null)

  const monitor = Model.parseStatus(`present=yes\nsource=alsa_input.usb-Elgato_Systems_Elgato_Wave_3_TEST123-00.monitor\n`)
  assert.equal(Model.setSourceMuteCommand(monitor, true), null)
})

test("headphone controls need a present mic and a sink", () => {
  assert.equal(Model.headphonesAvailable(Model.parseStatus(OK)), true)
  assert.equal(Model.headphonesAvailable(Model.parseStatus(OK.replace(`sink=${SINK}`, "sink="))), false)
  assert.equal(Model.headphonesAvailable(Model.parseStatus(MIC_ABSENT)), false)
  assert.equal(Model.headphonesAvailable(Model.parseStatus(ABSENT)), false)
})

test("canSetDefault only for a present mic that is not the default", () => {
  assert.equal(Model.canSetDefault(Model.parseStatus(OK)), false)
  assert.equal(Model.canSetDefault(Model.parseStatus(OK.replace("default=yes", "default=no"))), true)
  assert.equal(Model.canSetDefault(Model.parseStatus(ABSENT)), false)
})

test("sliderValue and volumeLabel", () => {
  assert.equal(Model.sliderValue(-1), 0)
  assert.equal(Model.sliderValue(45), 45)
  assert.equal(Model.sliderValue(130), 100)
  assert.equal(Model.volumeLabel(-1), "—")
  assert.equal(Model.volumeLabel(130), "130 %")
  assert.equal(Model.volumeLabel(0), "0 %")
})

test("headerLine describes the mic", () => {
  assert.equal(Model.headerLine(Model.parseStatus(ABSENT)), "Not connected")
  assert.equal(Model.headerLine(Model.parseStatus(MIC_ABSENT)), "Not connected")
  assert.equal(Model.headerLine(Model.parseStatus(OK)), "suspended · default input · output:analog-stereo+input:mono-fallback")
  assert.match(Model.headerLine(Model.parseStatus(OK.replace("default=yes", "default=no"))), / · not the default input · /)
})

test("parseMeterLine reads peak lines and rejects the rest", () => {
  assert.deepEqual(Model.parseMeterLine("0"), { peak: 0, db: -Infinity })
  const full = Model.parseMeterLine("32767\n")
  assert.equal(full.peak, 1)
  assert.ok(Math.abs(full.db) < 0.01)
  const half = Model.parseMeterLine("16384")
  assert.ok(Math.abs(half.peak - 0.5) < 0.001)
  assert.ok(Math.abs(half.db - -6.02) < 0.01)
  for (const line of ["abc", "-5", "40000", "", "12.5", undefined]) assert.equal(Model.parseMeterLine(line), null)
})

test("formatDb and meterPosition", () => {
  assert.equal(Model.formatDb(-Infinity), "-∞ dBFS")
  assert.equal(Model.formatDb(Model.parseMeterLine("0").db), "-∞ dBFS")
  assert.equal(Model.formatDb(Model.parseMeterLine("32767").db), "0 dBFS")
  assert.equal(Model.formatDb(-23.4), "-23 dBFS")
  assert.equal(Model.meterPosition(0), 0)
  assert.equal(Model.meterPosition(1), 1)
  assert.equal(Model.meterPosition(0.0001), 0)
  assert.ok(Math.abs(Model.meterPosition(0.1) - 2 / 3) < 0.001)
})

test("holdPeak holds the highest peak for holdMs", () => {
  let hold = Model.holdPeak(null, 0.2, 0, 1500)
  assert.deepEqual(hold, { value: 0.2, at: 0 })
  hold = Model.holdPeak(hold, 0.5, 100, 1500)
  assert.deepEqual(hold, { value: 0.5, at: 100 })
  hold = Model.holdPeak(hold, 0.1, 1000, 1500)
  assert.deepEqual(hold, { value: 0.5, at: 100 })
  hold = Model.holdPeak(hold, 0.1, 1600, 1500)
  assert.deepEqual(hold, { value: 0.1, at: 1600 })
})

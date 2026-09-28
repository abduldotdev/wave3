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

test("peakToDb and formatPeakDb convert linear peaks to dBFS", () => {
  assert.equal(Model.peakToDb(0), -Infinity)
  assert.equal(Model.peakToDb(-0.5), -Infinity)
  assert.equal(Model.peakToDb(NaN), -Infinity)
  assert.equal(Model.peakToDb(undefined), -Infinity)
  assert.equal(Model.peakToDb(1), 0)
  assert.ok(Math.abs(Model.peakToDb(0.5) - -6.02) < 0.01)
  assert.equal(Model.formatPeakDb(0), "-∞ dBFS")
  assert.equal(Model.formatPeakDb(1), "0 dBFS")
  assert.equal(Model.formatPeakDb(0.5), "-6 dBFS")
  assert.equal(Model.formatPeakDb(-1), "-∞ dBFS")
})

test("isWave3SourceNode and findWave3Source match the Wave:3 source node", () => {
  const wave3Node = { name: SRC, isSink: false, isStream: false }
  const sinkNode = { name: SINK, isSink: true, isStream: false }
  const streamNode = { name: SRC, isSink: false, isStream: true }
  const monitorNode = { name: SINK + ".monitor", isSink: false, isStream: false }
  const otherNode = { name: "alsa_input.pci-0000_0d_00.6.analog-stereo", isSink: false, isStream: false }

  assert.equal(Model.isWave3SourceNode(wave3Node), true)
  assert.equal(Model.isWave3SourceNode(sinkNode), false)
  assert.equal(Model.isWave3SourceNode(streamNode), false)
  assert.equal(Model.isWave3SourceNode(monitorNode), false)
  assert.equal(Model.isWave3SourceNode(otherNode), false)
  assert.equal(Model.isWave3SourceNode(null), false)
  assert.equal(Model.isWave3SourceNode({}), false)

  assert.equal(Model.findWave3Source([sinkNode, otherNode, wave3Node]), wave3Node)
  assert.equal(Model.findWave3Source({ values: [sinkNode, wave3Node] }), wave3Node)
  assert.equal(Model.findWave3Source([sinkNode, otherNode]), null)
  assert.equal(Model.findWave3Source(null), null)
  assert.equal(Model.findWave3Source([]), null)
})

test("formatDb and meterPosition", () => {
  assert.equal(Model.formatDb(-Infinity), "-∞ dBFS")
  assert.equal(Model.formatDb(Model.peakToDb(0)), "-∞ dBFS")
  assert.equal(Model.formatDb(Model.peakToDb(1)), "0 dBFS")
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

test("meterRunning needs the popup open and shown, the mic and the meter", () => {
  assert.equal(Model.meterRunning(true, true, true, true), true)
  // Closed popup, or one hidden while still open, never captures.
  assert.equal(Model.meterRunning(false, true, true, true), false)
  assert.equal(Model.meterRunning(true, false, true, true), false)
  assert.equal(Model.meterRunning(true, true, false, true), false)
  assert.equal(Model.meterRunning(true, true, true, false), false)
  assert.equal(Model.meterRunning(true, true, undefined, true), false)
})

test("parseStatus reads default_virtual key", () => {
  const virt = Model.parseStatus(OK + "default_virtual=yes\n")
  assert.equal(virt.isDefaultVirtual, true)
  const nonVirt = Model.parseStatus(OK + "default_virtual=no\n")
  assert.equal(nonVirt.isDefaultVirtual, false)
  const defaultAbsent = Model.parseStatus(OK)
  assert.equal(defaultAbsent.isDefaultVirtual, false)
})

const HW_OK = `present=yes
access=ok
device=/dev/bus/usb/001/003
api=5.3
supported=yes
gain_db=10.0
mute=0
clipguard=1
lowcut=1
hp_db=-20.5
hp_mute=0
direct_monitor=0
volume_select=1
leds_off=0
leds_flip=0
gain_lock=1
raw=00 0a 00 ec 00 01 01 80 eb 00 00 00 01 00 00 01
`

test("parseHwStatus reads the live block decoded fixture", () => {
  const s = Model.parseHwStatus(HW_OK)
  assert.equal(s.present, true)
  assert.equal(s.access, "ok")
  assert.equal(s.device, "/dev/bus/usb/001/003")
  assert.equal(s.api, "5.3")
  assert.equal(s.supported, true)
  assert.equal(s.hwReady, true)
  assert.equal(s.gainDb, 10.0)
  assert.equal(s.mute, false)
  assert.equal(s.clipguard, true)
  assert.equal(s.lowcut, true)
  assert.equal(s.hpDb, -20.5)
  assert.equal(s.hpMute, false)
  assert.equal(s.directMonitor, 0)
  assert.equal(s.volumeSelect, 1)
  assert.equal(s.ledsOff, false)
  assert.equal(s.ledsFlip, false)
  assert.equal(s.gainLock, true)
  assert.equal(s.raw, "00 0a 00 ec 00 01 01 80 eb 00 00 00 01 00 00 01")
})

test("parseHwStatus treats empty, garbage and absent output as absent shape", () => {
  for (const text of ["", undefined, "garbage\n=x\n", "present=no\n"]) {
    const s = Model.parseHwStatus(text)
    assert.equal(s.present, false)
    assert.equal(s.access, "")
    assert.equal(s.device, "")
    assert.equal(s.api, "")
    assert.equal(s.supported, false)
    assert.equal(s.hwReady, false)
    assert.equal(s.gainDb, 0)
    assert.equal(s.mute, false)
    assert.equal(s.clipguard, false)
    assert.equal(s.lowcut, false)
  }
})

test("parseHwStatus handles permission denied and unsupported api", () => {
  const denied = Model.parseHwStatus(`present=yes
access=denied
device=/dev/bus/usb/001/003
api=
supported=no
`)
  assert.equal(denied.present, true)
  assert.equal(denied.access, "denied")
  assert.equal(denied.supported, false)
  assert.equal(denied.hwReady, false)

  const unsupported = Model.parseHwStatus(`present=yes
access=ok
device=/dev/bus/usb/001/003
api=4.1
supported=no
`)
  assert.equal(unsupported.present, true)
  assert.equal(unsupported.access, "ok")
  assert.equal(unsupported.supported, false)
  assert.equal(unsupported.hwReady, false)
})

test("hwSetCommand builds command for valid fields and rejects unknown/reserved", () => {
  const script = "/opt/plugins/bin/wave3-hw"
  assert.deepEqual(Model.hwSetCommand(script, "gain_db", 10.5), [script, "set", "gain_db", "10.5"])
  assert.deepEqual(Model.hwSetCommand(script, "gainDb", 10.5), [script, "set", "gain_db", "10.5"])
  assert.deepEqual(Model.hwSetCommand(script, "mute", true), [script, "set", "mute", "true"])
  assert.deepEqual(Model.hwSetCommand(script, "clipguard", 1), [script, "set", "clipguard", "1"])
  assert.deepEqual(Model.hwSetCommand(script, "lowcut", 0), [script, "set", "lowcut", "0"])
  assert.deepEqual(Model.hwSetCommand(script, "hp_db", -15.5), [script, "set", "hp_db", "-15.5"])
  assert.deepEqual(Model.hwSetCommand(script, "hpDb", -15.5), [script, "set", "hp_db", "-15.5"])
  assert.deepEqual(Model.hwSetCommand(script, "hp_mute", false), [script, "set", "hp_mute", "false"])
  assert.deepEqual(Model.hwSetCommand(script, "direct_monitor", 50), [script, "set", "direct_monitor", "50"])
  assert.deepEqual(Model.hwSetCommand(script, "volume_select", 2), [script, "set", "volume_select", "2"])
  assert.deepEqual(Model.hwSetCommand(script, "leds_off", 1), [script, "set", "leds_off", "1"])
  assert.deepEqual(Model.hwSetCommand(script, "leds_flip", 1), [script, "set", "leds_flip", "1"])
  assert.deepEqual(Model.hwSetCommand(script, "gain_lock", 1), [script, "set", "gain_lock", "1"])

  // Unknown, reserved or missing
  assert.equal(Model.hwSetCommand(script, "reserved", 1), null)
  assert.equal(Model.hwSetCommand(script, "unknown", 1), null)
  assert.equal(Model.hwSetCommand("", "gain_db", 10), null)
  assert.equal(Model.hwSetCommand(null, "gain_db", 10), null)
})

test("quantizers clamp and round correctly", () => {
  // Gain: 0..40, step 0.5
  assert.equal(Model.quantizeGain(-5), 0)
  assert.equal(Model.quantizeGain(45), 40)
  assert.equal(Model.quantizeGain(10.2), 10.0)
  assert.equal(Model.quantizeGain(10.3), 10.5)
  assert.equal(Model.quantizeGain(10.7), 10.5)
  assert.equal(Model.quantizeGain(10.8), 11.0)
  assert.equal(Model.quantizeGain("abc"), 0)

  // Headphone: -60..0, step 0.5
  assert.equal(Model.quantizeHp(-70), -60)
  assert.equal(Model.quantizeHp(5), 0)
  assert.equal(Model.quantizeHp(-20.2), -20.0)
  assert.equal(Model.quantizeHp(-20.3), -20.5)
  assert.equal(Model.quantizeHp("abc"), -60)

  // Direct monitor: 0..100, step 5
  assert.equal(Model.quantizeDirectMonitor(-10), 0)
  assert.equal(Model.quantizeDirectMonitor(110), 100)
  assert.equal(Model.quantizeDirectMonitor(3), 5)
  assert.equal(Model.quantizeDirectMonitor(2), 0)
  assert.equal(Model.quantizeDirectMonitor(47), 45)
  assert.equal(Model.quantizeDirectMonitor(48), 50)
  assert.equal(Model.quantizeDirectMonitor("abc"), 0)
})

test("icon-state and mute logic with hardware and virtual default", () => {
  const hwOk = Model.parseHwStatus(HW_OK)
  const hwMuted = Model.parseHwStatus(HW_OK.replace("mute=0", "mute=1"))
  const baseStatus = Model.parseStatus(OK)

  // isMuted checks pactl or hw
  assert.equal(Model.isMuted(baseStatus, hwOk), false)
  assert.equal(Model.isMuted(baseStatus, hwMuted), true)
  assert.equal(Model.isMuted(Model.parseStatus(OK.replace("muted=no", "muted=yes")), hwOk), true)

  // Not default, but virtual default suppresses warning
  const notDefault = Model.parseStatus(OK.replace("default=yes", "default=no"))
  assert.equal(Model.statusLevel(notDefault, hwOk), "warn")

  const virtDefault = Model.parseStatus(OK.replace("default=yes", "default=no") + "default_virtual=yes\n")
  assert.equal(Model.statusLevel(virtDefault, hwOk), "ok")
  // But muted still warns
  assert.equal(Model.statusLevel(virtDefault, hwMuted), "warn")

  // State line mentions filter/virtual source
  assert.match(Model.headerLine(virtDefault), /filter source default \(e\.g\. EasyEffects\)/)
  assert.match(Model.statusSummary(virtDefault), /filter source default/)
})

test("mergeHwStatus keeps last good state on transient error (T-8)", () => {
  const good = Model.parseHwStatus(HW_OK)
  assert.equal(good.hwReady, true)
  assert.equal(good.stale, false)
  assert.equal(good.error, "")

  const busy = Model.parseHwStatus("error=busy\n")
  assert.equal(busy.hwReady, false)
  assert.equal(busy.transient, true)
  assert.equal(busy.error, "busy")

  // After a good status, merging error=busy keeps hwReady === true and old field values, with stale === true
  const merged = Model.mergeHwStatus(good, busy)
  assert.equal(merged.hwReady, true)
  assert.equal(merged.stale, true)
  assert.equal(merged.error, "busy")
  assert.equal(merged.gainDb, 10.0)
  assert.equal(merged.clipguard, true)
  assert.equal(merged.lowcut, true)
  assert.equal(merged.hpDb, -20.5)
  assert.equal(merged.volumeSelect, 1)
  assert.equal(merged.raw, good.raw)

  // A following good status gives stale === false
  const recovered = Model.mergeHwStatus(merged, good)
  assert.equal(recovered.hwReady, true)
  assert.equal(recovered.stale, false)
  assert.equal(recovered.error, "")
  assert.equal(recovered.gainDb, 10.0)
})

test("mergeHwStatus with definitive states gives hwReady === false (T-8)", () => {
  const good = Model.parseHwStatus(HW_OK)

  // present=no
  const absent = Model.parseHwStatus("present=no\n")
  assert.equal(absent.transient, false)
  const mergedAbsent = Model.mergeHwStatus(good, absent)
  assert.equal(mergedAbsent.hwReady, false)
  assert.equal(mergedAbsent.stale, false)

  // access=denied
  const denied = Model.parseHwStatus("present=yes\naccess=denied\nsupported=no\n")
  assert.equal(denied.transient, false)
  const mergedDenied = Model.mergeHwStatus(good, denied)
  assert.equal(mergedDenied.hwReady, false)
  assert.equal(mergedDenied.stale, false)

  // supported=no
  const unsupported = Model.parseHwStatus("present=yes\naccess=ok\nsupported=no\n")
  assert.equal(unsupported.transient, false)
  const mergedUnsupported = Model.mergeHwStatus(good, unsupported)
  assert.equal(mergedUnsupported.hwReady, false)
  assert.equal(mergedUnsupported.stale, false)
})

test("mergeHwStatus with no previous good status gives hwReady === false (T-8)", () => {
  const busy = Model.parseHwStatus("error=busy\n")
  const initial = Model.parseHwStatus("")
  const merged = Model.mergeHwStatus(initial, busy)
  assert.equal(merged.hwReady, false)
  assert.equal(merged.stale, false)

  const mergedNull = Model.mergeHwStatus(null, busy)
  assert.equal(mergedNull.hwReady, false)
  assert.equal(mergedNull.stale, false)
})

test("parseHwSetOutput reads various set output forms (T-8)", () => {
  assert.deepEqual(Model.parseHwSetOutput("lowcut=1\nsaved=yes\n"), {
    field: "lowcut",
    value: "1",
    saved: "yes"
  })

  assert.deepEqual(Model.parseHwSetOutput("mute=1\nsaved=no\n"), {
    field: "mute",
    value: "1",
    saved: "no"
  })

  assert.deepEqual(Model.parseHwSetOutput("gain_db=12.5\nsaved=error\n"), {
    field: "gain_db",
    value: "12.5",
    saved: "error"
  })

  assert.deepEqual(Model.parseHwSetOutput("saved=no\n"), {
    field: "",
    value: "",
    saved: "no"
  })

  assert.deepEqual(Model.parseHwSetOutput(""), {
    field: "",
    value: "",
    saved: ""
  })

  assert.deepEqual(Model.parseHwSetOutput(null), {
    field: "",
    value: "",
    saved: ""
  })

  assert.equal(Model.SAVED_HINT, "Saved · restores on reconnect")
})

test("hwPollDue handles forced, intervals, and backwards wall-clock jumps", () => {
  // Forced reads always return true regardless of timing
  assert.equal(Model.hwPollDue(1000, 500, true), true)
  assert.equal(Model.hwPollDue(500, 1000, true), true)
  assert.equal(Model.hwPollDue(0, 0, true), true)

  // Unforced: interval not reached returns false
  assert.equal(Model.hwPollDue(1000, 500, false), false)
  assert.equal(Model.hwPollDue(29999, 0, false), false)
  assert.equal(Model.hwPollDue(100000, 70001, false), false)

  // Unforced: interval reached or exceeded returns true
  assert.equal(Model.hwPollDue(30000, 0, false), true)
  assert.equal(Model.hwPollDue(30001, 0, false), true)
  assert.equal(Model.hwPollDue(100000, 70000, false), true)
  assert.equal(Model.hwPollDue(100000, 50000, false), true)

  // Backwards wall-clock jumps (NTP correction, manual time change)
  // Negative elapsed time must be treated as due so polling does not hang
  assert.equal(Model.hwPollDue(5000, 10000, false), true)
  assert.equal(Model.hwPollDue(100000, 3700000, false), true)

  // Initial poll with last = 0 and current timestamp
  assert.equal(Model.hwPollDue(1700000000000, 0, false), true)

  // Custom intervalMs
  assert.equal(Model.hwPollDue(4999, 0, false, 5000), false)
  assert.equal(Model.hwPollDue(5000, 0, false, 5000), true)
  assert.equal(Model.hwPollDue(6000, 0, false, 5000), true)
  assert.equal(Model.hwPollDue(0, 5000, false, 5000), true)

  // Non-numeric or missing inputs fail-safe to true
  assert.equal(Model.hwPollDue(NaN, 0, false), true)
  assert.equal(Model.hwPollDue(1000, undefined, false), true)
})


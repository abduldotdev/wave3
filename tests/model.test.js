const test = require("node:test")
const assert = require("node:assert/strict")
const Model = require("../Model.js")

const OK = `present=yes
default=yes
muted=no
state=SUSPENDED
profile=output:analog-stereo+input:mono-fallback
source=alsa_input.usb-Elgato_Systems_Elgato_Wave_3_XXXX-00.mono-fallback
`

const ABSENT = `present=no
default=no
muted=no
state=absent
profile=
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
})

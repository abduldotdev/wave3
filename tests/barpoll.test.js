const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")

// BarPoll.js is a Quickshell pragma library. Strip the two QML lines and
// evaluate a fresh copy so each test gets its own registry.
function loadBarPoll() {
  const file = path.join(__dirname, "..", "BarPoll.js")
  let src = fs.readFileSync(file, "utf8")
  src = src.replace(/^\.pragma library\r?\n/, "")
  src = src.replace(/^\.import\s+"Leader\.js"\s+as\s+Leader\r?\n/, "")
  const sandbox = { Leader: require("../Leader.js") }
  vm.createContext(sandbox)
  vm.runInContext(src, sandbox)
  return sandbox
}

function kinds(events, kind) {
  return events.filter((entry) => entry[0] === kind).map((entry) => entry[1])
}

test("setPopupOpen(false) releases the slot, and a second release stays released", () => {
  const bp = loadBarPoll()
  const events = []
  bp.register(1, function(kind, value) { events.push([kind, value]) })
  bp.register(2, function() {})

  assert.equal(bp.popupOpen(), false)
  assert.equal(bp.fastPollerId(), 0)
  assert.equal(bp.isLeader(1), true)

  bp.setPopupOpen(1, true)
  assert.equal(bp.popupOpen(), true)
  assert.equal(bp.fastPollerId(), 1)

  bp.setPopupOpen(1, false)
  assert.equal(bp.popupOpen(), false)
  assert.equal(bp.fastPollerId(), 0)

  bp.setPopupOpen(1, false)
  assert.equal(bp.popupOpen(), false)
  assert.equal(bp.fastPollerId(), 0)
  assert.equal(bp.isLeader(1), true)
  assert.equal(bp.isLeader(2), false)

  assert.deepEqual(kinds(events, "popup"), [false, true, false, false])
  assert.deepEqual(kinds(events, "fast"), [0, 1, 0, 0])
})

test("releasing one popup twice leaves another open popup as the fast poller", () => {
  const bp = loadBarPoll()
  bp.register(1, function() {})
  bp.register(2, function() {})
  bp.setPopupOpen(1, true)
  bp.setPopupOpen(2, true)
  assert.equal(bp.popupOpen(), true)
  assert.equal(bp.fastPollerId(), 1)

  bp.setPopupOpen(1, false)
  bp.setPopupOpen(1, false)
  assert.equal(bp.popupOpen(), true)
  assert.equal(bp.fastPollerId(), 2)
  assert.equal(bp.isLeader(1), true)

  bp.setPopupOpen(2, false)
  bp.setPopupOpen(2, false)
  assert.equal(bp.popupOpen(), false)
  assert.equal(bp.fastPollerId(), 0)
})

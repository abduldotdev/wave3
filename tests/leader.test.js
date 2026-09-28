const test = require("node:test")
const assert = require("node:assert/strict")
const Leader = require("../Leader.js")

test("the first live registrant is leader and leadership passes on", () => {
  const reg = Leader.createRegistry()
  reg.register("a", function() {})
  reg.register("b", function() {})
  reg.register("c", function() {})
  assert.equal(reg.isLeader("a"), true)
  assert.equal(reg.isLeader("b"), false)
  assert.equal(reg.leaderId(), "a")

  reg.unregister("a")
  assert.equal(reg.isLeader("b"), true)
  assert.equal(reg.isLeader("a"), false)
  assert.equal(reg.leaderId(), "b")

  // Dropping a follower leaves the current leader in place.
  reg.unregister("c")
  assert.equal(reg.isLeader("b"), true)

  reg.unregister("b")
  assert.equal(reg.isLeader("b"), false)
  assert.equal(reg.leaderId(), 0)
  assert.equal(reg.isLeader(0), false)
})

test("publish fans out kind and value to every live registrant", () => {
  const reg = Leader.createRegistry()
  const seen = []
  reg.register("a", function(kind, value) { seen.push(["a", kind, value]) })
  reg.register("b", function(kind, value) { seen.push(["b", kind, value]) })
  const status = { present: true }
  reg.publish("status", status)
  assert.equal(seen.length, 2)
  assert.deepEqual(seen[0], ["a", "status", status])
  assert.deepEqual(seen[1], ["b", "status", status])
  assert.equal(seen[0][2], status)
})

test("unregister stops callbacks, including one removed mid-publish", () => {
  const reg = Leader.createRegistry()
  const seen = []
  reg.register("a", function() { seen.push("a") })
  reg.register("b", function() { seen.push("b") })
  reg.unregister("a")
  reg.publish("hw", 1)
  assert.deepEqual(seen, ["b"])

  reg.publish("hw", 2)
  assert.deepEqual(seen, ["b", "b"])

  const during = []
  const reg2 = Leader.createRegistry()
  reg2.register("a", function() {
    during.push("a")
    reg2.unregister("b")
  })
  reg2.register("b", function() { during.push("b") })
  reg2.publish("status", 1)
  assert.deepEqual(during, ["a"])
  reg2.publish("status", 2)
  assert.deepEqual(during, ["a", "a"])
})

test("re-register replaces the callback and keeps leadership", () => {
  const reg = Leader.createRegistry()
  let calls = 0
  reg.register("a", function() { calls = 1 })
  reg.register("b", function() {})
  reg.register("a", function() { calls = 2 })
  assert.equal(reg.isLeader("a"), true)
  reg.publish("status", 0)
  assert.equal(calls, 2)
})

test("unregister of an unknown id is a no-op", () => {
  const reg = Leader.createRegistry()
  reg.register("a", function() {})
  reg.unregister("missing")
  assert.equal(reg.isLeader("a"), true)
  reg.publish("status", 1)
})

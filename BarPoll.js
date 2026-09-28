.pragma library
.import "Leader.js" as Leader

// One registry for every Widget instance in this shell. Background polling
// runs on the leader; an open popup takes over the fast poll. Published
// status is replayed to a bar that appears later.

var registry = Leader.createRegistry()
var nextId = 1
var popupOrder = []
var hwBusy = {}
var cache = { hasStatus: false, status: null, hasHw: false, hw: null }

function allocId() {
  var id = nextId
  nextId = nextId + 1
  return id
}

function popupOpen() {
  return popupOrder.length > 0
}

function fastPollerId() {
  return popupOrder.length ? popupOrder[0] : 0
}

function anyHwBusy() {
  for (var k in hwBusy) return true
  return false
}

function forgetPopup(id) {
  var next = []
  for (var i = 0; i < popupOrder.length; i++) {
    if (popupOrder[i] !== id) next.push(popupOrder[i])
  }
  popupOrder = next
}

function emit(kind, value) {
  if (kind === "status") {
    cache.hasStatus = true
    cache.status = value
  } else if (kind === "hw") {
    cache.hasHw = true
    cache.hw = value
  }
  registry.publish(kind, value)
}

function register(id, callback) {
  registry.register(id, callback)
  callback("leader", registry.leaderId())
  callback("popup", popupOpen())
  callback("fast", fastPollerId())
  callback("hwBusy", anyHwBusy())
  if (cache.hasStatus) callback("status", cache.status)
  if (cache.hasHw) callback("hw", cache.hw)
}

function unregister(id) {
  var wasLeader = registry.isLeader(id)
  forgetPopup(id)
  delete hwBusy[id]
  registry.unregister(id)
  if (wasLeader) registry.publish("leader", registry.leaderId())
  registry.publish("popup", popupOpen())
  registry.publish("fast", fastPollerId())
  registry.publish("hwBusy", anyHwBusy())
}

function setPopupOpen(id, open) {
  forgetPopup(id)
  if (open) popupOrder.push(id)
  registry.publish("popup", popupOpen())
  registry.publish("fast", fastPollerId())
}

function setHwBusy(id, busy) {
  if (busy) hwBusy[id] = true
  else delete hwBusy[id]
  registry.publish("hwBusy", anyHwBusy())
}

function publish(kind, value) {
  emit(kind, value)
}

function isLeader(id) {
  return registry.isLeader(id)
}

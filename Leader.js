// Leader.js — Pure leader registry shared by every bar widget.
//
// BarPoll.js holds the one live registry (.pragma library). This file is the
// testable logic: first live registrant leads, leadership passes to the next
// on unregister, and publish fans out to whoever is still registered.
//
// Dual-environment: Quickshell imports it from BarPoll.js, Node tests require it.
// Ids must be non-zero; 0 means "no leader".

function createRegistry() {
  var ids = []
  var callbacks = {}

  function register(id, callback) {
    if (Object.prototype.hasOwnProperty.call(callbacks, id)) {
      callbacks[id] = callback
      return
    }
    callbacks[id] = callback
    ids.push(id)
  }

  function unregister(id) {
    if (!Object.prototype.hasOwnProperty.call(callbacks, id)) return
    delete callbacks[id]
    var next = []
    for (var i = 0; i < ids.length; i++) {
      if (ids[i] !== id) next.push(ids[i])
    }
    ids = next
  }

  function isLeader(id) {
    return ids.length > 0 && ids[0] === id
  }

  function leaderId() {
    return ids.length ? ids[0] : 0
  }

  function publish(kind, value) {
    var snapshot = ids.slice()
    for (var i = 0; i < snapshot.length; i++) {
      var cb = callbacks[snapshot[i]]
      if (typeof cb === "function") cb(kind, value)
    }
  }

  return {
    register: register,
    unregister: unregister,
    isLeader: isLeader,
    leaderId: leaderId,
    publish: publish
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    createRegistry: createRegistry
  }
}

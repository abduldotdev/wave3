// Entry point so `node --test tests/` works: newer Node resolves a directory
// argument as a module (tests/index.js) instead of scanning it for tests.
const fs = require("node:fs")
const path = require("node:path")

for (const f of fs.readdirSync(__dirname).filter((f) => f.endsWith(".test.js")).sort()) {
  require(path.join(__dirname, f))
}

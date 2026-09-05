// Manifest checks that mirror `omarchy plugin validate`, so CI catches a
// broken plugin contract on a machine that has no Omarchy installed. Run with:
//
//     node test/manifest-test.js
const fs = require("fs")
const path = require("path")
const assert = require("assert")

const root = path.join(__dirname, "..")
const manifest = JSON.parse(fs.readFileSync(path.join(root, "manifest.json"), "utf8"))

let failures = 0
function test(name, fn) {
  try {
    fn()
    console.log("  ok   " + name)
  } catch (e) {
    failures++
    console.log("  FAIL " + name + "\n       " + (e && e.message))
  }
}

test("schemaVersion is the number 1", () => {
  assert.strictEqual(manifest.schemaVersion, 1)
})

test("every required field is present and non-empty", () => {
  for (const field of ["id", "name", "version", "kinds", "entryPoints"]) {
    assert.ok(manifest[field], "missing " + field)
  }
  assert.ok(Array.isArray(manifest.kinds) && manifest.kinds.length > 0)
  assert.strictEqual(typeof manifest.entryPoints, "object")
})

test("the id is namespaced and not in the reserved omarchy.* space", () => {
  assert.ok(/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(manifest.id), manifest.id)
  assert.ok(manifest.id.indexOf("omarchy.") !== 0, manifest.id)
  assert.ok(manifest.id.indexOf("..") === -1)
})

test("each declared kind has the entry point the shell looks for", () => {
  const required = {
    bar: "bar",
    "bar-widget": "barWidget",
    menu: "menu",
    overlay: "overlay",
    panel: "panel",
    service: "service"
  }
  for (const kind of manifest.kinds) {
    const key = required[kind]
    if (!key) continue
    assert.ok(manifest.entryPoints[key], "kind '" + kind + "' needs entryPoints." + key)
  }
})

test("entry point paths are safe and the files exist", () => {
  for (const value of Object.values(manifest.entryPoints)) {
    assert.ok(value && value[0] !== "/", "must be relative: " + value)
    assert.ok(value.indexOf("..") === -1, "must not escape the folder: " + value)
    assert.ok(fs.existsSync(path.join(root, value)), "missing file: " + value)
  }
})

test("a bar widget lands in a real bar section", () => {
  const section = manifest.barWidget && manifest.barWidget.defaultSection
  if (section === undefined) return
  assert.ok(["left", "center", "right"].indexOf(section) !== -1, section)
})

test("every settings key has a matching default", () => {
  const defaults = (manifest.barWidget && manifest.barWidget.defaults) || {}
  for (const field of (manifest.barWidget && manifest.barWidget.schema) || []) {
    assert.ok(field.key in defaults, "schema key without a default: " + field.key)
  }
})

test("the folder holds no symlinks — the shell refuses them", () => {
  const walk = (dir) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      if (entry.name === ".git") continue
      const full = path.join(dir, entry.name)
      assert.ok(!entry.isSymbolicLink(), "symlink: " + full)
      if (entry.isDirectory()) walk(full)
    }
  }
  walk(root)
})

console.log(failures === 0 ? "\nAll manifest tests passed." : "\n" + failures + " test(s) failed.")
process.exit(failures === 0 ? 0 : 1)

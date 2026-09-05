// Unit tests for Model.js — the plugin's pure logic. Run with:
//
//     node test/model-test.js
//
// Model.js is written for QML's JS engine and has no module syntax, so it is
// read and evaluated here rather than imported.
const fs = require("fs")
const path = require("path")
const assert = require("assert")
const vm = require("vm")

const source = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8")
const Model = vm.createContext({})
vm.runInContext(source, Model, { filename: "Model.js" })

// Values created inside the vm realm have their own Array/Object prototypes,
// so deepStrictEqual would reject them on identity alone. Compare the shape.
function plain(value) {
  return JSON.parse(JSON.stringify(value))
}

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

// ---------------------------------------------------------------- addresses

test("a bare host is https first — TrueNAS's own default — then http", () => {
  assert.deepStrictEqual(plain(Model.candidateBases("truenas.local")),
                         ["https://truenas.local", "http://truenas.local"])
  assert.strictEqual(Model.normalizeBase("truenas.local"), "https://truenas.local")
})

test("an explicit port is still ambiguous about the scheme", () => {
  assert.deepStrictEqual(plain(Model.candidateBases("10.0.0.4:31015")),
                         ["https://10.0.0.4:31015", "http://10.0.0.4:31015"])
})

test("a typed scheme is taken at its word, trailing slashes trimmed", () => {
  assert.deepStrictEqual(plain(Model.candidateBases("http://nas.example.com/")),
                         ["http://nas.example.com"])
  assert.deepStrictEqual(plain(Model.candidateBases("https://nas.example.com")),
                         ["https://nas.example.com"])
})

test("an empty address stays empty", () => {
  assert.deepStrictEqual(plain(Model.candidateBases("   ")), [])
  assert.strictEqual(Model.normalizeBase(""), "")
  assert.strictEqual(Model.appsPageUrl(""), "")
})

// The rule that bit the applet: curl can be told to accept the self-signed
// certificate, a browser cannot. The two bases are deliberately different.
test("the web UI opens over http where the API is tried over https", () => {
  assert.strictEqual(Model.normalizeBase("10.0.0.4"), "https://10.0.0.4")
  assert.strictEqual(Model.webUiBase("10.0.0.4"), "http://10.0.0.4")
  assert.strictEqual(Model.appsPageUrl("10.0.0.4"), "http://10.0.0.4/ui/apps/installed")
})

test("an explicit https:// web address is not downgraded", () => {
  assert.strictEqual(Model.webUiBase("https://nas.example.com"), "https://nas.example.com")
  assert.strictEqual(Model.appsPageUrl("https://nas.example.com/"),
                     "https://nas.example.com/ui/apps/installed")
})

// A URL copied out of a browser's address bar keeps its trailing slash. It is
// stripped when a request is built either way, but storing the canonical form
// is what lets the settings form tell "saved" from "unsaved".
test("a stored address drops trailing slashes and surrounding space", () => {
  assert.strictEqual(Model.normalizeAddress("  https://portainer.example.com/  "),
                     "https://portainer.example.com")
  assert.strictEqual(Model.normalizeAddress("https://portainer.example.com//"),
                     "https://portainer.example.com")
  assert.strictEqual(Model.normalizeAddress("truenas.local"), "truenas.local")
  assert.strictEqual(Model.normalizeAddress(""), "")
  assert.strictEqual(Model.normalizeAddress(null), "")
})

test("a trailing slash never reaches the request either way", () => {
  const withSlash = Model.candidateBases("https://portainer.example.com/")
  const without = Model.candidateBases("https://portainer.example.com")
  assert.deepStrictEqual(plain(withSlash), plain(without))
  assert.strictEqual(withSlash[0] + "/api/endpoints",
                     "https://portainer.example.com/api/endpoints")
})

// ---------------------------------------------------------------- curl auth

test("the API key becomes one bearer header line", () => {
  assert.strictEqual(Model.curlAuthConfig("  1-abcDEF  "),
                     "header = \"Authorization: Bearer 1-abcDEF\"\n")
})

test("Portainer gets its own header name", () => {
  assert.strictEqual(Model.curlApiKeyConfig("ptr_key"), "header = \"X-API-Key: ptr_key\"\n")
})

test("a key cannot smuggle a second curl directive into the config", () => {
  const line = Model.curlAuthConfig("x\"\ninsecure\nheader = \"y")
  assert.strictEqual(line.split("\n").length, 2, line)
  assert.ok(line.indexOf("\\\"") !== -1, line)
})

// -------------------------------------------------------------- config file

test("a fresh install starts at TrueNAS's own hostname, certificates accepted", () => {
  const config = Model.parseConfig("not json at all")
  assert.strictEqual(config.address, "truenas.local")
  assert.strictEqual(config.apiKey, "")
  // TrueNAS is self-signed out of the box, so this is on unless turned off.
  assert.strictEqual(config.acceptInvalidCerts, true)
  assert.strictEqual(config.portainerAddress, "")
})

test("config survives a round trip, including a deliberate false", () => {
  const written = Model.serializeConfig({
    address: "nas",
    apiKey: "k",
    acceptInvalidCerts: false,
    portainerAddress: "nas:31015",
    portainerApiKey: "p"
  })
  const back = Model.parseConfig(written)
  assert.strictEqual(back.address, "nas")
  assert.strictEqual(back.apiKey, "k")
  assert.strictEqual(back.acceptInvalidCerts, false)
  assert.strictEqual(back.portainerAddress, "nas:31015")
  assert.strictEqual(back.portainerApiKey, "p")
})

// ------------------------------------------------------------------ replies

test("body and status code are split from the right", () => {
  const r = Model.splitResponse("{\"a\":1}\n\n200")
  assert.strictEqual(r.code, 200)
  assert.strictEqual(r.body, "{\"a\":1}\n")
})

test("a good reply is parsed, an empty body is null", () => {
  assert.deepStrictEqual(plain(Model.interpretResponse("/app", 0, "[1,2]\n200", "").data), [1, 2])
  assert.strictEqual(Model.interpretResponse("/app", 0, "\n200", "").data, null)
})

test("401 names the API key, and Portainer names its token", () => {
  assert.strictEqual(Model.interpretResponse("/app", 0, "\n401", "").error,
                     "Authentication failed — check the API key")
  assert.strictEqual(Model.interpretResponse("/e", 0, "\n403", "", "Portainer").error,
                     "Portainer authentication failed — check the access token")
})

// The one that bit the real server: a proxy in front of a long upgrade job
// answers 504 while the job is still running on the NAS.
test("gateway statuses are unreachable, not a refusal", () => {
  const statuses = [408, 502, 503, 504, 522, 524]
  for (const code of statuses) {
    const r = Model.interpretResponse("/app", 0, "<html>Gateway Timeout</html>\n" + code, "")
    assert.strictEqual(r.ok, false, String(code))
    assert.strictEqual(r.unreachable, true, String(code))
  }
})

test("a real HTTP error keeps its words but drops its markup", () => {
  const r = Model.interpretResponse("/app", 0, "<h1>Bad  Request</h1>\n400", "")
  assert.strictEqual(r.unreachable, false)
  assert.strictEqual(r.error, "/app: HTTP 400: Bad Request")
})

test("a dead connection names the server that did not answer", () => {
  assert.strictEqual(Model.interpretResponse("/app", 7, "", "").error,
                     "Could not reach TrueNAS (connection refused)")
  assert.strictEqual(Model.interpretResponse("/e", 60, "", "", "Portainer").error,
                     "Could not reach Portainer (certificate not trusted)")
})

// --------------------------------------------------------------------- jobs

test("a job id is read from a bare number or a wrapper", () => {
  assert.strictEqual(Model.jobIdFrom(4711), 4711)
  assert.strictEqual(Model.jobIdFrom("4711"), 4711)
  assert.strictEqual(Model.jobIdFrom({ job_id: 12 }), 12)
  assert.strictEqual(Model.jobIdFrom({ nothing: true }), -1)
  assert.strictEqual(Model.jobIdFrom(null), -1)
})

test("a running job reports its percentage as a fraction", () => {
  const out = Model.jobOutcome([{ state: "RUNNING", progress: { percent: 42.5 } }])
  assert.strictEqual(out.state, "running")
  assert.strictEqual(out.percent, 0.425)
})

// Number(null) is 0, which would render as "0% done" and then jump.
test("a job with no percentage reports -1, not 0", () => {
  assert.strictEqual(Model.jobOutcome([{ state: "RUNNING", progress: { percent: null } }]).percent, -1)
  assert.strictEqual(Model.jobOutcome([{ state: "WAITING" }]).percent, -1)
  assert.strictEqual(Model.jobOutcome([{ state: "RUNNING", progress: { percent: 140 } }]).percent, -1)
})

test("every terminal state is recognised, and errors keep their first line", () => {
  assert.strictEqual(Model.jobOutcome([{ state: "SUCCESS" }]).state, "done")
  for (const state of ["FAILED", "ABORTED", "ERROR"]) {
    assert.strictEqual(Model.jobOutcome([{ state: state }]).state, "failed", state)
  }
  const failed = Model.jobOutcome([{ state: "FAILED", error: "pull failed\n  at line 3\n" }])
  assert.strictEqual(failed.error, "pull failed")
  // A failure with no message still says something.
  assert.strictEqual(Model.jobOutcome([{ state: "FAILED" }]).error, "FAILED")
})

test("an empty job list is missing, not failed", () => {
  assert.strictEqual(Model.jobOutcome([]).state, "missing")
  assert.strictEqual(Model.jobOutcome(null).state, "missing")
})

// ----------------------------------------------------------------- the apps

const APPS = [
  { name: "immich", upgrade_available: true, human_version: "1.99.0", latest_version: "1.100.0",
    metadata: { title: "Immich" } },
  { name: "zzz-custom", image_updates_available: true, human_version: "1.0.0" },
  { name: "audiobookshelf", upgrade_available: true, image_updates_available: true,
    human_version: "2.7.0", latest_version: "2.8.0", metadata: { title: "Audiobookshelf" } },
  { name: "plex", human_version: "1.40.0", metadata: { title: "Plex" } }
]

test("apps are split into catalog upgrades and image-only updates", () => {
  const parsed = Model.parseApps(APPS)
  assert.deepStrictEqual(plain(parsed.upgrades).map(i => i.name), ["audiobookshelf", "immich"])
  assert.deepStrictEqual(plain(parsed.images).map(i => i.name), ["zzz-custom"])
  assert.strictEqual(parsed.totalApps, 4)
})

// An app with both bits set gets the catalog upgrade, which pulls images anyway.
test("an app with both flags counts once, as an upgrade", () => {
  const parsed = Model.parseApps(APPS)
  const both = parsed.upgrades.filter(i => i.name === "audiobookshelf")
  assert.strictEqual(both.length, 1)
  assert.strictEqual(parsed.images.filter(i => i.name === "audiobookshelf").length, 0)
})

test("the catalog title wins over the app id, and sorting is case-insensitive", () => {
  const parsed = Model.parseApps(APPS)
  assert.strictEqual(parsed.upgrades[0].title, "Audiobookshelf")
  assert.strictEqual(parsed.images[0].title, "zzz-custom")
})

test("versions read as a transition only when there are two of them", () => {
  const parsed = Model.parseApps(APPS)
  assert.strictEqual(Model.versionsLine(parsed.upgrades[1]), "1.99.0 → 1.100.0")
  assert.strictEqual(Model.versionsLine(parsed.images[0]), "1.0.0")
})

test("a garbage response yields an empty report rather than throwing", () => {
  assert.strictEqual(Model.parseApps(null).totalApps, 0)
  assert.strictEqual(Model.parseApps({ error: "nope" }).totalApps, 0)
  assert.strictEqual(Model.parseApps([null, {}, 3]).totalApps, 0)
})

// --------------------------------------------------------------- containers

const CONTAINERS = [
  { Id: "aaa", Names: ["/dockge"], Image: "louislam/dockge:1", ImageID: "sha256:1",
    Labels: { "com.docker.compose.project": "dockge" } },
  { Id: "bbb", Names: ["/ix-immich-server"], Image: "ghcr.io/immich-app/immich-server:v1.99.0",
    ImageID: "sha256:2", Labels: { "com.docker.compose.project": "ix-immich" } },
  { Id: "ccc", Names: ["/pinned"], Image: "nginx@sha256:deadbeef", ImageID: "sha256:3", Labels: {} },
  { Id: "ddddddddddddddddddd", Names: [], Image: "caddy", ImageID: "sha256:4", Labels: {} }
]

test("TrueNAS's own ix-* containers are left to the apps check", () => {
  const watchable = Model.watchableContainers(CONTAINERS, 2)
  assert.deepStrictEqual(plain(watchable).map(c => c.name), ["dockge", "dddddddddddd"])
  assert.strictEqual(watchable[0].endpointId, 2)
})

test("digest-pinned images are skipped — they cannot drift", () => {
  assert.strictEqual(Model.isPinnedImage("nginx@sha256:deadbeef"), true)
  assert.strictEqual(Model.isPinnedImage("sha256:deadbeef"), true)
  assert.strictEqual(Model.isPinnedImage(""), true)
  assert.strictEqual(Model.isPinnedImage("nginx:1.25"), false)
})

test("a container with no name falls back to a short id", () => {
  assert.strictEqual(Model.containerDisplayName({ Id: "ddddddddddddddddddd", Names: [] }),
                     "dddddddddddd")
})

test("only Docker environments are asked for a container list", () => {
  const endpoints = [{ Id: 1, Type: 1 }, { Id: 2, Type: 2 }, { Id: 3, Type: 5 }, { nope: true }]
  assert.deepStrictEqual(plain(Model.dockerEndpointIds(endpoints)), [1, 2])
})

test("RepoDigests are reduced to their digest halves", () => {
  assert.deepStrictEqual(
    plain(Model.repoDigests({ RepoDigests: ["nginx@sha256:aa", "mirror/nginx@sha256:bb", "junk"] })),
    ["sha256:aa", "sha256:bb"])
  assert.deepStrictEqual(plain(Model.repoDigests({})), [])
})

test("a tag has moved when the registry digest is none of the local ones", () => {
  assert.strictEqual(Model.imageIsStale(["sha256:aa"], "sha256:bb"), true)
  assert.strictEqual(Model.imageIsStale(["sha256:aa", "sha256:bb"], "sha256:bb"), false)
  // Built on the box: nothing at a registry to compare against.
  assert.strictEqual(Model.imageIsStale([], "sha256:bb"), false)
  assert.strictEqual(Model.imageIsStale(["sha256:aa"], ""), false)
})

// ---------------------------------------------------------- registry lookups

test("image references follow Docker's own defaulting rules", () => {
  assert.deepStrictEqual(plain(Model.parseImageRef("nginx")),
                         { registry: "registry-1.docker.io", repo: "library/nginx", tag: "latest" })
  assert.deepStrictEqual(plain(Model.parseImageRef("louislam/dockge:1")),
                         { registry: "registry-1.docker.io", repo: "louislam/dockge", tag: "1" })
  assert.deepStrictEqual(plain(Model.parseImageRef("ghcr.io/immich-app/immich-server:v1.99.0")),
                         { registry: "ghcr.io", repo: "immich-app/immich-server", tag: "v1.99.0" })
})

// The one that trips naive splitting: the ':' here is a port, not a tag.
test("a registry port is not mistaken for a tag", () => {
  assert.deepStrictEqual(plain(Model.parseImageRef("localhost:5000/my/app")),
                         { registry: "localhost:5000", repo: "my/app", tag: "latest" })
  assert.deepStrictEqual(plain(Model.splitNameTag("localhost:5000/my/app")),
                         { name: "localhost:5000/my/app", tag: "latest" })
})

test("the manifest URL is built from the parsed reference", () => {
  assert.strictEqual(Model.manifestUrl(Model.parseImageRef("caddy:2")),
                     "https://registry-1.docker.io/v2/library/caddy/manifests/2")
})

test("a Bearer challenge is parsed into a token URL", () => {
  const challenge = 'Bearer realm="https://auth.docker.io/token",' +
    'service="registry.docker.io",scope="repository:library/nginx:pull"'
  const params = Model.parseChallenge(challenge)
  assert.strictEqual(params.realm, "https://auth.docker.io/token")
  assert.strictEqual(params.service, "registry.docker.io")
  assert.strictEqual(Model.tokenUrl(challenge, "library/nginx"),
    "https://auth.docker.io/token?service=registry.docker.io" +
    "&scope=repository%3Alibrary%2Fnginx%3Apull")
})

test("a challenge with no scope falls back to a pull scope for the repo", () => {
  assert.strictEqual(Model.tokenUrl('Bearer realm="https://auth.example.com/t"', "me/app"),
                     "https://auth.example.com/t?scope=repository%3Ame%2Fapp%3Apull")
  // Nowhere to ask means the lookup gives up rather than guessing.
  assert.strictEqual(Model.tokenUrl("Basic realm=\"x\"", "me/app"), "")
})

test("both spellings of a token response are accepted", () => {
  assert.strictEqual(Model.tokenFrom({ token: "a" }), "a")
  assert.strictEqual(Model.tokenFrom({ access_token: "b" }), "b")
  assert.strictEqual(Model.tokenFrom({}), "")
})

const HEAD_OK = "HTTP/2 200\r\ncontent-type: application/vnd.oci.image.index.v1+json\r\n" +
  "docker-content-digest: sha256:cafe\r\n\r\n\n200"

test("a manifest HEAD yields the digest", () => {
  const r = Model.interpretDigestResponse(0, HEAD_OK, "")
  assert.strictEqual(r.state, "ok")
  assert.strictEqual(r.digest, "sha256:cafe")
})

test("only the last header block counts when the registry redirects", () => {
  const redirected = "HTTP/2 307\r\nlocation: https://elsewhere\r\n\r\n" +
    "HTTP/2 200\r\ndocker-content-digest: sha256:beef\r\n\r\n\n200"
  assert.strictEqual(Model.interpretDigestResponse(0, redirected, "").digest, "sha256:beef")
})

test("a 401 hands back its challenge instead of failing", () => {
  const unauth = "HTTP/2 401\r\nwww-authenticate: Bearer realm=\"https://auth.docker.io/token\"\r\n\r\n\n401"
  const r = Model.interpretDigestResponse(0, unauth, "")
  assert.strictEqual(r.state, "auth")
  assert.strictEqual(Model.parseChallenge(r.challenge).realm, "https://auth.docker.io/token")
})

test("a 200 with no digest header is an error, not a silent pass", () => {
  const r = Model.interpretDigestResponse(0, "HTTP/2 200\r\n\r\n\n200", "")
  assert.strictEqual(r.state, "error")
  assert.strictEqual(r.digest, "")
})

// --------------------------------------------------------------- image pull

test("layer events average into overall pull progress", () => {
  const layers = {}
  Model.applyPullLine(layers, JSON.stringify({ id: "a", status: "Pulling fs layer" }))
  Model.applyPullLine(layers, JSON.stringify({ id: "b", status: "Pulling fs layer" }))
  let r = Model.applyPullLine(layers, JSON.stringify({
    id: "a", status: "Downloading", progressDetail: { current: 50, total: 100 }
  }))
  // a is 0.5 * 0.7 = 0.35, b is still 0 → mean 0.175.
  assert.ok(Math.abs(r.progress - 0.175) < 1e-9, String(r.progress))
  Model.applyPullLine(layers, JSON.stringify({ id: "a", status: "Pull complete" }))
  r = Model.applyPullLine(layers, JSON.stringify({ id: "b", status: "Already exists" }))
  assert.strictEqual(r.progress, 1)
})

test("extraction picks up where the download left off", () => {
  const layers = {}
  const r = Model.applyPullLine(layers, JSON.stringify({
    id: "a", status: "Extracting", progressDetail: { current: 1, total: 2 }
  }))
  assert.ok(Math.abs(r.progress - 0.85) < 1e-9, String(r.progress))
})

test("summary lines, junk and unknown statuses move nothing", () => {
  const layers = { a: 0.5 }
  assert.strictEqual(Model.applyPullLine(layers, "not json").changed, false)
  assert.strictEqual(Model.applyPullLine(layers, JSON.stringify({ status: "Digest: sha256:x" })).changed, false)
  assert.strictEqual(Model.applyPullLine(layers, JSON.stringify({ id: "b", status: "Mystery" })).changed, false)
  assert.deepStrictEqual(plain(layers), { a: 0.5 })
})

test("an error event in the stream is surfaced", () => {
  const r = Model.applyPullLine({}, JSON.stringify({ error: "denied: requested access\nmore" }))
  assert.strictEqual(r.error, "pull: denied: requested access")
})

// ---------------------------------------------------------------- the report

function reportWith(upgrades, images, containers, totalApps, totalContainers) {
  const report = Model.emptyReport()
  report.upgrades = upgrades
  report.images = images
  report.containers = containers
  report.totalApps = totalApps
  report.totalContainers = totalContainers
  return report
}

const A = { key: "app:a", title: "A", current: "1", latest: "2", kind: "app" }
const B = { key: "image:b", title: "B", current: "1", latest: "", kind: "image" }
const C = { key: "container:c", title: "C", current: "caddy", latest: "", kind: "container" }

test("apps are applied before the containers nothing depends on", () => {
  const report = reportWith([A], [B], [C], 9, 4)
  assert.deepStrictEqual(plain(Model.pendingOrder(report)).map(i => i.key),
                         ["app:a", "image:b", "container:c"])
  assert.strictEqual(Model.reportTotal(report), 3)
})

test("every row between the buttons is a cursor stop", () => {
  const rows = Model.navRows(reportWith([A], [B], [C], 9, 4), {})
  assert.deepStrictEqual(plain(rows).map(r => r.kind),
                         ["check", "item", "item", "item", "apply", "open"])
  // Applying is not offered while an apply is already running.
  const busy = Model.navRows(reportWith([A], [], [], 9, 0), { installing: true })
  assert.deepStrictEqual(plain(busy).map(r => r.kind), ["check", "item", "open"])
  // With nothing pending there is nothing to apply.
  const idle = Model.navRows(Model.emptyReport(), {})
  assert.deepStrictEqual(plain(idle).map(r => r.kind), ["check", "open"])
})

// ------------------------------------------------------------------ summary

test("an unconfigured widget says so rather than pretending to check", () => {
  assert.strictEqual(Model.summaryLine({ configured: false }), "Not connected to a TrueNAS server")
})

test("a first check in flight is neutral; a rejected key is not 'connecting'", () => {
  assert.strictEqual(
    Model.summaryLine({ configured: true, everSucceeded: false, offline: false, error: "" }),
    "Connecting to TrueNAS…")
  assert.strictEqual(
    Model.summaryLine({ configured: true, everSucceeded: false, offline: false,
                        error: "Authentication failed — check the API key" }),
    "Not connected to a TrueNAS server")
})

// A laptop that leaves the house should not light up red.
test("an unreachable server is a state, not an error", () => {
  assert.strictEqual(
    Model.summaryLine({ configured: true, everSucceeded: true, offline: true,
                        report: Model.emptyReport() }),
    "TrueNAS not reachable")
})

test("counts read naturally on both sides, singular and plural", () => {
  const base = { configured: true, everSucceeded: true, offline: false }
  assert.strictEqual(
    Model.summaryLine(Object.assign({}, base, { report: reportWith([A], [], [], 9, 0) })),
    "1 update available")
  assert.strictEqual(
    Model.summaryLine(Object.assign({}, base, { report: reportWith([A], [B], [C], 9, 4) })),
    "3 updates available")
  assert.strictEqual(
    Model.summaryLine(Object.assign({}, base, { report: reportWith([], [], [], 9, 0) })),
    "All 9 apps up to date")
  assert.strictEqual(
    Model.summaryLine(Object.assign({}, base, { report: reportWith([], [], [], 9, 4) })),
    "9 apps & 4 containers up to date")
  assert.strictEqual(
    Model.summaryLine(Object.assign({}, base, { report: reportWith([], [], [], 1, 1) })),
    "1 app & 1 container up to date")
  assert.strictEqual(
    Model.summaryLine(Object.assign({}, base, { report: Model.emptyReport() })),
    "No apps found")
})

test("work in progress outranks the counts", () => {
  const report = reportWith([A], [], [], 9, 0)
  const base = { configured: true, everSucceeded: true, offline: false, report: report }
  assert.strictEqual(Model.summaryLine(Object.assign({}, base, { checking: true })),
                     "Checking for updates…")
  assert.strictEqual(Model.summaryLine(Object.assign({}, base, { installing: true, checking: true })),
                     "Installing updates…")
})

console.log(failures === 0 ? "\nAll model tests passed." : "\n" + failures + " test(s) failed.")
process.exit(failures === 0 ? 0 : 1)

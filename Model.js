// Pure logic for the TrueNAS Apps Watcher plugin: no QML types, no I/O.
// Service.qml owns the curl processes and the timers; everything that can be
// decided from a string lives here so it can be reasoned about (and tested
// with `node test/model-test.js`) on its own.
//
// Two servers are talked to. TrueNAS SCALE's middleware REST API (`/api/v2.0`)
// answers for the apps it manages itself. Portainer — optional — answers for
// every other container on the box, through its Docker API proxy, and the
// registries those containers pull from answer for whether a newer image
// exists. All three shapes are parsed here.

// --------------------------------------------------------------- connection

// The base URLs worth trying for an address, best guess first.
//
// TrueNAS ships with a self-signed certificate and redirects http to https, so
// https is the right first guess for a bare host — the opposite of a plain
// appliance. The second guess covers a box whose UI was deliberately put back
// on http; the service falls through to it when the first won't connect, and
// stays there.
function candidateBases(address) {
  var b = String(address || "").replace(/^\s+|\s+$/g, "").replace(/\/+$/, "")
  if (b === "") return []
  if (/^https?:\/\//i.test(b)) return [b]
  if (b.split("/")[0] === "") return []
  return ["https://" + b, "http://" + b]
}

// The best guess on its own, for callers that only need one.
function normalizeBase(address) {
  var candidates = candidateBases(address)
  return candidates.length > 0 ? candidates[0] : ""
}

// An address as it should be *stored*: trimmed, and without the trailing slash
// a browser's address bar hands you when you copy a URL out of it.
// candidateBases() strips one anyway when it builds a request, so this changes
// no traffic — it keeps the settings form honest instead. Saving
// "https://host/" and "https://host" as the same string means the form can
// tell "saved" from "unsaved" by comparing them, and the field shows back
// exactly what was stored.
function normalizeAddress(address) {
  return String(address || "").replace(/^\s+|\s+$/g, "").replace(/\/+$/, "")
}

// Where to point a *browser*, which is a different question from where to
// point curl. curl can be told to accept TrueNAS's self-signed certificate;
// a browser cannot, and just throws a full-page warning at the user. So a
// bare host opens over http unless an https:// URL was typed explicitly.
function webUiBase(address) {
  var b = String(address || "").replace(/^\s+|\s+$/g, "").replace(/\/+$/, "")
  if (b === "") return ""
  if (/^https?:\/\//i.test(b)) return b
  if (b.split("/")[0] === "") return ""
  return "http://" + b
}

// TrueNAS's own list of installed apps, the page this plugin mirrors.
function appsPageUrl(address) {
  var base = webUiBase(address)
  return base === "" ? "" : base + "/ui/apps/installed"
}

// One `header = "…"` line for `curl -K`. Only backslash and double quote are
// special inside a curl config value; an API key is base64-ish so neither ever
// shows up, but a mistyped one must not be able to smuggle a second directive
// into the file.
function curlHeaderConfig(name, value) {
  var v = String(value || "").replace(/^\s+|\s+$/g, "")
  var escaped = v.replace(/\\/g, "\\\\").replace(/"/g, "\\\"").replace(/[\r\n]/g, "")
  return "header = \"" + name + ": " + escaped + "\"\n"
}

// TrueNAS authenticates API keys as a bearer token.
function curlAuthConfig(apiKey) {
  return curlHeaderConfig("Authorization", "Bearer " + String(apiKey || "").replace(/^\s+|\s+$/g, ""))
}

// Portainer uses its own header for user access tokens.
function curlApiKeyConfig(apiKey) {
  return curlHeaderConfig("X-API-Key", apiKey)
}

// ------------------------------------------------------------------ version

// The plugin's own version, for the settings footer and the `version` IPC
// method. It is a constant rather than a read of manifest.json because QML
// gets no handle on its own manifest — the shell's widget registry forwards
// the `barWidget` block, `pluginId` and `sourceDir`, but not the version — and
// reading the file at runtime would be I/O for a string that never changes.
//
// Kept honest by test/manifest-test.js, which fails if this and
// manifest.json's `version` ever disagree.
var VERSION = "1.2.0"

// -------------------------------------------------------------- config file

// TrueNAS SCALE answers on its own hostname out of the box, so that is where a
// fresh install starts. It is a starting point, not a lock: anything the user
// saves replaces it, including an empty address.
var DEFAULT_ADDRESS = "truenas.local"

function parseConfig(raw) {
  var config = {
    address: DEFAULT_ADDRESS,
    apiKey: "",
    // TrueNAS is self-signed out of the box, so this starts on — the opposite
    // of a server the user put behind a real certificate.
    acceptInvalidCerts: true,
    portainerAddress: "",
    portainerApiKey: ""
  }
  var data = null
  try {
    data = JSON.parse(String(raw || ""))
  } catch (e) {
    return config
  }
  if (!data || typeof data !== "object") return config
  if (typeof data.address === "string") config.address = data.address
  if (typeof data.apiKey === "string") config.apiKey = data.apiKey
  if (typeof data.acceptInvalidCerts === "boolean") config.acceptInvalidCerts = data.acceptInvalidCerts
  if (typeof data.portainerAddress === "string") config.portainerAddress = data.portainerAddress
  if (typeof data.portainerApiKey === "string") config.portainerApiKey = data.portainerApiKey
  return config
}

function serializeConfig(config) {
  return JSON.stringify({
    version: 1,
    address: String(config.address || ""),
    apiKey: String(config.apiKey || ""),
    acceptInvalidCerts: config.acceptInvalidCerts !== false,
    portainerAddress: String(config.portainerAddress || ""),
    portainerApiKey: String(config.portainerApiKey || "")
  }, null, 2) + "\n"
}

// ------------------------------------------------------------------ replies

// How many bytes of body each endpoint may deliver. The shell process is
// long-lived and these replies are read into memory, so a compromised or
// simply broken endpoint must not be able to grow it without bound — a
// duration limit does not help, since thirty seconds of a fast stream is
// hundreds of megabytes. Every limit is generous for the reply it covers and
// still small enough to be harmless: the apps list is the biggest legitimate
// one, at a few hundred kilobytes for a full NAS.
var RESPONSE_LIMITS = {
  small: 64 * 1024,           // job records, job ids, catalog sync: a few bytes
  apps: 4 * 1024 * 1024,      // every installed app plus its catalog metadata
  endpoints: 2 * 1024 * 1024, // Portainer's environment list
  containers: 4 * 1024 * 1024,// one Docker environment's containers
  imageInspect: 4 * 1024 * 1024,
  registryHeaders: 256 * 1024,// a manifest HEAD: headers only, no body
  registryToken: 64 * 1024,
  recreate: 256 * 1024,
  pullStream: 8 * 1024 * 1024 // per-layer progress events for a large image
}

// The trailer written by `-w "\n%{http_code} %{exitcode}"`.
//
// curl emits the write-out even when the transfer fails, which is what lets
// its exit code travel *inside* the stream. That matters because curl no
// longer runs as the process: it runs as the left half of a pipeline whose
// ceiling is `head`, so the process exit status belongs to `head`, not to
// curl. The message is deliberately not carried here — `%{errormsg}` can
// contain anything, including a newline, and a trailer that cannot be found
// is worse than a mapped exit code.
function parseTrailer(line) {
  var m = /^(\d{3}) (\d{1,3})$/.exec(String(line || "").replace(/^\s+|\s+$/g, ""))
  if (!m) return null
  return { code: parseInt(m[1], 10), exitCode: parseInt(m[2], 10) }
}

// Split the trailer off the end of a reply. Split from the right so a body
// that ends in a newline survives. `hasTrailer` false means curl never got to
// write it — the stream was cut off, or the pipeline never ran.
function splitResponse(stdout) {
  var text = String(stdout === undefined || stdout === null ? "" : stdout)
  var cut = text.lastIndexOf("\n")
  var trailer = parseTrailer(cut === -1 ? text : text.substring(cut + 1))
  if (!trailer) {
    return { code: 0, exitCode: -1, body: text, hasTrailer: false }
  }
  return {
    code: trailer.code,
    exitCode: trailer.exitCode,
    body: cut === -1 ? "" : text.substring(0, cut),
    hasTrailer: true
  }
}

// "4 MB" / "64 kB", for a message a user can act on.
function describeBytes(bytes) {
  var n = Number(bytes)
  if (!isFinite(n) || n <= 0) return "the size limit"
  if (n >= 1024 * 1024) return Math.round(n / (1024 * 1024)) + " MB"
  return Math.round(n / 1024) + " kB"
}

// Turn one finished curl into either { ok: true, data } or a classified
// failure. `unreachable` marks the transport-level ones — a laptop off the
// home network, or the NAS rebooting mid-upgrade — which callers retry quietly
// instead of reporting. `server` names whichever of the two servers was asked,
// so the message says which one is not answering.
//
// `processExit` is the *pipeline's* status, used only when there is no trailer
// to read curl's own from. `limit` is the byte ceiling that applied, so an
// oversized reply can say so instead of looking like a network fault.
function interpretResponse(path, processExit, stdout, limit, server) {
  var who = String(server || "TrueNAS")
  var response = splitResponse(stdout)

  // No trailer: curl never finished writing. Either the ceiling cut the
  // stream off, or the pipeline itself never ran.
  if (!response.hasTrailer) {
    if (limit && String(stdout || "").length >= limit) {
      return {
        ok: false,
        unreachable: false,
        error: path + ": reply exceeded " + describeBytes(limit) + " and was cut off"
      }
    }
    return {
      ok: false,
      unreachable: true,
      error: "Could not reach " + who + " (" + curlErrorText(processExit, "") + ")"
    }
  }

  if (response.exitCode !== 0) {
    // An oversized reply is a fault at the far end, not a network blip, so it
    // is reported rather than retried quietly forever.
    if (response.exitCode === 63) {
      return {
        ok: false,
        unreachable: false,
        error: path + ": reply exceeded " + describeBytes(limit) + " and was refused"
      }
    }
    return {
      ok: false,
      unreachable: true,
      error: "Could not reach " + who + " (" + curlErrorText(response.exitCode, "") + ")"
    }
  }

  if (response.code === 401 || response.code === 403) {
    return { ok: false, unreachable: false, error: authErrorText(who) }
  }
  if (response.code === 0) {
    return { ok: false, unreachable: true, error: "Could not reach " + who + " (no response)" }
  }
  if (GATEWAY_STATUSES[response.code]) {
    return {
      ok: false,
      unreachable: true,
      error: "Could not reach " + who + " (gateway returned HTTP " + response.code + ")"
    }
  }
  if (response.code >= 400) {
    var snippet = bodySnippet(response.body)
    return { ok: false, unreachable: false, error: path + ": HTTP " + response.code + (snippet ? ": " + snippet : "") }
  }
  if (response.body.replace(/^\s+|\s+$/g, "") === "") return { ok: true, data: null }
  try {
    return { ok: true, data: JSON.parse(response.body) }
  } catch (e) {
    return { ok: false, unreachable: false, error: path + ": invalid JSON (" + e + ")" }
  }
}

function authErrorText(server) {
  if (server === "TrueNAS") return "Authentication failed — check the API key"
  if (server === "Portainer") return "Portainer authentication failed — check the access token"
  return "Authentication rejected by " + server
}

// Statuses that mean the path between here and the server gave out — a reverse
// proxy timing out a long upgrade job, a gateway restarting — rather than the
// server refusing the request. They are transport failures wearing an HTTP
// status, and a job behind one is very likely still running, so callers keep
// polling instead of calling it a failure.
var GATEWAY_STATUSES = { 408: 1, 502: 1, 503: 1, 504: 1, 522: 1, 524: 1 }

// An error body from a proxy is an HTML page. Keep its words, drop its markup,
// so the popup shows a sentence rather than a wall of tags.
function bodySnippet(body) {
  return String(body || "")
    .replace(/<[^>]*>/g, " ")
    .replace(/\s+/g, " ")
    .replace(/^\s+|\s+$/g, "")
    .substring(0, 200)
}

function curlErrorText(exitCode, stderr) {
  var known = {
    6: "host not found",
    7: "connection refused",
    23: "reply too large to read",
    28: "timed out",
    35: "TLS handshake failed",
    51: "certificate not trusted",
    60: "certificate not trusted",
    63: "reply too large"
  }
  if (known[exitCode]) return known[exitCode]
  var detail = String(stderr || "").replace(/\s+/g, " ").replace(/^\s+|\s+$/g, "")
  if (detail !== "") return detail.substring(0, 120)
  return "curl exit " + exitCode
}

// --------------------------------------------------------------------- jobs

// Anything slow in TrueNAS's middleware is a *job*: the call returns a numeric
// id and the work happens in the background. `core.get_jobs?id=` is how you
// find out what became of it.
var JOB_DONE = { SUCCESS: 1 }
var JOB_FAILED = { FAILED: 1, ABORTED: 1, ERROR: 1 }

// A job id, or -1 when the response wasn't one. The REST layer answers with a
// bare number; some builds wrap it in `{ "job_id": n }`.
function jobIdFrom(data) {
  if (typeof data === "number" && isFinite(data)) return Math.round(data)
  if (typeof data === "string" && /^\d+$/.test(data)) return parseInt(data, 10)
  if (data && typeof data === "object") {
    if (typeof data.job_id === "number") return Math.round(data.job_id)
    if (typeof data.id === "number") return Math.round(data.id)
  }
  return -1
}

// A job's own percentage as a 0..1 fraction, or -1 when it isn't reporting one.
// `Number(null)` is 0, which would read as "0% done" — guard before converting.
function jobPercent(job) {
  var raw = job && job.progress ? job.progress.percent : undefined
  if (raw === undefined || raw === null || raw === "") return -1
  var pct = Number(raw)
  if (!isFinite(pct) || pct < 0 || pct > 100) return -1
  return pct / 100
}

// Read one `core.get_jobs` reply into a verdict the caller can act on.
function jobOutcome(data) {
  if (!data || typeof data.length !== "number" || data.length === 0) {
    return { state: "missing", percent: -1, error: "job not found" }
  }
  var job = data[0]
  var state = String((job && job.state) || "")
  if (JOB_DONE[state]) return { state: "done", percent: 1, error: "" }
  if (JOB_FAILED[state]) {
    var detail = firstLine(String((job && job.error) || ""))
    return { state: "failed", percent: -1, error: detail === "" ? state : detail }
  }
  return { state: "running", percent: jobPercent(job), error: "" }
}

function firstLine(text) {
  return String(text || "").split("\n")[0].replace(/^\s+|\s+$/g, "")
}

// ----------------------------------------------------------------- the apps

function emptyReport() {
  return {
    upgrades: [],
    images: [],
    containers: [],
    totalApps: 0,
    totalContainers: 0,
    errors: []
  }
}

// Sort `GET /api/v2.0/app` into the two kinds of pending update TrueNAS knows
// about. `upgrade_available` is a newer catalog version and is applied with
// `app.upgrade`; `image_updates_available` on its own means the same catalog
// version pointing at a newer image (a custom app tracking `latest`), which
// `app.pull_images` fixes without touching the app's config.
function parseApps(list) {
  var upgrades = []
  var images = []
  var total = 0
  if (!list || typeof list.length !== "number") {
    return { upgrades: upgrades, images: images, totalApps: 0 }
  }
  for (var i = 0; i < list.length; i++) {
    var app = list[i]
    if (!app || typeof app.name !== "string") continue
    total++
    var title = (app.metadata && app.metadata.title) ? String(app.metadata.title) : app.name
    var current = app.human_version === null || app.human_version === undefined
      ? "" : String(app.human_version)
    if (app.upgrade_available === true) {
      upgrades.push({
        key: "app:" + app.name,
        name: app.name,
        title: title,
        current: current,
        latest: app.latest_version === null || app.latest_version === undefined
          ? "" : String(app.latest_version),
        kind: "app"
      })
    } else if (app.image_updates_available === true) {
      images.push({
        key: "image:" + app.name,
        name: app.name,
        title: title,
        current: current,
        latest: "",
        kind: "image"
      })
    }
  }
  upgrades.sort(byTitle)
  images.sort(byTitle)
  return { upgrades: upgrades, images: images, totalApps: total }
}

function byTitle(x, y) {
  var a = String(x.title).toLowerCase()
  var b = String(y.title).toLowerCase()
  return a < b ? -1 : (a > b ? 1 : 0)
}

// --------------------------------------------------------------- containers

// Portainer environments that speak Docker: 1 is the local socket, 2 an agent.
// Kubernetes and cloud environments have no container list of this shape.
function dockerEndpointIds(list) {
  var ids = []
  if (!list || typeof list.length !== "number") return ids
  for (var i = 0; i < list.length; i++) {
    var ep = list[i]
    if (!ep || typeof ep.Id !== "number") continue
    if (ep.Type === 1 || ep.Type === 2) ids.push(ep.Id)
  }
  return ids
}

// Containers belonging to a TrueNAS app run in an `ix-<app>` compose project;
// those are already covered by the apps check and must not be counted twice.
function isTrueNasManaged(container) {
  var labels = (container && container.Labels) || {}
  var project = labels["com.docker.compose.project"]
  return typeof project === "string" && project.indexOf("ix-") === 0
}

// --- compose metadata ------------------------------------------------------

function composeLabel(container, name) {
  var labels = (container && container.Labels) || {}
  var value = labels[name]
  return typeof value === "string" ? value : ""
}

function composeProject(container) {
  return composeLabel(container, "com.docker.compose.project")
}

function composeService(container) {
  return composeLabel(container, "com.docker.compose.service")
}

// Where the stack's compose file lives, so a blocked item can say where to go.
function stackWorkingDir(container) {
  return composeLabel(container, "com.docker.compose.project.working_dir")
}

// Only a running container is a candidate for an update. The container list is
// fetched with `?all=1` so that stopped dependents are visible to the checks
// below — without this filter that same flag would make the watcher offer to
// recreate containers the user had deliberately stopped, and start them.
//
// `State` is what current Docker reports; `Status` ("Up 3 days", "Exited (0)
// …") is the older spelling and covers a proxy that only forwards that. If
// neither is present, treat it as running: that is what the list meant before
// `?all=1` was added, and silently updating nothing at all is a worse failure
// than the one this filter exists to prevent.
function isRunning(container) {
  if (!container) return false
  var state = String(container.State || "")
  if (state !== "") return state === "running"
  var status = String(container.Status || "")
  if (status !== "") return status.indexOf("Up") === 0
  return true
}

// --- who depends on whom ---------------------------------------------------

// `com.docker.compose.depends_on` is a comma-separated list of
// `<service>:<condition>:<restart>` entries, e.g.
// "gluetun:service_healthy:false".
function parseDependsOn(value) {
  var out = []
  var parts = String(value || "").split(",")
  for (var i = 0; i < parts.length; i++) {
    var name = parts[i].split(":")[0].replace(/^\s+|\s+$/g, "")
    if (name !== "") out.push(name)
  }
  return out
}

// Containers riding this one's network namespace — the fatal case.
//
// compose's `network_mode: "service:x"` is stored by Docker per container as a
// literal `HostConfig.NetworkMode = "container:<x-id>"`. Recreating x gives it
// a *new* id, so the passenger's namespace target stops existing: it cannot
// start ("No such container"), and a passenger that was already running can
// keep reporting healthy with no network at all, which is worse because
// nothing alarms.
function networkPassengers(container, all) {
  var id = String((container && container.Id) || "")
  var out = []
  if (id === "") return out
  for (var i = 0; i < (all || []).length; i++) {
    var other = all[i]
    if (!other || String(other.Id || "") === id) continue
    var mode = other.HostConfig ? other.HostConfig.NetworkMode : ""
    if (String(mode || "") === "container:" + id) out.push(containerDisplayName(other))
  }
  return out
}

// Containers in the same stack that declared a compose dependency on this
// one's service.
function composeDependants(container, all) {
  var out = []
  var project = composeProject(container)
  var service = composeService(container)
  if (project === "" || service === "") return out
  var id = String((container && container.Id) || "")
  for (var i = 0; i < (all || []).length; i++) {
    var other = all[i]
    if (!other || String(other.Id || "") === id) continue
    if (composeProject(other) !== project) continue
    var deps = parseDependsOn(composeLabel(other, "com.docker.compose.depends_on"))
    for (var j = 0; j < deps.length; j++) {
      if (deps[j] === service) {
        out.push(containerDisplayName(other))
        break
      }
    }
  }
  return out
}

// Whether this container may be recreated on its own, and if not, why.
//
// Portainer's recreate is per container: it renames the old one aside, creates
// a replacement with a new id, and destroys the original. That is safe for a
// standalone container and destructive for one that anything else is attached
// to. Both signals come out of the container list already being fetched, so
// this costs no extra request.
function dependencyBlock(container, all) {
  var names = networkPassengers(container, all)
  var declared = composeDependants(container, all)
  for (var i = 0; i < declared.length; i++) {
    if (names.indexOf(declared[i]) === -1) names.push(declared[i])
  }
  names.sort()
  if (names.length === 0) {
    return { blocked: false, dependents: [], stackDir: "", reason: "" }
  }
  return {
    blocked: true,
    dependents: names,
    stackDir: stackWorkingDir(container),
    reason: dependencyReason(containerDisplayName(container), names, stackWorkingDir(container))
  }
}

// Why the item is refused, and where to go instead. Refusing is the complete
// fix, not a half one: Portainer's recreate reuses the container's existing
// config, which still names the old namespace id, so recreating the dependents
// afterwards reproduces the same breakage. Only `docker compose up -d`
// re-resolves `service:x` to the new id, and this widget has no shell on the
// NAS.
function dependencyReason(name, dependents, stackDir) {
  var n = dependents.length
  var shown = dependents.slice(0, 3).join(", ")
  if (n > 3) shown += ", +" + (n - 3) + " more"
  var text = n + " container" + (n === 1 ? "" : "s") + " depend" + (n === 1 ? "s" : "") +
    " on " + name + " (" + shown + "). Recreating it alone would give it a new id and break " +
    (n === 1 ? "it" : "them") + "."
  if (String(stackDir || "") !== "") return text + " Update the stack instead: " + stackDir
  return text + " Update the whole stack instead (docker compose up -d)."
}

function containerDisplayName(container) {
  var names = (container && container.Names) || []
  for (var i = 0; i < names.length; i++) {
    var n = String(names[i] || "").replace(/^\/+/, "")
    if (n !== "") return n
  }
  return String((container && container.Id) || "").substring(0, 12)
}

// An image pinned by digest, or referenced by raw id, cannot drift — there is
// no tag at a registry to compare it against.
function isPinnedImage(image) {
  var ref = String(image || "")
  return ref === "" || ref.indexOf("@") !== -1 || ref.indexOf("sha256:") === 0
}

// The containers on one endpoint worth asking a registry about. `raw` is the
// container's own list entry, kept so the dependency checks can run against
// the full list later without a second fetch.
function watchableContainers(list, endpointId) {
  var result = []
  if (!list || typeof list.length !== "number") return result
  for (var i = 0; i < list.length; i++) {
    var c = list[i]
    if (!c || typeof c.Id !== "string") continue
    if (isTrueNasManaged(c)) continue
    if (isPinnedImage(c.Image)) continue
    if (!isRunning(c)) continue
    result.push({
      endpointId: endpointId,
      id: c.Id,
      name: containerDisplayName(c),
      image: String(c.Image),
      imageId: String(c.ImageID || ""),
      raw: c
    })
  }
  return result
}

// The `sha256:…` halves of an image's RepoDigests. Empty means the image was
// built locally and has no registry counterpart.
function repoDigests(inspect) {
  var out = []
  var list = (inspect && inspect.RepoDigests) || []
  if (typeof list.length !== "number") return out
  for (var i = 0; i < list.length; i++) {
    var parts = String(list[i] || "").split("@")
    if (parts.length === 2 && parts[1] !== "") out.push(parts[1])
  }
  return out
}

function containerItem(candidate, block) {
  var verdict = block || { blocked: false, dependents: [], stackDir: "", reason: "" }
  return {
    key: "container:" + candidate.id,
    name: candidate.name,
    title: candidate.name,
    current: candidate.image,
    latest: "",
    kind: "container",
    endpointId: candidate.endpointId,
    containerId: candidate.id,
    image: candidate.image,
    // A blocked item is still listed — hiding it would be claiming the update
    // does not exist — but it never joins the apply queue.
    blocked: verdict.blocked === true,
    blockedReason: String(verdict.reason || ""),
    dependents: verdict.dependents || [],
    stackDir: String(verdict.stackDir || "")
  }
}

// ---------------------------------------------------------- registry lookups

// Accept headers covering both Docker and OCI manifests (and their multi-arch
// list/index forms, which is what a tag's top-level digest usually is).
var MANIFEST_ACCEPT = "application/vnd.docker.distribution.manifest.list.v2+json, " +
  "application/vnd.oci.image.index.v1+json, " +
  "application/vnd.docker.distribution.manifest.v2+json, " +
  "application/vnd.oci.image.manifest.v1+json"

// Split an image reference into name and tag (default "latest"). A ':' only
// counts as a tag separator after the last '/', otherwise it is a registry port.
function splitNameTag(image) {
  var ref = String(image || "")
  var cut = ref.lastIndexOf(":")
  if (cut === -1) return { name: ref, tag: "latest" }
  var tag = ref.substring(cut + 1)
  if (tag.indexOf("/") !== -1) return { name: ref, tag: "latest" }
  return { name: ref.substring(0, cut), tag: tag }
}

// Split an image reference into registry host, repository and tag, applying
// Docker's own defaulting rules (Docker Hub, `library/`, `latest`).
function parseImageRef(image) {
  var split = splitNameTag(image)
  var name = split.name
  var slash = name.indexOf("/")
  if (slash !== -1) {
    var host = name.substring(0, slash)
    // The first segment is a host only if it looks like one — that is how
    // Docker itself tells `myuser/app` from `registry.example.com/app`.
    if (host.indexOf(".") !== -1 || host.indexOf(":") !== -1 || host === "localhost") {
      return { registry: host, repo: name.substring(slash + 1), tag: split.tag }
    }
  }
  return {
    registry: "registry-1.docker.io",
    repo: slash === -1 ? "library/" + name : name,
    tag: split.tag
  }
}

function manifestUrl(ref) {
  return "https://" + ref.registry + "/v2/" + ref.repo + "/manifests/" + ref.tag
}

// Parse the `k="v"` pairs of a `WWW-Authenticate: Bearer …` challenge.
function parseChallenge(challenge) {
  var out = {}
  var text = String(challenge || "").replace(/^\s*Bearer\s*/i, "")
  var parts = text.split(",")
  for (var i = 0; i < parts.length; i++) {
    var eq = parts[i].indexOf("=")
    if (eq === -1) continue
    var k = parts[i].substring(0, eq).replace(/^\s+|\s+$/g, "")
    var v = parts[i].substring(eq + 1).replace(/^\s+|\s+$/g, "").replace(/^"|"$/g, "")
    if (k !== "") out[k] = v
  }
  return out
}

// The anonymous pull-token URL named by a challenge. A challenge without a
// realm names nowhere to ask, so the lookup gives up rather than guessing.
function tokenUrl(challenge, repo) {
  var params = parseChallenge(challenge)
  if (!params.realm) return ""
  var query = []
  if (params.service) query.push("service=" + encodeURIComponent(params.service))
  query.push("scope=" + encodeURIComponent(params.scope || ("repository:" + repo + ":pull")))
  return params.realm + (params.realm.indexOf("?") === -1 ? "?" : "&") + query.join("&")
}

function tokenFrom(data) {
  if (!data || typeof data !== "object") return ""
  if (typeof data.token === "string") return data.token
  if (typeof data.access_token === "string") return data.access_token
  return ""
}

// `curl -sSI` prints one header block per response (there can be several when
// a registry redirects) and then the trailer. Read the last block: that is the
// response the status belongs to.
function parseHeadResponse(stdout) {
  var split = splitResponse(stdout)
  var blocks = String(split.body).replace(/\r/g, "").split(/\n\s*\n/)
  var last = ""
  for (var i = 0; i < blocks.length; i++) {
    if (blocks[i].replace(/^\s+|\s+$/g, "") !== "") last = blocks[i]
  }
  var headers = {}
  var lines = last.split("\n")
  for (var j = 0; j < lines.length; j++) {
    var colon = lines[j].indexOf(":")
    if (colon === -1) continue
    var name = lines[j].substring(0, colon).replace(/^\s+|\s+$/g, "").toLowerCase()
    if (name === "" || name.indexOf(" ") !== -1) continue
    headers[name] = lines[j].substring(colon + 1).replace(/^\s+|\s+$/g, "")
  }
  return {
    code: split.code,
    exitCode: split.exitCode,
    hasTrailer: split.hasTrailer,
    headers: headers
  }
}

// What a registry's answer to a manifest HEAD means. A registry is the least
// trusted of the three endpoints — it is whatever host a container image
// happens to name — so the same byte ceiling applies to its headers.
function interpretDigestResponse(processExit, stdout, limit) {
  var head = parseHeadResponse(stdout)
  if (!head.hasTrailer) {
    if (limit && String(stdout || "").length >= limit) {
      return { state: "error", digest: "", challenge: "",
               error: "registry: headers exceeded " + describeBytes(limit) }
    }
    return { state: "error", digest: "", challenge: "",
             error: "registry: " + curlErrorText(processExit, "") }
  }
  if (head.exitCode !== 0) {
    return { state: "error", digest: "", challenge: "",
             error: "registry: " + curlErrorText(head.exitCode, "") }
  }
  if (head.code === 401) {
    return { state: "auth", digest: "", challenge: head.headers["www-authenticate"] || "", error: "" }
  }
  if (head.code < 200 || head.code >= 300) {
    return { state: "error", digest: "", challenge: "", error: "registry: HTTP " + head.code }
  }
  var digest = head.headers["docker-content-digest"] || ""
  if (digest === "") {
    return { state: "error", digest: "", challenge: "", error: "registry did not return a digest" }
  }
  return { state: "ok", digest: digest, challenge: "", error: "" }
}

// Watchtower's rule: the tag has moved when the registry's digest for it is
// none of the digests the running image was pulled under. An image with no
// local digests at all was built on the box and is never stale.
//
// The comparison is against every RepoDigest the image carries, not just the
// first: an image pulled through a mirror has one digest per repository it is
// known by, and only one of them will match the registry being asked.
function imageIsStale(localDigests, remoteDigest) {
  if (!remoteDigest) return false
  var list = localDigests || []
  if (list.length === 0) return false
  for (var i = 0; i < list.length; i++) if (list[i] === remoteDigest) return false
  return true
}

// --------------------------------------------------------------- image pull

// `POST /images/create` streams newline-delimited JSON, one event per layer
// state change. Docker weighs nothing itself, so each layer counts its download
// as 70% of its own work and its extraction as the remaining 30%; overall
// progress is the mean across the layers seen so far.
//
// `layers` is the caller's accumulator and is updated in place.
function applyPullLine(layers, line) {
  var event = null
  try {
    event = JSON.parse(String(line || "").replace(/^\s+|\s+$/g, ""))
  } catch (e) {
    return { changed: false, progress: -1, error: "" }
  }
  if (!event || typeof event !== "object") return { changed: false, progress: -1, error: "" }
  if (typeof event.error === "string" && event.error !== "") {
    return { changed: false, progress: -1, error: "pull: " + firstLine(event.error) }
  }
  // Digest and summary lines carry no layer id.
  var id = typeof event.id === "string" ? event.id : ""
  if (id === "") return { changed: false, progress: -1, error: "" }

  var fraction = layerFraction(event)
  if (fraction < 0) return { changed: false, progress: -1, error: "" }
  layers[id] = fraction

  var sum = 0
  var n = 0
  for (var key in layers) {
    if (!layers.hasOwnProperty(key)) continue
    sum += layers[key]
    n++
  }
  return { changed: true, progress: n === 0 ? -1 : sum / n, error: "" }
}

function layerFraction(event) {
  var status = String(event.status || "")
  var detail = detailFraction(event)
  if (status === "Pulling fs layer" || status === "Waiting") return 0
  if (status === "Downloading") return detail < 0 ? -1 : detail * 0.7
  if (status === "Verifying Checksum" || status === "Download complete") return 0.7
  if (status === "Extracting") return detail < 0 ? -1 : 0.7 + detail * 0.3
  if (status === "Pull complete" || status === "Already exists") return 1
  return -1
}

function detailFraction(event) {
  var d = event.progressDetail
  if (!d || typeof d !== "object") return -1
  var current = Number(d.current)
  var total = Number(d.total)
  if (!isFinite(current) || !isFinite(total) || total <= 0) return -1
  return Math.min(1, current / total)
}

// ---------------------------------------------------------------- the report

// The containers that may actually be recreated on their own.
function actionableContainers(report) {
  var out = []
  var list = (report && report.containers) || []
  for (var i = 0; i < list.length; i++) if (!list[i].blocked) out.push(list[i])
  return out
}

// The containers something else is attached to. Pending, listed, and refused.
function blockedContainers(report) {
  var out = []
  var list = (report && report.containers) || []
  for (var i = 0; i < list.length; i++) if (list[i].blocked) out.push(list[i])
  return out
}

// What the badge counts and what Apply would act on: only what can be applied.
function reportTotal(report) {
  if (!report) return 0
  return report.upgrades.length + report.images.length + actionableContainers(report).length
}

function blockedTotal(report) {
  return blockedContainers(report).length
}

// Everything pending, in the order it is applied. TrueNAS's own apps go first
// and one at a time — parallel upgrades would compete for the same Docker
// daemon and the same pool datasets — and the unmanaged containers come last.
//
// Containers that anything else depends on are left out entirely. Portainer's
// recreate is per container and gives the replacement a new id; a container
// whose namespace or start order something else is pinned to cannot be
// replaced that way without breaking it. This was not a theory: on
// 2026-09-09 recreating `gluetun` took qBittorrent and FlareSolverr down for
// twenty minutes, and FlareSolverr kept reporting healthy with no network,
// so nothing alarmed. They are listed with a reason instead — see
// dependencyBlock().
function pendingOrder(report) {
  if (!report) return []
  return report.upgrades.concat(report.images).concat(actionableContainers(report))
}

// Everything the panel draws, in the order it draws them. Unlike the apply
// order this includes the blocked containers: an update that exists must be
// visible even when this widget is the wrong tool for it.
// Draw order, which the panel's sections must match exactly — the keyboard
// cursor walks this list by index.
function displayItems(report) {
  if (!report) return []
  return report.upgrades
    .concat(report.images)
    .concat(actionableContainers(report))
    .concat(blockedContainers(report))
}

function versionsLine(item) {
  if (!item) return ""
  if (item.current === "") return item.latest
  if (item.latest === "") return item.current
  return item.current + " → " + item.latest
}

// ------------------------------------------------------------------ summary

// The one line under the panel title (and the bar tooltip). Mirrors the
// applet: an unreachable server is a neutral state, not an error, because a
// laptop that leaves the house should not light up red.
function summaryLine(state) {
  if (!state.configured) return "Not connected to a TrueNAS server"
  // A hard failure that no check has ever got past — a rejected API key, a
  // proxy in the way — is not "connecting", however long it keeps trying.
  // The error itself is spelled out on its own line under this one.
  if (!state.everSucceeded && !state.offline && String(state.error || "") !== "") {
    return "Not connected to a TrueNAS server"
  }
  if (!state.everSucceeded && !state.offline) return "Connecting to TrueNAS…"
  var report = state.report || emptyReport()
  var total = reportTotal(report)
  if (state.offline && total === 0 && report.totalApps === 0) return "TrueNAS not reachable"
  if (state.installing) return "Installing updates…"
  if (state.checking) return "Checking for updates…"
  if (total > 0) return total + " update" + (total === 1 ? "" : "s") + " available"
  // Nothing to apply, but something is pending: saying "up to date" here would
  // be a lie the user could only discover by opening Dockge.
  var blocked = blockedTotal(report)
  if (blocked > 0) {
    return blocked + " update" + (blocked === 1 ? "" : "s") + " need" + (blocked === 1 ? "s" : "") +
      " a stack update"
  }
  if (report.totalApps === 0 && report.totalContainers === 0) return "No apps found"
  if (report.totalContainers === 0) {
    return "All " + report.totalApps + " app" + (report.totalApps === 1 ? "" : "s") + " up to date"
  }
  return report.totalApps + " app" + (report.totalApps === 1 ? "" : "s") +
    " & " + report.totalContainers + " container" + (report.totalContainers === 1 ? "" : "s") +
    " up to date"
}

// --------------------------------------------------------------- navigation

// The panel's rows, flattened into one list so j/k walks the whole popup:
// section headers are skipped, everything actionable is a stop.
function navRows(report, options) {
  var rows = [{ kind: "check" }]
  var items = displayItems(report)
  for (var i = 0; i < items.length; i++) rows.push({ kind: "item", item: items[i] })
  if (reportTotal(report) > 0 && !(options && options.installing)) rows.push({ kind: "apply" })
  rows.push({ kind: "open" })
  return rows
}

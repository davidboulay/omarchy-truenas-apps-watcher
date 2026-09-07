import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// TrueNAS backend for the bar widget.
//
// Two sources, one list. TrueNAS SCALE's middleware REST API (`/api/v2.0`,
// authenticated with an API key) reports the apps it manages itself: a newer
// catalog version is `app.upgrade`, a newer image under the same version is
// `app.pull_images`. Both are middleware *jobs* — the call hands back an id and
// the work happens in the background, polled through `core.get_jobs`.
//
// Everything else running on the box — compose stacks, Dockge, hand-started
// containers — TrueNAS knows nothing about, so an optional Portainer
// connection covers those: its Docker API proxy lists them, their registries
// say whether the tag has moved, and a pull-and-recreate applies it.
//
// The calls are made with curl rather than a QML XMLHttpRequest so the keys can
// be handed over in `-K` config files (mode 600, in a 700 directory) instead of
// an argv anyone with `ps` can read.
Item {
  id: root

  property var settings: ({})

  // ---------------------------------------------------------- saved config
  //
  // Connection details live in their own file rather than in shell.json:
  // shell.json is world-readable and gets pasted into support threads, and a
  // TrueNAS API key is root on the whole NAS.
  readonly property string configDir: Quickshell.env("HOME") + "/.config/omarchy/truenas-apps-watcher"
  readonly property string configPath: configDir + "/config.json"
  readonly property string authPath: configDir + "/auth.conf"
  readonly property string portainerAuthPath: configDir + "/portainer-auth.conf"

  property string address: ""
  property string apiKey: ""
  // TrueNAS ships a self-signed certificate, so this starts on.
  property bool acceptInvalidCerts: true
  property string portainerAddress: ""
  property string portainerApiKey: ""
  property bool configLoaded: false

  readonly property bool configured: String(address).replace(/^\s+|\s+$/g, "") !== ""
    && String(apiKey).replace(/^\s+|\s+$/g, "") !== ""
  readonly property bool portainerConfigured: String(portainerAddress).replace(/^\s+|\s+$/g, "") !== ""
    && String(portainerApiKey).replace(/^\s+|\s+$/g, "") !== ""

  // A bare host is https first (TrueNAS's own default) and http second, for a
  // box that was deliberately put back on plain http. The check falls through
  // when one won't connect and stays on whichever answered; reset whenever the
  // address changes.
  readonly property var baseCandidates: Model.candidateBases(address)
  property int baseIndex: 0
  readonly property string baseUrl: baseCandidates.length === 0
    ? ""
    : baseCandidates[Math.min(baseIndex, baseCandidates.length - 1)]

  readonly property var portainerCandidates: Model.candidateBases(portainerAddress)
  property int portainerIndex: 0
  readonly property string portainerBase: portainerCandidates.length === 0
    ? ""
    : portainerCandidates[Math.min(portainerIndex, portainerCandidates.length - 1)]

  // Derived from the typed address, never from whichever candidate curl
  // settled on: a browser has no "accept this certificate" switch, so the web
  // UI opens over http unless an https:// URL was typed.
  readonly property string webUiUrl: Model.appsPageUrl(address)

  onAddressChanged: baseIndex = 0
  onPortainerAddressChanged: portainerIndex = 0

  // ------------------------------------------------------------ live state

  property var appsPart: ({ upgrades: [], images: [], totalApps: 0 })
  property var containerPart: ({ containers: [], totalContainers: 0 })

  readonly property var report: ({
    upgrades: appsPart.upgrades,
    images: appsPart.images,
    containers: containerPart.containers,
    totalApps: appsPart.totalApps,
    totalContainers: containerPart.totalContainers,
    errors: []
  })

  property bool checking: false
  property bool checkingContainers: false
  property bool everSucceeded: false
  property bool offline: false
  property string lastCheckedText: ""
  property string lastError: ""
  property string actionError: ""
  // Portainer keeps its own two states: the apps list is still worth showing
  // when only the container half is having trouble.
  property string containerError: ""
  property bool containersOffline: false

  property bool installing: false
  // -1 while an install is running with nothing to show yet; 0..1 otherwise.
  property real installProgress: -1
  property string installingTitle: ""

  readonly property int pendingTotal: Model.reportTotal(report)
  readonly property string summary: Model.summaryLine({
    configured: root.configured,
    everSucceeded: root.everSucceeded,
    offline: root.offline,
    checking: root.checking || root.checkingContainers,
    installing: root.installing,
    error: root.lastError,
    report: root.report
  })
  readonly property bool busy: checking || checkingContainers || installing

  readonly property int refreshIntervalMin: intSetting("refreshIntervalMin", 30, 5, 720)
  // Every unique image costs a round trip to its registry — two, the first
  // time, for the anonymous token. Measured against Docker Hub, a manifest
  // HEAD does not spend the anonymous pull allowance (100/hour by IP: four
  // HEADs left `ratelimit-remaining` at 100), so this is about network chatter
  // rather than a quota. It still runs far less often than the apps check:
  // an image tag moves on the order of days, not minutes.
  readonly property int containerIntervalHours: intSetting("containerIntervalHours", 6, 1, 168)

  signal configSaved()

  // Quiet 20-second retries before an unreachable server is reported —
  // roughly five minutes of grace after login, when the network is often not
  // up yet and a red banner would help nobody.
  readonly property int maxSilentRetries: 15
  property int silentRetries: 0
  property bool lastCheckManual: false

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  // ---------------------------------------------------------------- config

  function saveConfig(next) {
    root.address = Model.normalizeAddress(next.address)
    root.apiKey = String(next.apiKey || "").replace(/^\s+|\s+$/g, "")
    root.acceptInvalidCerts = next.acceptInvalidCerts !== false
    root.portainerAddress = Model.normalizeAddress(next.portainerAddress)
    root.portainerApiKey = String(next.portainerApiKey || "").replace(/^\s+|\s+$/g, "")
    writeConfig()
    // Start over against the new server: stale counts from the old one would
    // otherwise sit in the bar until the first check lands.
    root.appsPart = { upgrades: [], images: [], totalApps: 0 }
    root.containerPart = { containers: [], totalContainers: 0 }
    root.everSucceeded = false
    root.offline = false
    root.containersOffline = false
    root.silentRetries = 0
    root.lastError = ""
    root.actionError = ""
    root.containerError = ""
    root.containerRetries = 0
    root.configSaved()
    check(false)
    checkContainers()
  }

  function writeConfig() {
    configFile.setText(Model.serializeConfig({
      address: root.address,
      apiKey: root.apiKey,
      acceptInvalidCerts: root.acceptInvalidCerts,
      portainerAddress: root.portainerAddress,
      portainerApiKey: root.portainerApiKey
    }))
    authFile.setText(Model.curlAuthConfig(root.apiKey))
    portainerAuthFile.setText(Model.curlApiKeyConfig(root.portainerApiKey))
    // The directory is 700, so a file that lands 644 for a moment is still
    // unreachable by anyone else; tighten it anyway.
    hardenProc.running = true
  }

  function applyConfig(raw) {
    var parsed = Model.parseConfig(raw)
    // Normalised on the way in as well as on the way out: a hand-edited
    // config.json is just as likely to carry a pasted trailing slash.
    root.address = Model.normalizeAddress(parsed.address)
    root.apiKey = parsed.apiKey
    root.acceptInvalidCerts = parsed.acceptInvalidCerts
    root.portainerAddress = Model.normalizeAddress(parsed.portainerAddress)
    root.portainerApiKey = parsed.portainerApiKey
    root.configLoaded = true
    // Keys that were edited by hand need their curl configs regenerated.
    if (root.apiKey !== "") authFile.setText(Model.curlAuthConfig(root.apiKey))
    if (root.portainerApiKey !== "") portainerAuthFile.setText(Model.curlApiKeyConfig(root.portainerApiKey))
    if (root.configured) check(false)
    if (root.portainerConfigured) checkContainers()
  }

  // ------------------------------------------------------------------ curl

  // Two ceilings on every reply, because one is not enough.
  //
  // `--max-filesize` is curl's own: it ends the transfer cleanly with exit 63
  // and still writes the trailer, so the failure explains itself. But it is
  // documented to do nothing when the length is not known in advance, which
  // is exactly the shape a hostile endpoint would choose, and how much it
  // catches varies by curl version.
  //
  // So `head -c` is the backstop. It closes the pipe, curl dies on its next
  // write, and the bytes that reach QML are bounded whatever the transfer or
  // content encoding — chunked, gzipped, or an endless stream. Measured: it
  // stops a chunked flood in about four milliseconds.
  //
  // The cost is that the process is now a pipeline, so its exit status belongs
  // to `head`. curl's own code travels in the `-w` trailer instead, which also
  // makes stderr redundant — it is discarded rather than collected, so there
  // is no second unbounded buffer.
  function capped(args, limit) {
    return ["bash", "-c", 'cap="$1"; shift; "$@" 2>/dev/null | head -c "$cap"',
            "--", String(limit + 4096)].concat(args)
  }

  // maxTime is in seconds, limit in bytes. GET bodies are never used; `body`
  // is a JSON string.
  function curlCommand(method, path, body, maxTime, limit) {
    return buildCurl(root.baseUrl, root.authPath, method, path, body, maxTime, limit)
  }

  function portainerCommand(method, path, body, maxTime, limit) {
    return buildCurl(root.portainerBase, root.portainerAuthPath, method, path, body, maxTime, limit)
  }

  function buildCurl(base, authFilePath, method, path, body, maxTime, limit) {
    var args = ["curl", "-sS", "--connect-timeout", "10", "--max-time", String(maxTime),
                "--max-filesize", String(limit),
                "-w", "\n%{http_code} %{exitcode}", "-K", authFilePath]
    if (root.acceptInvalidCerts) args.push("--insecure")
    if (method !== "GET") args.push("-X", method)
    if (body !== null && body !== undefined) {
      args.push("-H", "Content-Type: application/json", "--data-binary", body)
    }
    args.push(base + path)
    return capped(args, limit)
  }

  // Registry lookups go straight to Docker Hub / ghcr / lscr, not through
  // either server, so they carry neither `-K` file — sending the NAS's API key
  // to a public registry would be a real leak. The (short-lived, anonymous)
  // pull token still goes over stdin rather than argv, same rule as the rest.
  //
  // A registry is also the least trusted endpoint here: it is whichever host a
  // container image happens to name. Its headers get the same ceiling.
  function registryHeadCommand(url) {
    var limit = Model.RESPONSE_LIMITS.registryHeaders
    var args = ["curl", "-sSI", "-L", "--connect-timeout", "10", "--max-time", "30",
                "--max-filesize", String(limit),
                "-w", "\n%{http_code} %{exitcode}", "-K", "-",
                "-H", "Accept: " + Model.MANIFEST_ACCEPT]
    if (root.acceptInvalidCerts) args.push("--insecure")
    args.push(url)
    return capped(args, limit)
  }

  function registryGetCommand(url) {
    var limit = Model.RESPONSE_LIMITS.registryToken
    var args = ["curl", "-sS", "-L", "--connect-timeout", "10", "--max-time", "30",
                "--max-filesize", String(limit),
                "-w", "\n%{http_code} %{exitcode}"]
    if (root.acceptInvalidCerts) args.push("--insecure")
    args.push(url)
    return capped(args, limit)
  }

  // ------------------------------------------------------------ apps check

  // `refresh` first asks TrueNAS to re-sync its app catalog — the same thing
  // its own daily cron does — so a manual check reflects versions published
  // since the last sync rather than the last sync's snapshot.
  function check(refresh) {
    if (!root.configured || root.installing) return
    if (appsProc.running || syncProc.running || root._jobPurpose === "sync") return
    root.lastCheckManual = refresh === true
    root._candidateTries = 0
    root.checking = true
    if (refresh === true) startCatalogSync()
    else runAppsQuery()
  }

  // How many base candidates this round of checking has already burned
  // through, so a two-candidate address is tried twice and then reported.
  property int _candidateTries: 0

  function startCatalogSync() {
    // `catalog.sync` takes no arguments, which the REST layer maps to GET
    // (POST answers 405).
    syncProc.command = curlCommand("GET", "/api/v2.0/catalog/sync", null, 60, Model.RESPONSE_LIMITS.small)
    syncProc.running = true
  }

  function runAppsQuery() {
    appsProc.command = curlCommand("GET", "/api/v2.0/app", null, 30, Model.RESPONSE_LIMITS.apps)
    appsProc.running = true
  }

  function handleApps(result) {
    if (!result.ok) {
      root.checking = false
      if (result.unreachable) {
        // https didn't answer — try the http shape before deciding the NAS is
        // away.
        if (root._candidateTries + 1 < root.baseCandidates.length) {
          root._candidateTries++
          root.baseIndex = (root.baseIndex + 1) % root.baseCandidates.length
          root.checking = true
          Qt.callLater(function() { root.runAppsQuery() })
          return
        }
        root._candidateTries = 0
        handleUnreachable()
        return
      }
      root.lastError = result.error
      root.offline = false
      return
    }

    var parsed = Model.parseApps(result.data)
    root._candidateTries = 0
    root.everSucceeded = true
    root.silentRetries = 0
    root.offline = false
    root.appsPart = parsed
    root.lastError = ""
    root.lastCheckedText = Qt.formatDateTime(new Date(), "HH:mm")
    root.checking = false

    // The NAS is back. If Portainer went quiet earlier it was probably the
    // same outage, so give the container half another go now rather than
    // waiting hours for its own timer.
    if (root.containersOffline) checkContainers()
  }

  // Off the home network, the NAS rebooting, Wi-Fi not up yet after login: all
  // the same shape, and all recoverable on their own. Automatic checks retry
  // quietly for a while, then settle into a slow background retry with a
  // neutral banner instead of an error.
  function handleUnreachable() {
    if (!root.lastCheckManual && root.silentRetries < root.maxSilentRetries) {
      root.silentRetries++
      silentRetryTimer.restart()
      return
    }
    root.offline = true
    if (!root.lastCheckManual) offlineRetryTimer.restart()
  }

  // ------------------------------------------------------- container check
  //
  // Walked one candidate at a time: inspect the image the container actually
  // runs to learn its digests, ask the registry for the tag's current digest,
  // compare. Both answers are cached, because a dozen containers usually share
  // a handful of images and every registry call costs rate-limit budget.

  property var _endpointIds: []
  property int _endpointIndex: 0
  property var _candidates: []
  property int _candidateIndex: 0
  property var _localDigests: ({})
  property var _remoteDigests: ({})
  property var _foundContainers: []
  property var _containerErrors: []

  function checkContainers() {
    if (!root.portainerConfigured || root.checkingContainers || root.installing) return
    root.checkingContainers = true
    root.containerError = ""
    root._endpointIds = []
    root._endpointIndex = 0
    root._candidates = []
    root._candidateIndex = 0
    root._localDigests = {}
    root._remoteDigests = {}
    root._foundContainers = []
    root._containerErrors = []
    root._portainerTries = 0
    endpointsProc.command = portainerCommand("GET", "/api/endpoints?limit=100", null, 30, Model.RESPONSE_LIMITS.endpoints)
    endpointsProc.running = true
  }

  property int _portainerTries: 0

  // A Portainer that is briefly unhappy — a proxy hiccup, a restart, a token
  // check that raced a cold start — used to leave a red line in the popup
  // until the six-hourly timer came round again. The apps side has always had
  // its own quiet retries; this gives the container side the same courtesy,
  // bounded so a genuinely rejected token settles down instead of hammering.
  readonly property int maxContainerRetries: 5
  property int containerRetries: 0

  function handleEndpoints(result) {
    if (!result.ok) {
      if (result.unreachable && root._portainerTries + 1 < root.portainerCandidates.length) {
        root._portainerTries++
        root.portainerIndex = (root.portainerIndex + 1) % root.portainerCandidates.length
        Qt.callLater(function() {
          endpointsProc.command = root.portainerCommand("GET", "/api/endpoints?limit=100", null, 30, Model.RESPONSE_LIMITS.endpoints)
          endpointsProc.running = true
        })
        return
      }
      root.checkingContainers = false
      root.containersOffline = result.unreachable === true
      root.containerError = result.unreachable ? "" : result.error
      if (root.containerRetries < root.maxContainerRetries) {
        root.containerRetries++
        containerRetryTimer.restart()
      }
      return
    }
    root.containersOffline = false
    root.containerRetries = 0
    root._endpointIds = Model.dockerEndpointIds(result.data)
    root._endpointIndex = 0
    nextEndpoint()
  }

  function nextEndpoint() {
    if (root._endpointIndex >= root._endpointIds.length) {
      root._candidateIndex = 0
      containerStep()
      return
    }
    var id = root._endpointIds[root._endpointIndex]
    containersProc.endpointId = id
    containersProc.command = portainerCommand(
      "GET", "/api/endpoints/" + id + "/docker/containers/json", null, 30, Model.RESPONSE_LIMITS.containers)
    containersProc.running = true
  }

  function handleContainerList(result, endpointId) {
    if (!result.ok) pushContainerError(result.error)
    else root._candidates = root._candidates.concat(Model.watchableContainers(result.data, endpointId))
    root._endpointIndex++
    nextEndpoint()
  }

  // One step of the walk. Every asynchronous branch fills a cache and calls
  // back in here, so the whole traversal is this one function plus its two
  // lookups.
  function containerStep() {
    if (!root.checkingContainers) return
    if (root._candidateIndex >= root._candidates.length) {
      finishContainers()
      return
    }
    var c = root._candidates[root._candidateIndex]

    var localKey = c.endpointId + "/" + c.imageId
    if (root._localDigests[localKey] === undefined) {
      inspectProc.localKey = localKey
      inspectProc.command = portainerCommand(
        "GET", "/api/endpoints/" + c.endpointId + "/docker/images/" + c.imageId + "/json", null, 30,
        Model.RESPONSE_LIMITS.imageInspect)
      inspectProc.running = true
      return
    }
    var local = root._localDigests[localKey]
    // Built on the box: there is no registry counterpart to compare against.
    if (local.length === 0) {
      advanceCandidate()
      return
    }

    if (root._remoteDigests[c.image] === undefined) {
      lookupDigest(c.image)
      return
    }
    var remote = root._remoteDigests[c.image]
    if (remote.error !== "") {
      pushContainerError(c.name + " (" + c.image + "): " + remote.error)
    } else if (Model.imageIsStale(local, remote.digest)) {
      root._foundContainers = root._foundContainers.concat([Model.containerItem(c)])
    }
    advanceCandidate()
  }

  function advanceCandidate() {
    root._candidateIndex++
    containerStep()
  }

  function cacheLocalDigests(key, digests) {
    var next = root._localDigests
    next[key] = digests
    root._localDigests = next
  }

  function cacheRemoteDigest(image, digest, error) {
    var next = root._remoteDigests
    next[image] = { digest: digest, error: error }
    root._remoteDigests = next
  }

  // --- registry digest, with the anonymous Bearer dance ---

  property string _digestImage: ""
  property var _digestRef: ({ registry: "", repo: "", tag: "" })
  property bool _digestRetried: false

  function lookupDigest(image) {
    root._digestImage = image
    root._digestRef = Model.parseImageRef(image)
    root._digestRetried = false
    digestProc.token = ""
    digestProc.command = registryHeadCommand(Model.manifestUrl(root._digestRef))
    digestProc.running = true
  }

  function handleDigest(result) {
    if (result.state === "ok") {
      cacheRemoteDigest(root._digestImage, result.digest, "")
      containerStep()
      return
    }
    if (result.state === "auth" && !root._digestRetried) {
      var url = Model.tokenUrl(result.challenge, root._digestRef.repo)
      if (url === "") {
        cacheRemoteDigest(root._digestImage, "", "registry auth: no realm in challenge")
        containerStep()
        return
      }
      tokenProc.command = registryGetCommand(url)
      tokenProc.running = true
      return
    }
    cacheRemoteDigest(root._digestImage, "",
                      result.error !== "" ? result.error : "registry: authentication required")
    containerStep()
  }

  function handleRegistryToken(result) {
    var token = result.ok ? Model.tokenFrom(result.data) : ""
    if (token === "") {
      cacheRemoteDigest(root._digestImage, "",
                        result.ok ? "registry auth: no token in response" : result.error)
      containerStep()
      return
    }
    root._digestRetried = true
    digestProc.token = token
    digestProc.command = registryHeadCommand(Model.manifestUrl(root._digestRef))
    digestProc.running = true
  }

  function pushContainerError(message) {
    root._containerErrors = root._containerErrors.concat([String(message)])
  }

  function finishContainers() {
    root.checkingContainers = false
    root.containerPart = {
      containers: root._foundContainers.slice(),
      totalContainers: root._candidates.length
    }
    // A handful of unreadable containers should read as a note, not as a wall.
    var errors = root._containerErrors
    root.containerError = errors.length === 0
      ? ""
      : (errors.length <= 3
         ? errors.join("\n")
         : errors.slice(0, 3).join("\n") + "\n… and " + (errors.length - 3) + " more")
    root._candidates = []
    root._foundContainers = []
    root._containerErrors = []
    root._localDigests = {}
    root._remoteDigests = {}
  }

  // ---------------------------------------------------------------- install

  property var _queue: []
  property int _queueIndex: 0
  property var _queueErrors: []
  property real _itemProgress: 0
  property double _itemDeadline: 0

  // The id of the middleware job being watched, and what it is for: a catalog
  // sync during a manual check, or one item of the install queue. The two
  // never overlap — check() refuses while installing, installAll() refuses
  // while checking — so one poller serves both.
  property int _jobId: -1
  property string _jobPurpose: ""
  property int _jobMissing: 0
  property double _jobDeadline: 0

  // How long one item may take end to end. An app upgrade pulls container
  // images over whatever the house internet is, so this has to be generous.
  readonly property int itemTimeoutMs: 30 * 60 * 1000
  readonly property int syncTimeoutMs: 5 * 60 * 1000

  function installAll() {
    if (root.installing || root.checking || root.checkingContainers) return
    if (root.offline || !root.configured) return
    var queue = Model.pendingOrder(root.report)
    if (queue.length === 0) return
    root._queue = queue
    root._queueIndex = 0
    root._queueErrors = []
    root.installing = true
    root.installProgress = 0
    root.actionError = ""
    startQueueItem()
  }

  function currentItem() {
    if (root._queueIndex < 0 || root._queueIndex >= root._queue.length) return null
    return root._queue[root._queueIndex]
  }

  function startQueueItem() {
    if (root._queueIndex >= root._queue.length) {
      finishInstall()
      return
    }
    var item = root._queue[root._queueIndex]
    root.installingTitle = String(item.title || "")
    root._itemProgress = 0
    root._itemDeadline = Date.now() + root.itemTimeoutMs
    publishProgress()
    if (item.kind === "container") startContainerPull(item)
    else startAppJob(item)
  }

  // --- TrueNAS apps: start a job, then watch it ---

  function startAppJob(item) {
    var path = item.kind === "app" ? "/api/v2.0/app/upgrade" : "/api/v2.0/app/pull_images"
    // `app_version` defaults to "latest" server-side; spelled out for clarity.
    var body = item.kind === "app"
      ? JSON.stringify({ app_name: item.name, options: { app_version: "latest" } })
      : JSON.stringify({ app_name: item.name })
    startJobProc.command = curlCommand("POST", path, body, 60, Model.RESPONSE_LIMITS.small)
    startJobProc.running = true
  }

  function handleJobStart(result) {
    if (!result.ok) {
      failCurrentItem(result.error)
      return
    }
    var id = Model.jobIdFrom(result.data)
    if (id < 0) {
      failCurrentItem("unexpected job response")
      return
    }
    watchJob(id, "install", root.itemTimeoutMs)
  }

  function watchJob(id, purpose, timeoutMs) {
    root._jobId = id
    root._jobPurpose = purpose
    root._jobMissing = 0
    root._jobDeadline = Date.now() + timeoutMs
    jobTimer.start()
    pollJob()
  }

  function stopWatchingJob() {
    jobTimer.stop()
    root._jobId = -1
    root._jobPurpose = ""
  }

  function pollJob() {
    if (root._jobId < 0 || jobProc.running) return
    if (Date.now() >= root._jobDeadline) {
      var purpose = root._jobPurpose
      stopWatchingJob()
      if (purpose === "sync") runAppsQuery()
      else failCurrentItem("timed out waiting for the job to finish")
      return
    }
    jobProc.command = curlCommand("GET", "/api/v2.0/core/get_jobs?id=" + root._jobId, null, 30, Model.RESPONSE_LIMITS.small)
    jobProc.running = true
  }

  function handleJobPoll(result) {
    if (root._jobId < 0) return
    // A proxy 504 or a dropped connection says nothing about the job, which is
    // very likely still running on the NAS. Keep polling; the deadline is the
    // only honest limit.
    if (!result.ok) {
      if (result.unreachable) return
      finishJob(false, result.error)
      return
    }
    var outcome = Model.jobOutcome(result.data)
    if (outcome.state === "running") {
      root._jobMissing = 0
      if (outcome.percent >= 0 && root._jobPurpose === "install") {
        root._itemProgress = outcome.percent
        publishProgress()
      }
      return
    }
    if (outcome.state === "missing") {
      // A job can take a moment to appear in the queue right after it is
      // created; only a persistent absence is a failure.
      root._jobMissing++
      if (root._jobMissing < 3) return
      finishJob(false, "job " + root._jobId + " not found")
      return
    }
    finishJob(outcome.state === "done", outcome.error)
  }

  function finishJob(ok, error) {
    var purpose = root._jobPurpose
    stopWatchingJob()
    if (purpose === "sync") {
      // A sync failure must not hide the updates the NAS can still report from
      // what it already knows, so it degrades to a note beside the list.
      if (!ok) root.lastError = "Catalog refresh failed: " + error
      runAppsQuery()
      return
    }
    if (purpose !== "install" || !root.installing) return
    if (ok) advanceQueue()
    else failCurrentItem(error)
  }

  // --- unmanaged containers: pull with progress, then recreate ---

  property var _pullLayers: ({})
  property string _pullLastLine: ""

  // Built by hand rather than through portainerCommand: this one streams, so
  // it needs `-N` (no output buffering) and a newline *after* the status code
  // so the line splitter emits that last line too.
  function pullCommand(item) {
    var split = Model.splitNameTag(item.image)
    var limit = Model.RESPONSE_LIMITS.pullStream
    var args = ["curl", "-sS", "-N", "--connect-timeout", "10", "--max-time", String(30 * 60),
                "--max-filesize", String(limit),
                "-w", "\n%{http_code} %{exitcode}\n", "-K", root.portainerAuthPath]
    if (root.acceptInvalidCerts) args.push("--insecure")
    args.push("-X", "POST")
    args.push(root.portainerBase + "/api/endpoints/" + item.endpointId + "/docker/images/create"
              + "?fromImage=" + encodeURIComponent(split.name)
              + "&tag=" + encodeURIComponent(split.tag))
    // This is the one reply that is a stream by design, and the longest-lived:
    // an endless one would otherwise be read a line at a time, forever.
    return capped(args, limit)
  }

  function startContainerPull(item) {
    root._pullLayers = {}
    root._pullLastLine = ""
    pullProc.command = pullCommand(item)
    pullProc.running = true
  }

  function handlePullLine(line) {
    if (!root.installing) return
    // The trailer is newline-terminated so the splitter emits it, which can
    // leave an empty segment after it; keep the last line that had content.
    if (String(line).replace(/^\s+|\s+$/g, "") !== "") root._pullLastLine = String(line)
    var result = Model.applyPullLine(root._pullLayers, line)
    if (!result.changed) return
    // The pull is nearly all the wall time; leave the last tenth for the
    // recreate that follows it.
    root._itemProgress = result.progress * 0.9
    publishProgress()
  }

  function handlePullExit() {
    if (!root.installing) return
    var item = currentItem()
    if (!item) return
    // The stream's own last line is the trailer, so the verdict comes from
    // there rather than from the pipeline's exit status. No trailer means the
    // ceiling cut it off — treat that as a pull that did not happen.
    var trailer = Model.parseTrailer(root._pullLastLine)
    var pulled = !!trailer && trailer.exitCode === 0
      && trailer.code >= 200 && trailer.code < 300
    root._itemProgress = 0.9
    publishProgress()
    // If the streamed pull isn't possible (an older daemon, a registry that
    // wants credentials…), fall back to letting the recreate pull for us — no
    // progress bar, but it works.
    recreateContainer(item, !pulled)
  }

  function recreateContainer(item, pull) {
    recreateProc.command = portainerCommand(
      "POST",
      "/api/docker/" + item.endpointId + "/containers/" + item.containerId + "/recreate",
      JSON.stringify({ PullImage: pull === true }),
      15 * 60, Model.RESPONSE_LIMITS.recreate)
    recreateProc.running = true
  }

  function handleRecreate(result) {
    if (!root.installing) return
    if (result.ok) advanceQueue()
    else failCurrentItem(result.error)
  }

  // --- queue bookkeeping ---

  function failCurrentItem(message) {
    var item = currentItem()
    var errors = root._queueErrors.slice()
    errors.push((item ? item.title + ": " : "") + message)
    root._queueErrors = errors
    advanceQueue()
  }

  function advanceQueue() {
    stopWatchingJob()
    root._queueIndex++
    root._itemProgress = 0
    publishProgress()
    startQueueItem()
  }

  function publishProgress() {
    var n = Math.max(1, root._queue.length)
    root.installProgress = Math.max(0, Math.min(1, (root._queueIndex + root._itemProgress) / n))
  }

  function finishInstall() {
    stopWatchingJob()
    root.installing = false
    root.installProgress = -1
    root.installingTitle = ""
    root.actionError = root._queueErrors.join("\n")
    root._queue = []
    root._queueIndex = 0
    root._queueErrors = []
    // Re-query so the counts and the badge drop immediately.
    root.lastCheckManual = false
    check(false)
    checkContainers()
  }

  // ------------------------------------------------------------------- misc

  function openWebUi() {
    if (root.webUiUrl === "") return
    Quickshell.execDetached(["omarchy-launch-browser", root.webUiUrl])
  }

  // ------------------------------------------------------------- processes

  Process {
    id: syncProc
    running: false
    stdout: StdioCollector { id: syncOut; waitForEnd: true }
    onExited: function(exitCode) {
      var result = Model.interpretResponse("catalog.sync", exitCode, syncOut.text, Model.RESPONSE_LIMITS.small)
      if (!result.ok) {
        if (!result.unreachable) root.lastError = "Catalog refresh failed: " + result.error
        root.runAppsQuery()
        return
      }
      var id = Model.jobIdFrom(result.data)
      if (id < 0) root.runAppsQuery()
      else root.watchJob(id, "sync", root.syncTimeoutMs)
    }
  }

  Process {
    id: appsProc
    running: false
    stdout: StdioCollector { id: appsOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.handleApps(Model.interpretResponse("/api/v2.0/app", exitCode, appsOut.text, Model.RESPONSE_LIMITS.apps))
    }
  }

  Process {
    id: startJobProc
    running: false
    stdout: StdioCollector { id: startJobOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (!root.installing) return
      root.handleJobStart(
        Model.interpretResponse("app.upgrade", exitCode, startJobOut.text, Model.RESPONSE_LIMITS.small))
    }
  }

  Process {
    id: jobProc
    running: false
    stdout: StdioCollector { id: jobOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.handleJobPoll(
        Model.interpretResponse("core.get_jobs", exitCode, jobOut.text, Model.RESPONSE_LIMITS.small))
    }
  }

  Process {
    id: endpointsProc
    running: false
    stdout: StdioCollector { id: endpointsOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.handleEndpoints(Model.interpretResponse(
        "/api/endpoints", exitCode, endpointsOut.text, Model.RESPONSE_LIMITS.endpoints, "Portainer"))
    }
  }

  Process {
    id: containersProc
    property int endpointId: 0
    running: false
    stdout: StdioCollector { id: containersOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.handleContainerList(Model.interpretResponse(
        "containers", exitCode, containersOut.text, Model.RESPONSE_LIMITS.containers, "Portainer"),
        containersProc.endpointId)
    }
  }

  Process {
    id: inspectProc
    property string localKey: ""
    running: false
    stdout: StdioCollector { id: inspectOut; waitForEnd: true }
    onExited: function(exitCode) {
      var result = Model.interpretResponse(
        "image inspect", exitCode, inspectOut.text, Model.RESPONSE_LIMITS.imageInspect, "Portainer")
      if (!result.ok) {
        root.pushContainerError(result.error)
        // An image we cannot inspect is one we cannot judge: cache the empty
        // answer so the walk moves on instead of asking again.
        root.cacheLocalDigests(inspectProc.localKey, [])
      } else {
        root.cacheLocalDigests(inspectProc.localKey, Model.repoDigests(result.data))
      }
      root.containerStep()
    }
  }

  // The registry manifest HEAD. `-K -` is fed either nothing or one
  // Authorization line, so the token never lands in argv.
  Process {
    id: digestProc
    property string token: ""
    running: false
    stdinEnabled: true
    stdout: StdioCollector { id: digestOut; waitForEnd: true }
    onStarted: {
      write(digestProc.token === ""
            ? "\n"
            : Model.curlHeaderConfig("Authorization", "Bearer " + digestProc.token))
      digestProc.stdinEnabled = false
    }
    onExited: function(exitCode) {
      digestProc.stdinEnabled = true
      root.handleDigest(Model.interpretDigestResponse(exitCode, digestOut.text, Model.RESPONSE_LIMITS.registryHeaders))
    }
  }

  Process {
    id: tokenProc
    running: false
    stdout: StdioCollector { id: tokenOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.handleRegistryToken(Model.interpretResponse(
        "registry auth", exitCode, tokenOut.text, Model.RESPONSE_LIMITS.registryToken, "the registry"))
    }
  }

  // The pull streams newline-delimited JSON progress events; SplitParser hands
  // them over a line at a time as they arrive, which is the whole point of
  // pulling separately from the recreate.
  Process {
    id: pullProc
    running: false
    stdout: SplitParser { onRead: function(line) { root.handlePullLine(line) } }
    onExited: function() { root.handlePullExit() }
  }

  Process {
    id: recreateProc
    running: false
    stdout: StdioCollector { id: recreateOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.handleRecreate(Model.interpretResponse(
        "recreate", exitCode, recreateOut.text, Model.RESPONSE_LIMITS.recreate, "Portainer"))
    }
  }

  // mkdir -p -m 700 keeps the keys unreadable to other users even in the
  // moment between an atomic write and the chmod that follows it.
  Process {
    id: ensureDirProc
    running: false
    command: ["mkdir", "-p", "-m", "700", root.configDir]
    onExited: function() {
      hardenProc.running = true
      configFile.reload()
    }
  }

  Process {
    id: hardenProc
    running: false
    command: ["bash", "-c",
              "chmod 700 \"$1\" 2>/dev/null; chmod 600 \"$1\"/config.json \"$1\"/auth.conf \"$1\"/portainer-auth.conf 2>/dev/null; true",
              "--", root.configDir]
  }

  // ---------------------------------------------------------------- files

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: if (!root.configLoaded) root.applyConfig(text())
    // First run: no file yet. Without this the plugin would sit unconfigured
    // and never open its settings view.
    onLoadFailed: if (!root.configLoaded) root.applyConfig("")
  }

  FileView {
    id: authFile
    path: root.authPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
  }

  FileView {
    id: portainerAuthFile
    path: root.portainerAuthPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
  }

  // ---------------------------------------------------------------- timers

  Timer {
    id: jobTimer
    interval: 2000
    repeat: true
    running: false
    onTriggered: root.pollJob()
  }

  Timer {
    id: silentRetryTimer
    interval: 20000
    repeat: false
    onTriggered: root.check(false)
  }

  Timer {
    id: offlineRetryTimer
    interval: 120000
    repeat: false
    onTriggered: root.check(false)
  }

  Timer {
    id: periodicTimer
    interval: root.refreshIntervalMin * 60000
    repeat: true
    running: root.configured
    onTriggered: {
      if (root.installing) return
      root.lastCheckManual = false
      root.check(false)
    }
  }

  Timer {
    id: containerRetryTimer
    interval: 120000
    repeat: false
    onTriggered: root.checkContainers()
  }

  Timer {
    id: containerTimer
    interval: root.containerIntervalHours * 3600000
    repeat: true
    running: root.portainerConfigured
    onTriggered: root.checkContainers()
  }

  Component.onCompleted: ensureDirProc.running = true
}

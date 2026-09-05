#!/usr/bin/env python3
"""A stand-in for a TrueNAS SCALE box and a Portainer next to it.

Lets the plugin be developed and exercised end to end without a NAS. Serves
both path spaces on one port (they do not collide):

  TrueNAS   /api/v2.0/...      Authorization: Bearer <TRUENAS_KEY>
  Portainer /api/endpoints/... X-API-Key: <PORTAINER_KEY>

Jobs behave like the real middleware: the call returns a bare integer id and
core/get_jobs walks it through RUNNING with a rising percent, then SUCCESS.

The container images below are real references with deliberately wrong local
digests, so the registry half of the check runs against the actual registries
— that is the only way to exercise the anonymous Bearer-token dance.

    python3 test/mock-server.py

Environment switches:
  PORT=8899        which port to listen on
  GATEWAY_504=1    answer core/get_jobs with a 504 HTML page for the first few
                   seconds of each job, the way a reverse proxy does. The
                   plugin must keep polling rather than call the job failed.
  FAIL_APP=name    make that app's job end FAILED.
"""
import json
import os
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

TRUENAS_KEY = os.environ.get("TRUENAS_KEY", "mock-truenas-key")
PORTAINER_KEY = os.environ.get("PORTAINER_KEY", "mock-portainer-key")
PORT = int(os.environ.get("PORT", "8899"))
GATEWAY_504 = os.environ.get("GATEWAY_504") == "1"
FAIL_APP = os.environ.get("FAIL_APP", "")

APPS = [
    {"name": "immich", "upgrade_available": True, "image_updates_available": False,
     "human_version": "1.99.0", "latest_version": "1.100.0",
     "metadata": {"title": "Immich"}},
    {"name": "audiobookshelf", "upgrade_available": True, "image_updates_available": True,
     "human_version": "2.7.0", "latest_version": "2.8.0",
     "metadata": {"title": "Audiobookshelf"}},
    {"name": "syncthing", "upgrade_available": False, "image_updates_available": True,
     "human_version": "1.27.2", "latest_version": "1.27.2",
     "metadata": {"title": "Syncthing"}},
    {"name": "plex", "upgrade_available": False, "image_updates_available": False,
     "human_version": "1.40.0", "latest_version": "1.40.0",
     "metadata": {"title": "Plex"}},
    {"name": "vaultwarden", "upgrade_available": False, "image_updates_available": False,
     "human_version": "1.30.1", "latest_version": "1.30.1",
     "metadata": {"title": "Vaultwarden"}},
]

CONTAINERS = [
    {"Id": "c1" + "0" * 62, "Names": ["/dockge"], "Image": "louislam/dockge:1",
     "ImageID": "sha256:aaa", "Labels": {"com.docker.compose.project": "dockge"}},
    {"Id": "c2" + "0" * 62, "Names": ["/caddy"], "Image": "caddy:2",
     "ImageID": "sha256:bbb", "Labels": {}},
    # TrueNAS's own — must be skipped, the apps check already covers it.
    {"Id": "c3" + "0" * 62, "Names": ["/ix-immich-server"],
     "Image": "ghcr.io/immich-app/immich-server:v1.99.0", "ImageID": "sha256:ccc",
     "Labels": {"com.docker.compose.project": "ix-immich"}},
    # Pinned by digest — cannot drift, must be skipped.
    {"Id": "c4" + "0" * 62, "Names": ["/pinned"], "Image": "nginx@sha256:deadbeef",
     "ImageID": "sha256:ddd", "Labels": {}},
    # Built on the box: no RepoDigests, so there is nothing to compare.
    {"Id": "c5" + "0" * 62, "Names": ["/homebrew"], "Image": "my-own-thing:latest",
     "ImageID": "sha256:eee", "Labels": {}},
]

IMAGES = {
    "sha256:aaa": {"RepoDigests": ["louislam/dockge@sha256:" + "1" * 64]},
    "sha256:bbb": {"RepoDigests": ["caddy@sha256:" + "2" * 64]},
    "sha256:eee": {"RepoDigests": []},
}

jobs = {}
jobs_lock = threading.Lock()
next_job_id = [4700]


def start_job(label, seconds=6.0, fail=False):
    with jobs_lock:
        next_job_id[0] += 1
        jid = next_job_id[0]
        jobs[jid] = {"state": "WAITING", "progress": {"percent": None},
                     "error": None, "label": label, "born": time.time()}

    def run():
        time.sleep(0.4)
        steps = 10
        for i in range(steps + 1):
            with jobs_lock:
                jobs[jid]["state"] = "RUNNING"
                jobs[jid]["progress"] = {"percent": i * 100.0 / steps}
            time.sleep(seconds / steps)
        with jobs_lock:
            if fail:
                jobs[jid]["state"] = "FAILED"
                jobs[jid]["error"] = "[EFAULT] pull access denied\nTraceback: ..."
            else:
                jobs[jid]["state"] = "SUCCESS"
                jobs[jid]["progress"] = {"percent": 100.0}

    threading.Thread(target=run, daemon=True).start()
    return jid


PULL_EVENTS = [
    {"id": "l1", "status": "Pulling fs layer"},
    {"id": "l2", "status": "Pulling fs layer"},
    {"id": "l3", "status": "Waiting"},
    {"id": "l1", "status": "Downloading", "progressDetail": {"current": 30, "total": 100}},
    {"id": "l2", "status": "Downloading", "progressDetail": {"current": 60, "total": 100}},
    {"id": "l1", "status": "Downloading", "progressDetail": {"current": 100, "total": 100}},
    {"id": "l1", "status": "Download complete"},
    {"id": "l2", "status": "Download complete"},
    {"id": "l3", "status": "Already exists"},
    {"id": "l1", "status": "Extracting", "progressDetail": {"current": 50, "total": 100}},
    {"id": "l1", "status": "Pull complete"},
    {"id": "l2", "status": "Extracting", "progressDetail": {"current": 100, "total": 100}},
    {"id": "l2", "status": "Pull complete"},
    {"status": "Status: Downloaded newer image"},
]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        print("%s %s" % (time.strftime("%H:%M:%S"), fmt % args), flush=True)

    # ---------------------------------------------------------------- helpers

    def send_json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_text(self, text, code=200):
        body = text.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def truenas_authed(self):
        if self.headers.get("Authorization") == "Bearer " + TRUENAS_KEY:
            return True
        self.send_json({"message": "Not authenticated"}, 401)
        return False

    def portainer_authed(self):
        if self.headers.get("X-API-Key") == PORTAINER_KEY:
            return True
        self.send_json({"message": "Invalid API key"}, 403)
        return False

    def read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            return json.loads(raw or b"{}")
        except ValueError:
            return {}

    # --------------------------------------------------------------- routing

    def do_GET(self):
        url = urlparse(self.path)
        path, query = url.path, parse_qs(url.query)

        if path.startswith("/api/v2.0/"):
            if not self.truenas_authed():
                return
            if path == "/api/v2.0/app":
                return self.send_json(APPS)
            if path == "/api/v2.0/catalog/sync":
                return self.send_json(start_job("catalog.sync", seconds=1.5))
            if path == "/api/v2.0/core/get_jobs":
                jid = int((query.get("id") or ["0"])[0])
                with jobs_lock:
                    job = jobs.get(jid)
                if job is None:
                    return self.send_json([])
                # A proxy in front of the NAS times the poll out while the job
                # is still perfectly alive underneath it.
                if GATEWAY_504 and 1.0 < time.time() - job["born"] < 6.0:
                    return self.send_text(
                        "<html><head><title>504 Gateway Time-out</title></head>"
                        "<body><center><h1>504 Gateway Time-out</h1></center></body></html>",
                        504)
                return self.send_json([{k: job[k] for k in ("state", "progress", "error")}])
            return self.send_json({"message": "not found"}, 404)

        if path.startswith("/api/"):
            if not self.portainer_authed():
                return
            if path == "/api/endpoints":
                return self.send_json([{"Id": 1, "Type": 1, "Name": "local"},
                                       {"Id": 7, "Type": 3, "Name": "some-kubernetes"}])
            if re.match(r"^/api/endpoints/(\d+)/docker/containers/json$", path):
                return self.send_json(CONTAINERS)
            m = re.match(r"^/api/endpoints/(\d+)/docker/images/([^/]+)/json$", path)
            if m:
                image = IMAGES.get(m.group(2))
                if image is None:
                    return self.send_json({"message": "no such image"}, 404)
                return self.send_json(image)
        return self.send_json({"message": "not found"}, 404)

    def do_POST(self):
        url = urlparse(self.path)
        path, query = url.path, parse_qs(url.query)

        if path.startswith("/api/v2.0/"):
            if not self.truenas_authed():
                return
            name = self.read_body().get("app_name", "")
            if path == "/api/v2.0/app/upgrade":
                return self.send_json(start_job("upgrade:" + name, 6.0, fail=(name == FAIL_APP)))
            if path == "/api/v2.0/app/pull_images":
                return self.send_json(
                    start_job("pull_images:" + name, 4.0, fail=(name == FAIL_APP)))
            return self.send_json({"message": "not found"}, 404)

        if path.startswith("/api/"):
            if not self.portainer_authed():
                return
            if re.match(r"^/api/endpoints/(\d+)/docker/images/create$", path):
                return self.stream_pull()
            m = re.match(r"^/api/docker/(\d+)/containers/([^/]+)/recreate$", path)
            if m:
                self.read_body()
                time.sleep(1.0)
                return self.send_json({"Id": m.group(2), "State": {"Running": True}})
        return self.send_json({"message": "not found"}, 404)

    def stream_pull(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        for event in PULL_EVENTS:
            chunk = (json.dumps(event) + "\r\n").encode()
            self.wfile.write(b"%x\r\n" % len(chunk) + chunk + b"\r\n")
            self.wfile.flush()
            time.sleep(0.35)
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()


if __name__ == "__main__":
    print("TrueNAS + Portainer mock on http://127.0.0.1:%d "
          "(504 mode: %s, failing app: %r)" % (PORT, GATEWAY_504, FAIL_APP), flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()

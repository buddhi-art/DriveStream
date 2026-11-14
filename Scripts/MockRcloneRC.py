#!/usr/bin/env python3
"""Authenticated loopback-only RC mock; never reads user rclone config.

Both RC listeners bind port 0 and keep their sockets until shutdown. Test-only
controls inject real HTTP/transport failures, delays and redirects, and expose
request counts so tests can prove that the production client does not retry.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any


def basic(username: str, password: str) -> str:
    return "Basic " + base64.b64encode(f"{username}:{password}".encode()).decode("ascii")


class MockServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, name: str, authorization: str, marker: int) -> None:
        super().__init__(("127.0.0.1", 0), Handler)
        self.name = name
        self.authorization = authorization
        self.marker = marker
        self.state_lock = threading.Lock()
        self.counts: dict[str, int] = {}
        self.unauthorized = 0
        self.behaviors: dict[str, list[dict[str, Any]]] = {}
        self.last_bodies: dict[str, Any] = {}
        self.redirect_hits = 0
        self.redirect_authorizations: list[str] = []

    @property
    def address(self) -> str:
        return f"http://127.0.0.1:{self.server_address[1]}"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "MockRcloneRC/2.0"
    server: MockServer

    def log_message(self, fmt: str, *args: Any) -> None:
        # Stress tests are intentionally quiet; unexpected failures still log.
        pass

    def _raw_reply(self, encoded: bytes, status: int = 200, location: str | None = None) -> None:
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        if location is not None:
            self.send_header("Location", location)
        self.end_headers()
        self.wfile.write(encoded)

    def _reply(self, payload: Any, status: int = 200) -> None:
        self._raw_reply(json.dumps(payload).encode("utf-8"), status)

    def _record_redirect_sink(self) -> bool:
        if self.path != "/_test/redirect-sink":
            return False
        with self.server.state_lock:
            self.server.redirect_hits += 1
            authorization = self.headers.get("Authorization")
            if authorization:
                self.server.redirect_authorizations.append(authorization)
        self._reply({})
        return True

    def do_GET(self) -> None:  # noqa: N802
        if self._record_redirect_sink():
            return
        if self.path != "/_test/state":
            self._reply({"error": "unknown test endpoint"}, 404)
            return
        with self.server.state_lock:
            payload = {
                "counts": dict(self.server.counts),
                "unauthorized": self.server.unauthorized,
                "lastBodies": dict(self.server.last_bodies),
                "redirectHits": self.server.redirect_hits,
                "redirectAuthorizations": list(self.server.redirect_authorizations),
            }
        self._reply(payload)

    def do_POST(self) -> None:  # noqa: N802
        try:
            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(length) if length else b"{}"
            if self._record_redirect_sink():
                return
            if self.headers.get("Authorization") != self.server.authorization:
                with self.server.state_lock:
                    self.server.unauthorized += 1
                self._reply({"error": "unauthorized"}, 401)
                return
            try:
                body = json.loads(raw or b"{}")
            except json.JSONDecodeError:
                self._reply({"error": "invalid JSON"}, 400)
                return
            if not isinstance(body, dict):
                self._reply({"error": "expected JSON object"}, 400)
                return
            if self.path == "/_test/control":
                endpoint = body["endpoint"]
                behaviors = body["behaviors"]
                with self.server.state_lock:
                    self.server.behaviors[endpoint] = behaviors
                self._reply({})
                return

            with self.server.state_lock:
                self.server.counts[self.path] = self.server.counts.get(self.path, 0) + 1
                self.server.last_bodies[self.path] = body
                queue = self.server.behaviors.get(self.path, [])
                behavior = queue.pop(0) if queue else {}
            if behavior.get("delay"):
                time.sleep(behavior["delay"])
            if behavior.get("close"):
                self.close_connection = True
                self.connection.shutdown(socket.SHUT_RDWR)
                self.connection.close()
                return
            if "redirect" in behavior:
                self._raw_reply(b"{}", behavior.get("status", 307), behavior["redirect"])
                return
            if "raw" in behavior:
                self._raw_reply(behavior["raw"].encode("utf-8"), behavior.get("status", 200))
                return
            if "status" in behavior:
                self._reply({"error": "injected RC failure"}, behavior["status"])
                return

            if self.path == "/rc/noop":
                if body != {}:
                    self._reply({"error": "invalid noop body"}, 400)
                    return
                self._reply({})
                return
            if self.path == "/core/pid":
                self._reply({"pid": os.getpid()})
                return
            if self.path == "/options/get":
                self._reply({"vfs": {"CacheMode": 3, "ReadAhead": 268435456}})
                return
            if self.path == "/vfs/refresh":
                if set(body) != {"recursive", "_async"} or body["recursive"] != "true" or body["_async"] is not True:
                    self._reply({"error": "invalid vfs/refresh body", "seen": body}, 400)
                    return
                self._reply({"jobid": 41, "executeId": "mock-execute-id"})
                return
            if self.path == "/job/status":
                if body != {"jobid": 41}:
                    self._reply({"error": "invalid job id", "seen": body}, 400)
                    return
                self._reply({"id": 41, "finished": True, "success": True, "error": "", "duration": 1.25})
                return
            if self.path == "/operations/about":
                if body != {"fs": "gdrive:"}:
                    self._reply({"error": "invalid about fs", "seen": body}, 400)
                    return
                self._reply({"total": 5_000_000_000_000, "used": 1_200_000_000_000,
                             "free": 3_800_000_000_000, "trashed": 5_000, "objects": 1_200})
                return
            if self.path == "/core/stats":
                if body != {}:
                    self._reply({"error": "invalid core stats body"}, 400)
                    return
                self._reply({"bytes": self.server.marker, "speed": 1_048_576.0, "transfers": 1,
                             "transferring": [{"name": "Video.mov", "size": 1_000_000,
                                               "bytes": 400_000, "percentage": 40, "speed": 1_048_576.0,
                                               "srcFs": "/cache/vfs/gdrive/Video.mov", "dstFs": "gdrive:Video.mov",
                                               "startedAt": "2026-10-25T09:00:00Z"}]})
                return
            if self.path == "/vfs/stats":
                if body != {}:
                    self._reply({"error": "DriveStream must use the single-active-VFS form", "seen": body}, 400)
                    return
                self._reply({"fs": "gdrive:", "inUse": 3,
                             "diskCache": {"bytesUsed": 2048, "files": 2, "uploadsQueued": 1, "uploadsInProgress": 0,
                                            "erroredFiles": 0, "outOfSpace": False, "path": "/tmp/mock-cache"},
                             "metadataCache": {"dirs": 2, "files": 3}})
                return
            if self.path == "/vfs/queue":
                if body != {}:
                    self._reply({"error": "queue must target single VFS"}, 400)
                    return
                self._reply({"queue": [{"id": 1, "name": "Video.mov", "size": 1000000,
                                       "expiry": 2.5, "tries": 1, "delay": 5.0, "uploading": False}]})
                return
            if self.path == "/core/bwlimit":
                self._reply({"rate": body.get("rate", "off")})
                return
            if self.path == "/vfs/forget":
                if set(body) not in (set(), {"file"}, {"dir"}) or any(not isinstance(value, str) for value in body.values()):
                    self._reply({"error": "invalid single-active-VFS forget body", "seen": body}, 400)
                    return
                self._reply({"forgotten": list(body.values())})
                return
            self._reply({"error": f"unknown endpoint {self.path}"}, 404)
        except (BrokenPipeError, ConnectionResetError):
            pass  # Expected when cancellation or a short timeout closes a socket.
        except Exception as error:
            print(f"mock request failed: {error}", file=sys.stderr)
            try:
                self._reply({"error": str(error)}, 500)
            except (BrokenPipeError, ConnectionResetError):
                pass


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--address-file", required=True, help="JSON manifest containing already-bound addresses.")
    parser.add_argument("--ready-file", required=True, help="Created only after the manifest is flushed and closed.")
    args = parser.parse_args()
    primary = MockServer("primary", basic("drivestream", "secret"), 101)
    secondary = MockServer("secondary", basic("second", "new-secret"), 202)
    threading.Thread(target=secondary.serve_forever, daemon=True).start()
    try:
        with open(args.address_file, "w", encoding="utf-8") as address_file:
            json.dump({"primaryURL": primary.address, "secondaryURL": secondary.address, "pid": os.getpid()}, address_file)
            address_file.flush()
            os.fsync(address_file.fileno())
        with open(args.ready_file, "w", encoding="utf-8") as ready_file:
            ready_file.write("ready\n")
        primary.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        secondary.shutdown()
        secondary.server_close()
        primary.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

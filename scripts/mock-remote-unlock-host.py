#!/usr/bin/env python3
"""Loopback-only UI fixture. Never controls a real Mac or records request bodies.

Run this server, then run ControlSurfaceUITests with
TEST_RUNNER_VAMP_UNLOCK_UI_TEST=1. Restart the server before each run: the first
unlock stays locked, and the second confirms an unlock after 1.5 seconds.
"""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import time


state = {"attempts": 0, "unlock_at": None}


def locked():
    return state["unlock_at"] is None or time.monotonic() < state["unlock_at"]


def control():
    return dict(
        enabled=True, screenRecording=True, accessibility=True, ready=not locked(),
        locked=locked(), remoteUnlockEnabled=True, remoteUnlockAvailable=True,
        remoteUnlockMessage="Unlock test Mac", displays=[],
        displayWidth=1024, displayHeight=768,
    )


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send_json(self, value, status=200):
        data = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/api/status":
            return self.send_json(dict(
                protocolVersion=1, appVersion="QA", appBuild="0", capabilities=[],
                pairedClients=1, networkKind="localNetwork", tokenExpiresAt=2100000000,
                isRunning=False, phase="idle", queuedTasks=0, macControl=control(),
            ))
        if path == "/api/control":
            return self.send_json(control())
        if path == "/api/sessions":
            return self.send_json(dict(sessions=[]))
        if path == "/api/control/apps":
            return self.send_json(dict(applications=[]))
        if path == "/qa/status":
            return self.send_json(dict(attempts=state["attempts"], locked=locked()))
        if path == "/api/models":
            return self.send_json(dict(models=[]))
        return self.send_json(dict(error="QA fixture has no video stream"), 503)

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if self.path == "/api/pair":
            return self.send_json(dict(token="unlock-qa-token", expiresAt=2100000000))
        if self.path == "/api/control/unlock":
            state["attempts"] += 1
            if state["attempts"] >= 2:
                state["unlock_at"] = time.monotonic() + 1.5
            return self.send_json(dict(accepted=True), 202)
        return self.send_json(dict(accepted=True))


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 9576), Handler).serve_forever()

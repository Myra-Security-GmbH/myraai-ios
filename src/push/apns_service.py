#!/usr/bin/env python3
"""
MYRA AI APNs microservice.

Listens on 127.0.0.1:8010. Accepts POST /send from Lua/OpenResty and
forwards the notification to Apple's APNs HTTP/2 API using JWT auth (ES256).

Request body (JSON):
    {
        "device_token": "<hex APNs token>",
        "title":        "Notification title",
        "body":         "Notification body text",
        "data":         { ...optional custom payload fields... }
    }

Response: {"ok": true} or {"error": "..."} with appropriate HTTP status.

Configuration (environment variables or /etc/myra-apns.env):
    APNS_KEY_ID     – 10-char key ID (e.g. AJ6X2G9GR8)
    APNS_TEAM_ID    – 10-char team ID (e.g. A4C54HLPJ7)
    APNS_KEY_PATH   – path to .p8 private key file
    APNS_BUNDLE_ID  – app bundle ID (e.g. eu.myra.myraai)
    APNS_PROD       – "1" for production APNs, "0" for sandbox (default: "1")
    LISTEN_PORT     – port to bind (default: 8010)
"""

import json
import logging
import os
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

import httpx
import jwt  # PyJWT

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("apns")

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

def _load_env_file(path: str):
    if not os.path.exists(path):
        return
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip())

_load_env_file("/etc/myra-apns.env")

KEY_ID    = os.environ["APNS_KEY_ID"]
TEAM_ID   = os.environ["APNS_TEAM_ID"]
KEY_PATH  = os.environ["APNS_KEY_PATH"]
BUNDLE_ID = os.environ.get("APNS_BUNDLE_ID", "eu.myra.myraai")
PROD      = os.environ.get("APNS_PROD", "1") == "1"
PORT      = int(os.environ.get("LISTEN_PORT", "8010"))

APNS_HOST = "api.push.apple.com" if PROD else "api.sandbox.push.apple.com"

with open(KEY_PATH) as f:
    PRIVATE_KEY = f.read()

# ---------------------------------------------------------------------------
# JWT token — cached for up to 55 minutes (Apple limit is 60)
# ---------------------------------------------------------------------------

_jwt_cache: dict = {"token": None, "generated_at": 0}

def _apns_jwt() -> str:
    now = int(time.time())
    if _jwt_cache["token"] and now - _jwt_cache["generated_at"] < 55 * 60:
        return _jwt_cache["token"]
    token = jwt.encode(
        {"iss": TEAM_ID, "iat": now},
        PRIVATE_KEY,
        algorithm="ES256",
        headers={"kid": KEY_ID},
    )
    _jwt_cache.update({"token": token, "generated_at": now})
    return token

# ---------------------------------------------------------------------------
# APNs sender — reuse a single HTTP/2 connection
# ---------------------------------------------------------------------------

_client: httpx.Client | None = None

def _get_client() -> httpx.Client:
    global _client
    if _client is None or _client.is_closed:
        _client = httpx.Client(http2=True, timeout=15.0)
    return _client

def send_notification(device_token: str, title: str, body: str,
                      data: dict | None = None) -> tuple[bool, str]:
    url = f"https://{APNS_HOST}/3/device/{device_token}"
    payload: dict = {
        "aps": {
            "alert": {"title": title, "body": body},
            "sound": "default",
        }
    }
    if data:
        payload.update(data)

    headers = {
        "authorization": f"bearer {_apns_jwt()}",
        "apns-push-type": "alert",
        "apns-topic": BUNDLE_ID,
        "apns-priority": "10",
        "content-type": "application/json",
    }

    try:
        resp = _get_client().post(url, content=json.dumps(payload), headers=headers)
    except Exception as exc:
        log.warning("APNs request failed: %s", exc)
        return False, str(exc)

    if resp.status_code == 200:
        return True, ""

    reason = ""
    try:
        reason = resp.json().get("reason", "")
    except Exception:
        reason = resp.text[:120]

    log.warning("APNs rejected token=%s status=%d reason=%s", device_token[:8], resp.status_code, reason)
    return False, f"APNs {resp.status_code}: {reason}"

# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # suppress per-request access log noise

    def _reply(self, status: int, body: dict):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        if self.path != "/send":
            self._reply(404, {"error": "not found"})
            return

        length = int(self.headers.get("Content-Length", 0))
        try:
            req = json.loads(self.rfile.read(length))
        except Exception:
            self._reply(400, {"error": "invalid JSON"})
            return

        token = req.get("device_token", "").strip()
        title = req.get("title", "MYRA AI")
        body  = req.get("body", "")
        data  = req.get("data")

        if not token:
            self._reply(400, {"error": "device_token required"})
            return

        ok, err = send_notification(token, title, body, data)
        if ok:
            self._reply(200, {"ok": True})
        else:
            self._reply(502, {"error": err})

if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", PORT), Handler)
    log.info("MYRA APNs service listening on 127.0.0.1:%d (PROD=%s BUNDLE=%s)", PORT, PROD, BUNDLE_ID)
    server.serve_forever()

#!/usr/bin/env python3
"""
MYRA AI FCM microservice.

Listens on 127.0.0.1:8011. Accepts POST /send from Lua/OpenResty and forwards
the notification to Firebase Cloud Messaging (HTTP v1 API) with OAuth2
auth from a Google service-account JSON key.

Request body (JSON):
    {
        "device_token": "<FCM registration token>",
        "title":        "Notification title",
        "body":         "Notification body text",
        "data":         { ...optional custom payload fields, string-valued... }
    }

Response:
    200 {"ok": true}                      — delivered
    410 {"error": "..."} {"dead": true}   — token is dead; caller should DELETE it
    502 {"error": "..."}                  — transient FCM error; caller may retry

Configuration (environment variables or /etc/myra-fcm.env):
    FCM_PROJECT_ID         – Firebase project id (e.g. "myraai-prod")
    FCM_SERVICE_ACCOUNT    – path to the service-account JSON key
    LISTEN_PORT            – port to bind (default: 8011)

Payload contract: data-only (no top-level "notification" field). The Android
client constructs the displayed notification itself in
MyraFirebaseMessagingService.onMessageReceived. This guarantees consistent
foreground vs. background behaviour and gives us full control over channels,
priorities, and click actions.
"""

import json
import logging
import os
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

import httpx
import jwt  # PyJWT — same library used by apns_service.py

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("fcm")

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

_load_env_file("/etc/myra-fcm.env")

PROJECT_ID  = os.environ["FCM_PROJECT_ID"]
SA_PATH     = os.environ["FCM_SERVICE_ACCOUNT"]
PORT        = int(os.environ.get("LISTEN_PORT", "8011"))

with open(SA_PATH) as f:
    SERVICE_ACCOUNT = json.load(f)

CLIENT_EMAIL = SERVICE_ACCOUNT["client_email"]
PRIVATE_KEY  = SERVICE_ACCOUNT["private_key"]
TOKEN_URI    = SERVICE_ACCOUNT.get("token_uri", "https://oauth2.googleapis.com/token")

FCM_URL = f"https://fcm.googleapis.com/v1/projects/{PROJECT_ID}/messages:send"
SCOPE   = "https://www.googleapis.com/auth/firebase.messaging"

# ---------------------------------------------------------------------------
# OAuth2 access token — cached. Google issues 1-hour tokens; refresh
# 5 minutes before expiry to avoid races.
# ---------------------------------------------------------------------------

_token_cache: dict = {"access_token": None, "expires_at": 0}

def _access_token() -> str:
    now = int(time.time())
    if _token_cache["access_token"] and now < _token_cache["expires_at"] - 300:
        return _token_cache["access_token"]

    assertion = jwt.encode(
        {
            "iss":   CLIENT_EMAIL,
            "scope": SCOPE,
            "aud":   TOKEN_URI,
            "iat":   now,
            "exp":   now + 3600,
        },
        PRIVATE_KEY,
        algorithm="RS256",
    )
    resp = httpx.post(
        TOKEN_URI,
        data={
            "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
            "assertion":  assertion,
        },
        timeout=15.0,
    )
    resp.raise_for_status()
    j = resp.json()
    _token_cache["access_token"] = j["access_token"]
    _token_cache["expires_at"]   = now + int(j.get("expires_in", 3600))
    return _token_cache["access_token"]

# ---------------------------------------------------------------------------
# FCM sender — reuse a single HTTP/2 connection
# ---------------------------------------------------------------------------

_client: httpx.Client | None = None

def _get_client() -> httpx.Client:
    global _client
    if _client is None or _client.is_closed:
        _client = httpx.Client(http2=True, timeout=15.0)
    return _client

# Errors that mean "this token is permanently dead — delete it from the DB".
# https://firebase.google.com/docs/cloud-messaging/manage-tokens#detect-invalid-token-responses
_DEAD_ERRORS = {"UNREGISTERED", "INVALID_ARGUMENT", "NOT_FOUND"}

def send_notification(device_token: str, title: str, body: str,
                      data: dict | None = None) -> tuple[bool, str, bool]:
    """Returns (ok, err, dead). dead=True means caller should DELETE the token."""
    # Data-only payload. All values must be strings per FCM HTTP v1 spec.
    msg_data: dict[str, str] = {
        "title": title or "",
        "body":  body or "",
    }
    if data:
        for k, v in data.items():
            if v is None:
                continue
            msg_data[str(k)] = v if isinstance(v, str) else json.dumps(v)

    payload = {
        "message": {
            "token":   device_token,
            "data":    msg_data,
            "android": {"priority": "HIGH"},
        }
    }
    headers = {
        "authorization": f"Bearer {_access_token()}",
        "content-type":  "application/json",
    }

    try:
        resp = _get_client().post(FCM_URL, content=json.dumps(payload), headers=headers)
    except Exception as exc:
        log.warning("FCM request failed: %s", exc)
        return False, str(exc), False

    if resp.status_code == 200:
        return True, "", False

    err_status = ""
    err_msg    = ""
    try:
        body_json = resp.json()
        err_status = (body_json.get("error", {})
                                .get("details", [{}])[0]
                                .get("errorCode", "")) or ""
        err_msg = body_json.get("error", {}).get("message", "")
    except Exception:
        err_msg = resp.text[:200]

    dead = (resp.status_code in (400, 404) and err_status in _DEAD_ERRORS) \
        or err_status == "UNREGISTERED"

    log.warning("FCM rejected token=%s status=%d err=%s msg=%s dead=%s",
                device_token[:8], resp.status_code, err_status, err_msg, dead)
    return False, f"FCM {resp.status_code}: {err_status or err_msg}", dead

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

        ok, err, dead = send_notification(token, title, body, data)
        if ok:
            self._reply(200, {"ok": True})
        elif dead:
            self._reply(410, {"error": err, "dead": True})
        else:
            self._reply(502, {"error": err})

if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", PORT), Handler)
    log.info("MYRA FCM service listening on 127.0.0.1:%d (project=%s)", PORT, PROJECT_ID)
    server.serve_forever()

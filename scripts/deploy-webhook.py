import hashlib
import hmac
import http.server
import json
import os
import re
import subprocess
import sys
import time


def load_config():
    if len(sys.argv) != 3:
        print("usage: deploy-webhook.py <apps-json> <default-port>", file=sys.stderr)
        sys.exit(2)

    with open(sys.argv[1]) as file:
        apps = json.load(file)

    return apps, int(os.environ.get("DEPLOY_WEBHOOK_PORT", sys.argv[2]))


secret = os.environ["DEPLOY_WEBHOOK_SECRET"].encode()
apps, port = load_config()
systemctl = os.environ.get("SYSTEMCTL", "systemctl")
replay_window_seconds = 300
replay_dir = "/run/deploy-webhook/replay"
tag_pattern = re.compile(r"^[A-Za-z0-9._-]+$")
signature_pattern = re.compile(r"^sha256=([0-9a-f]{64})$")


def reject(handler, status, message):
    handler.send_error(status, message)
    return False


def cleanup_replay_cache(now):
    os.makedirs(replay_dir, mode=0o700, exist_ok=True)
    cutoff = now - replay_window_seconds
    for name in os.listdir(replay_dir):
        path = os.path.join(replay_dir, name)
        try:
            if os.path.isfile(path) and os.path.getmtime(path) < cutoff:
                os.unlink(path)
        except FileNotFoundError:
            pass


def verify_signature(handler, body):
    now = int(time.time())
    timestamp = handler.headers.get("X-Deploy-Timestamp")
    signature_header = handler.headers.get("X-Deploy-Signature", "")
    signature_match = signature_pattern.match(signature_header)

    if not timestamp or not timestamp.isdigit():
        return reject(handler, 401, "missing deploy timestamp")
    if abs(now - int(timestamp)) > replay_window_seconds:
        return reject(handler, 401, "stale deploy timestamp")
    if not signature_match:
        return reject(handler, 401, "invalid deploy signature")

    expected = hmac.new(secret, timestamp.encode() + b"." + body, hashlib.sha256).hexdigest()
    signature = signature_match.group(1)
    if not hmac.compare_digest(signature, expected):
        return reject(handler, 401, "invalid deploy signature")

    cleanup_replay_cache(now)
    replay_path = os.path.join(replay_dir, signature)
    try:
        fd = os.open(replay_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        return reject(handler, 409, "replayed deploy request")
    with os.fdopen(fd, "w") as file:
        file.write(str(now))
    return True


def validate_payload(app, payload):
    config = apps[app]

    tag = payload.get("tag")
    repo = payload.get("repo")

    if repo != config["repo"]:
        return None, "unexpected repo"
    if not isinstance(tag, str) or not tag_pattern.match(tag):
        return None, "invalid tag"

    return {
        "app": app,
        "repo": repo,
        "tag": tag,
    }, None


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        app = self.path.removeprefix("/deploy/").strip("/")
        if app not in apps:
            self.send_error(404, "unknown app")
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length)
            if not verify_signature(self, body):
                return
            payload = json.loads(body or b"{}")
        except Exception:
            self.send_error(400, "invalid json")
            return

        request, error = validate_payload(app, payload)
        if error:
            self.send_error(400, error)
            return

        unit = f"{app}-deploy@{request['tag']}.service"
        result = subprocess.run(
            [systemctl, "start", unit],
            text=True,
            capture_output=True,
        )
        if result.returncode != 0:
            self.send_response(500)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({
                "ok": False,
                "unit": unit,
                "stderr": result.stderr,
            }).encode())
            return

        self.send_response(202)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"ok": True, "unit": unit}).encode())

    def log_message(self, format, *args):
        print(f"{self.address_string()} - {format % args}", flush=True)


server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
server.serve_forever()

import hashlib
import hmac
import http.server
import json
import os
import re
import subprocess
import sys
import time
import uuid


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
commit_pattern = re.compile(r"^[0-9a-f]{40}$")
sha256_pattern = re.compile(r"^[0-9a-f]{64}$")
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
    commit = payload.get("commit")
    compose_sha256 = payload.get("composeSha256")
    images = payload.get("images")

    if repo != config["repo"]:
        return None, "unexpected repo"
    if not isinstance(tag, str) or not tag_pattern.match(tag):
        return None, "invalid tag"
    if not isinstance(commit, str) or not commit_pattern.match(commit):
        return None, "invalid commit"
    if not isinstance(compose_sha256, str) or not sha256_pattern.match(compose_sha256):
        return None, "invalid composeSha256"
    if not isinstance(images, dict):
        return None, "invalid images"

    expected_images = config["images"]
    if set(images.keys()) != set(expected_images.keys()):
        return None, "unexpected image keys"

    for name, image in expected_images.items():
        digest_prefix = f"{image}@sha256:"
        tag_ref = f"{image}:{tag}"
        actual_ref = images.get(name)
        if actual_ref != tag_ref and not (
            isinstance(actual_ref, str)
            and actual_ref.startswith(digest_prefix)
            and sha256_pattern.match(actual_ref.removeprefix(digest_prefix))
        ):
            return None, f"unexpected image ref for {name}"

    return {
        "app": app,
        "repo": repo,
        "tag": tag,
        "commit": commit,
        "composePath": config["composePath"],
        "composeSha256": compose_sha256,
        "images": images,
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

        request_id = uuid.uuid4().hex
        request_dir = os.path.join("/run/deploy-webhook", app)
        os.makedirs(request_dir, mode=0o700, exist_ok=True)
        request_path = os.path.join(request_dir, f"{request_id}.json")
        tmp_path = f"{request_path}.tmp"
        fd = os.open(tmp_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as file:
            json.dump(request, file)
        os.replace(tmp_path, request_path)

        unit = f"{app}-deploy@{request_id}.service"
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
                "request": request_id,
                "stderr": result.stderr,
            }).encode())
            return

        self.send_response(202)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"ok": True, "unit": unit, "request": request_id}).encode())

    def log_message(self, format, *args):
        print(f"{self.address_string()} - {format % args}", flush=True)


server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
server.serve_forever()

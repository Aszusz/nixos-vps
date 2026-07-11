{ config, lib, pkgs, ... }:

let
  cfg = config.services.deployWebhook;
  appsJson = builtins.toJSON cfg.apps;

  deployWebhook = pkgs.writeText "deploy-webhook.py" ''
    import http.server
    import json
    import os
    import re
    import subprocess
    import uuid

    token = os.environ["DEPLOY_WEBHOOK_TOKEN"]
    port = int(os.environ.get("DEPLOY_WEBHOOK_PORT", "${toString cfg.port}"))
    apps = ${appsJson}
    tag_pattern = re.compile(r"^[A-Za-z0-9._-]+$")
    commit_pattern = re.compile(r"^[0-9a-f]{40}$")
    sha256_pattern = re.compile(r"^[0-9a-f]{64}$")

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
        expected_ref = f"{image}:{tag}"
        if images.get(name) != expected_ref:
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

        expected = f"Bearer {token}"
        if self.headers.get("Authorization") != expected:
          self.send_error(401, "unauthorized")
          return

        try:
          length = int(self.headers.get("Content-Length", "0"))
          payload = json.loads(self.rfile.read(length) or b"{}")
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

        unit = apps[app]["unit"].format(request=request_id)
        result = subprocess.run(
          ["${pkgs.systemd}/bin/systemctl", "start", unit],
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
  '';
in
{
  options.services.deployWebhook = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 9010;
    };
    apps = lib.mkOption {
      default = { };
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          repo = lib.mkOption { type = lib.types.str; };
          composePath = lib.mkOption { type = lib.types.str; };
          images = lib.mkOption { type = lib.types.attrsOf lib.types.str; };
          unit = lib.mkOption { type = lib.types.str; };
        };
      });
    };
  };

  config = lib.mkIf cfg.enable {
  systemd.tmpfiles.rules = [
    "d /var/lib/deploy-webhook 0700 root root -"
    "d /run/deploy-webhook 0700 root root -"
  ];

  systemd.services.deploy-webhook = {
    description = "Deployment webhook receiver";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      EnvironmentFile = "/var/lib/deploy-webhook/env";
      ExecStart = "${pkgs.python3}/bin/python ${deployWebhook}";
      Restart = "always";
      RestartSec = "5s";
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
    };
    unitConfig.ConditionPathExists = "/var/lib/deploy-webhook/env";
  };
  };
}

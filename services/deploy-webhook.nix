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

    token = os.environ["DEPLOY_WEBHOOK_TOKEN"]
    port = int(os.environ.get("DEPLOY_WEBHOOK_PORT", "${toString cfg.port}"))
    apps = ${appsJson}
    tag_pattern = re.compile(r"^[A-Za-z0-9._-]+$")

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

        tag = payload.get("tag")
        repo = payload.get("repo")
        if repo != apps[app]["repo"]:
          self.send_error(400, "unexpected repo")
          return
        if not isinstance(tag, str) or not tag_pattern.match(tag):
          self.send_error(400, "invalid tag")
          return

        unit = apps[app]["unit"].format(tag=tag)
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
          unit = lib.mkOption { type = lib.types.str; };
        };
      });
    };
  };

  config = lib.mkIf cfg.enable {
  systemd.tmpfiles.rules = [
    "d /var/lib/deploy-webhook 0700 root root -"
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

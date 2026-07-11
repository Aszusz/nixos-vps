{ config, lib, pkgs, ... }:

let
  cfg = config.services.deployWebhook;
  appsJson = builtins.toJSON cfg.apps;
  appsConfig = pkgs.writeText "deploy-webhook-apps.json" appsJson;
  deployWebhook = ../scripts/deploy-webhook.py;
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
        };
      });
    };
  };

  config = lib.mkIf cfg.enable {
  services.nginx.commonHttpConfig = ''
    limit_req_zone $binary_remote_addr zone=deploy_webhook:10m rate=5r/m;
  '';

  systemd.tmpfiles.rules = [
    "d /var/lib/deploy-webhook 0700 root root -"
    "d /run/deploy-webhook 0700 root root -"
    "d /run/deploy-webhook/replay 0700 root root -"
  ];

  systemd.services.deploy-webhook = {
    description = "Deployment webhook receiver";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      EnvironmentFile = "/var/lib/deploy-webhook/env";
      Environment = "SYSTEMCTL=${pkgs.systemd}/bin/systemctl";
      ExecStart = "${pkgs.python3}/bin/python ${deployWebhook} ${appsConfig} ${toString cfg.port}";
      Restart = "always";
      RestartSec = "5s";
      ProtectSystem = "strict";
      ReadWritePaths = [ "/run/deploy-webhook" ];
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      SystemCallArchitectures = "native";
      NoNewPrivileges = true;
    };
    unitConfig.ConditionPathExists = "/var/lib/deploy-webhook/env";
  };
  };
}

{ config, lib, pkgs, ... }:

let
  cfg = config.services.deployWebhook;
  appsJson = builtins.toJSON cfg.apps;
  appsConfig = pkgs.writeText "deploy-webhook-apps.json" appsJson;
  deployWebhook = ../scripts/deploy-webhook.py;
  allowedUnitPrefixes = builtins.toJSON (
    map (app: "${app}-deploy@") (builtins.attrNames cfg.apps)
  );
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
    users.groups.deploy-webhook = { };
    users.users.deploy-webhook = {
      isSystemUser = true;
      group = "deploy-webhook";
    };

    security.polkit.enable = true;
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id !== "org.freedesktop.systemd1.manage-units" || subject.user !== "deploy-webhook") {
          return;
        }

        var verb = action.lookup("verb");
        var unit = action.lookup("unit");
        var allowedUnitPrefixes = ${allowedUnitPrefixes};

        if (verb !== "start" || !unit) {
          return;
        }

        for (var i = 0; i < allowedUnitPrefixes.length; i++) {
          if (unit.indexOf(allowedUnitPrefixes[i]) === 0 && unit.slice(-8) === ".service") {
            return polkit.Result.YES;
          }
        }
      });
    '';

    services.nginx.commonHttpConfig = ''
      limit_req_zone $binary_remote_addr zone=deploy_webhook:10m rate=5r/m;
    '';

    systemd.tmpfiles.rules = [
      "d /var/lib/deploy-webhook 0700 root root -"
      "d /run/deploy-webhook 0700 deploy-webhook deploy-webhook -"
      "d /run/deploy-webhook/replay 0700 deploy-webhook deploy-webhook -"
    ];

    systemd.services.deploy-webhook = {
      description = "Deployment webhook receiver";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        User = "deploy-webhook";
        Group = "deploy-webhook";
        UMask = "0077";
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

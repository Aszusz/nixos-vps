{ config, lib, pkgs, ... }:

let
  cfg = config.services.postgresAdmin;

  mkPgwebService = name: app: {
    name = "pgweb-${name}";
    value = {
      description = "pgweb PostgreSQL admin for ${name}";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        DynamicUser = true;
        UMask = "0077";
        EnvironmentFile = app.envFile;
        Environment = "HOME=/var/lib/pgweb-${name}";
        ExecStart = lib.escapeShellArgs [
          (lib.getExe pkgs.pgweb)
          "--bind=127.0.0.1"
          "--listen=${toString app.port}"
          "--readonly"
          "--lock-session"
          "--skip-open"
        ];
        Restart = "always";
        RestartSec = "5s";
        StateDirectory = "pgweb-${name}";
        ProtectSystem = "strict";
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
      unitConfig.ConditionPathExists = app.envFile;
    };
  };

  mkNginxVhost = name: app: {
    name = app.domain;
    value = {
      enableACME = true;
      forceSSL = true;

      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString app.port}";
        extraConfig = ''
          allow 100.64.0.0/10;
          deny all;
        '';
      };
    };
  };
in
{
  options.services.postgresAdmin = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };

    apps = lib.mkOption {
      default = { };
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options = {
          domain = lib.mkOption {
            type = lib.types.str;
            description = "Tailscale-only virtual host for this app's pgweb instance.";
          };

          port = lib.mkOption {
            type = lib.types.port;
            description = "Loopback port for this app's pgweb instance.";
          };

          envFile = lib.mkOption {
            type = lib.types.path;
            default = "/var/lib/${name}/pgweb.env";
            description = "Environment file containing PGWEB_DATABASE_URL.";
          };
        };
      }));
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services = lib.listToAttrs (lib.mapAttrsToList mkPgwebService cfg.apps);
    services.nginx.virtualHosts = lib.listToAttrs (lib.mapAttrsToList mkNginxVhost cfg.apps);
  };
}

{ config, lib, pkgs, ... }:

let
  cfg = config.services.postgresAdmin;

  cloudbeaverDbAccess = pkgs.runCommand "cloudbeaver-db-access" { } ''
    mkdir -p $out
    cp ${../scripts/cloudbeaver-db-access.py} $out/cloudbeaver-db-access.py
    cp ${../scripts/cloudbeaver-db-access.sql} $out/cloudbeaver-db-access.sql
  '';

  mkSchemaArgs = schemas:
    lib.concatMap (schema: [ "--schema" schema ]) schemas;

  mkDbAccessService = name: app: {
    name = "cloudbeaver-${name}-db-access";
    value = {
      description = "Ensure CloudBeaver PostgreSQL read-only access for ${name}";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        UMask = "0077";
        EnvironmentFile = [ app.appEnvFile app.envFile ];
        ExecStart = lib.escapeShellArgs ([
          (lib.getExe pkgs.python3)
          "${cloudbeaverDbAccess}/cloudbeaver-db-access.py"
          "--psql"
          (lib.getExe' pkgs.postgresql "psql")
          "--readonly-role"
          app.readOnlyRole
        ] ++ mkSchemaArgs app.schemas);
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
      unitConfig.ConditionPathExists = [ app.appEnvFile app.envFile ];
    };
  };

  mkCloudBeaverService = name: app: {
    name = "cloudbeaver-${name}";
    value = {
      description = "CloudBeaver PostgreSQL admin for ${name}";
      after = [ "network-online.target" "docker.service" "cloudbeaver-${name}-db-access.service" ];
      wants = [ "network-online.target" "cloudbeaver-${name}-db-access.service" ];
      requires = [ "docker.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStartPre = [
          "-${lib.escapeShellArgs [ (lib.getExe pkgs.docker) "rm" "-f" "cloudbeaver-${name}" ]}"
          (lib.escapeShellArgs [ (lib.getExe pkgs.docker) "pull" app.image ])
        ];
        ExecStart = lib.escapeShellArgs [
          (lib.getExe pkgs.docker)
          "run"
          "--rm"
          "--name"
          "cloudbeaver-${name}"
          "--publish"
          "127.0.0.1:${toString app.port}:8978"
          "--volume"
          "cloudbeaver-${name}:/opt/cloudbeaver/workspace"
          app.image
        ];
        ExecStop = lib.escapeShellArgs [ (lib.getExe pkgs.docker) "stop" "cloudbeaver-${name}" ];
        Restart = "always";
        RestartSec = "5s";
      };
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
            description = "Tailscale-only virtual host for this app's CloudBeaver instance.";
          };

          port = lib.mkOption {
            type = lib.types.port;
            description = "Loopback port for this app's CloudBeaver instance.";
          };

          envFile = lib.mkOption {
            type = lib.types.path;
            default = "/var/lib/${name}/cloudbeaver.env";
            description = "Environment file containing CLOUDBEAVER_DATABASE_URL.";
          };

          appEnvFile = lib.mkOption {
            type = lib.types.path;
            default = "/var/lib/${name}/app.env";
            description = "App environment file containing POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB, and POSTGRES_PORT.";
          };

          readOnlyRole = lib.mkOption {
            type = lib.types.str;
            default = "${builtins.replaceStrings [ "-" ] [ "_" ] name}_readonly";
            description = "PostgreSQL role CloudBeaver uses for read-only inspection.";
          };

          image = lib.mkOption {
            type = lib.types.str;
            default = "dbeaver/cloudbeaver:latest";
            description = "CloudBeaver container image.";
          };

          schemas = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "public" ];
            description = "Application-owned schemas CloudBeaver may inspect.";
          };
        };
      }));
    };
  };

  config = lib.mkIf cfg.enable {
    virtualisation.docker.enable = true;
    systemd.services =
      lib.listToAttrs (lib.mapAttrsToList mkDbAccessService cfg.apps)
      // lib.listToAttrs (lib.mapAttrsToList mkCloudBeaverService cfg.apps);
    services.nginx.virtualHosts = lib.listToAttrs (lib.mapAttrsToList mkNginxVhost cfg.apps);
  };
}

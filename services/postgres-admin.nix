{ config, lib, pkgs, ... }:

let
  cfg = config.services.postgresAdmin;

  pgwebDbAccess = pkgs.runCommand "pgweb-db-access" { } ''
    mkdir -p $out
    cp ${../scripts/pgweb-db-access.py} $out/pgweb-db-access.py
    cp ${../scripts/pgweb-db-access.sql} $out/pgweb-db-access.sql
  '';

  mkSchemaArgs = schemas:
    lib.concatMap (schema: [ "--schema" schema ]) schemas;

  mkDbAccessService = name: app: {
    name = "pgweb-${name}-db-access";
    value = {
      description = "Ensure pgweb PostgreSQL read-only access for ${name}";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        UMask = "0077";
        User = "postgres";
        EnvironmentFile = [ app.appEnvFile app.envFile ];
        ExecStart = lib.escapeShellArgs ([
          (lib.getExe pkgs.python3)
          "${pgwebDbAccess}/pgweb-db-access.py"
          "--psql"
          (lib.getExe' pkgs.postgresql "psql")
          "--admin-user"
          "postgres"
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

  mkPgwebService = name: app: {
    name = "pgweb-${name}";
    value = {
      description = "pgweb PostgreSQL admin for ${name}";
      after = [ "network-online.target" "pgweb-${name}-db-access.service" ];
      wants = [ "network-online.target" "pgweb-${name}-db-access.service" ];
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

          appEnvFile = lib.mkOption {
            type = lib.types.path;
            default = "/var/lib/${name}/app.env";
            description = "App environment file containing POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB, and POSTGRES_PORT.";
          };

          readOnlyRole = lib.mkOption {
            type = lib.types.str;
            default = "${builtins.replaceStrings [ "-" ] [ "_" ] name}_readonly";
            description = "PostgreSQL role pgweb uses for read-only inspection.";
          };

          schemas = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "public" ];
            description = "Application-owned schemas pgweb may inspect.";
          };
        };
      }));
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services =
      lib.listToAttrs (lib.mapAttrsToList mkDbAccessService cfg.apps)
      // lib.listToAttrs (lib.mapAttrsToList mkPgwebService cfg.apps);
    services.nginx.virtualHosts = lib.listToAttrs (lib.mapAttrsToList mkNginxVhost cfg.apps);
  };
}

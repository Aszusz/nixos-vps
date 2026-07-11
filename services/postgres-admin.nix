{ config, lib, pkgs, ... }:

let
  cfg = config.services.postgresAdmin;

  quoteSqlString = value: "'${builtins.replaceStrings [ "'" ] [ "''" ] value}'";

  mkDbAccessScript = name: app:
    pkgs.writeShellScript "pgweb-${name}-db-access" ''
      set -euo pipefail

      readonly_password="$(${pkgs.python3}/bin/python - <<'PY'
      import os
      import urllib.parse

      password = urllib.parse.urlparse(os.environ["PGWEB_DATABASE_URL"]).password
      if not password:
          raise SystemExit("PGWEB_DATABASE_URL must include the read-only role password")
      print(urllib.parse.unquote(password))
      PY
      )"

      export PGPASSWORD="$POSTGRES_PASSWORD"

      psql=(
        ${lib.getExe' pkgs.postgresql "psql"}
        -h 127.0.0.1
        -p "$POSTGRES_PORT"
        -U "$POSTGRES_USER"
        -d "$POSTGRES_DB"
        -v ON_ERROR_STOP=1
      )

      for attempt in $(seq 1 60); do
        if "''${psql[@]}" -tAc 'SELECT 1' >/dev/null 2>&1; then
          break
        fi

        if [ "$attempt" -eq 60 ]; then
          "''${psql[@]}" -tAc 'SELECT 1' >/dev/null
        fi

        sleep 2
      done

      "''${psql[@]}" \
        -v readonly_role=${lib.escapeShellArg app.readOnlyRole} \
        -v readonly_password="$readonly_password" \
        -v database_owner="$POSTGRES_USER" <<'SQL'
      SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'readonly_role', :'readonly_password')
      WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'readonly_role')
      \gexec

      SELECT format('ALTER ROLE %I WITH LOGIN PASSWORD %L', :'readonly_role', :'readonly_password')
      \gexec

      SELECT format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), :'readonly_role')
      \gexec

      SELECT format('GRANT USAGE ON SCHEMA %I TO %I', schema_name, :'readonly_role')
      FROM unnest(ARRAY[${lib.concatMapStringsSep ", " quoteSqlString app.schemas}]) AS schema_name
      \gexec

      SELECT format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO %I', schema_name, :'readonly_role')
      FROM unnest(ARRAY[${lib.concatMapStringsSep ", " quoteSqlString app.schemas}]) AS schema_name
      \gexec

      SELECT format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I GRANT SELECT ON TABLES TO %I', :'database_owner', schema_name, :'readonly_role')
      FROM unnest(ARRAY[${lib.concatMapStringsSep ", " quoteSqlString app.schemas}]) AS schema_name
      \gexec
      SQL
    '';

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
        EnvironmentFile = [ app.appEnvFile app.envFile ];
        ExecStart = mkDbAccessScript name app;
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

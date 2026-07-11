{ pkgs, ... }:

let
  appDir = "/var/lib/monobara-codex";
  appEnv = "${appDir}/app.env";
  ghcrEnv = "${appDir}/ghcr.env";
  imageWeb = "ghcr.io/aszusz/monobara-codex-web";
  imageApi = "ghcr.io/aszusz/monobara-codex-api";

  deployScript = pkgs.writeShellScript "monobara-deploy" ''
    set -euo pipefail

    tag="''${1:?tag is required}"
    exec 9>/run/monobara-codex-deploy.lock
    ${pkgs.util-linux}/bin/flock -n 9

    ${pkgs.podman}/bin/podman login ghcr.io \
      --username "$GHCR_USERNAME" \
      --password-stdin < "$GHCR_TOKEN_FILE"

    ${pkgs.podman}/bin/podman pull "${imageWeb}:$tag"
    ${pkgs.podman}/bin/podman pull "${imageApi}:$tag"
    ${pkgs.podman}/bin/podman tag "${imageWeb}:$tag" localhost/monobara-codex-web:current
    ${pkgs.podman}/bin/podman tag "${imageApi}:$tag" localhost/monobara-codex-api:current

    ${pkgs.podman}/bin/podman run --rm \
      --network=host \
      --env-file ${appEnv} \
      localhost/monobara-codex-api:current \
      bun --cwd packages/db drizzle-kit migrate

    ${pkgs.systemd}/bin/systemctl restart monobara-codex-api.service monobara-codex-web.service
    ${pkgs.curl}/bin/curl -fsS http://127.0.0.1:3000/health >/dev/null
  '';
in
{
  systemd.tmpfiles.rules = [
    "d ${appDir} 0700 root root -"
  ];

  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_18;
    enableTCPIP = true;
    settings = {
      listen_addresses = pkgs.lib.mkForce "127.0.0.1";
      password_encryption = "scram-sha-256";
    };
    authentication = pkgs.lib.mkForce ''
      local all all peer
      host monobara monobara 127.0.0.1/32 scram-sha-256
    '';
  };

  systemd.services.monobara-codex-db = {
    description = "Prepare monobara-codex PostgreSQL role and database";
    after = [ "postgresql.service" ];
    requires = [ "postgresql.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      EnvironmentFile = appEnv;
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "monobara-codex-db" ''
        set -euo pipefail

        ${pkgs.sudo}/bin/sudo -u postgres ${pkgs.postgresql_18}/bin/psql --set=ON_ERROR_STOP=1 --set=password="$MONOBARA_DB_PASSWORD" <<SQL
        DO \$\$
        BEGIN
          IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'monobara') THEN
            CREATE ROLE monobara LOGIN;
          END IF;
        END
        \$\$;
        ALTER ROLE monobara WITH PASSWORD :'password';
        SELECT 'CREATE DATABASE monobara OWNER monobara'
        WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'monobara')\gexec
        SQL
      '';
    };
    unitConfig.ConditionPathExists = appEnv;
  };

  systemd.services.monobara-codex-api = {
    description = "monobara-codex API container";
    after = [ "network-online.target" "monobara-codex-db.service" ];
    wants = [ "network-online.target" ];
    requires = [ "monobara-codex-db.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Restart = "always";
      RestartSec = "5s";
      ExecStartPre = "-${pkgs.podman}/bin/podman rm -f monobara-codex-api";
      ExecStart = "${pkgs.podman}/bin/podman run --rm --name monobara-codex-api --network=host --env-file ${appEnv} localhost/monobara-codex-api:current";
      ExecStop = "${pkgs.podman}/bin/podman stop monobara-codex-api";
    };
    unitConfig.ConditionPathExists = appEnv;
  };

  systemd.services.monobara-codex-web = {
    description = "monobara-codex web container";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Restart = "always";
      RestartSec = "5s";
      ExecStartPre = "-${pkgs.podman}/bin/podman rm -f monobara-codex-web";
      ExecStart = "${pkgs.podman}/bin/podman run --rm --name monobara-codex-web --publish 127.0.0.1:8080:80 localhost/monobara-codex-web:current";
      ExecStop = "${pkgs.podman}/bin/podman stop monobara-codex-web";
    };
  };

  systemd.services."monobara-deploy@" = {
    description = "Deploy monobara-codex image tag %i";
    after = [ "network-online.target" "postgresql.service" ];
    wants = [ "network-online.target" ];
    requires = [ "postgresql.service" ];
    serviceConfig = {
      Type = "oneshot";
      EnvironmentFile = [ appEnv ghcrEnv ];
      ExecStart = "${deployScript} %i";
    };
    unitConfig.ConditionPathExists = [ appEnv ghcrEnv ];
  };

  services.nginx.virtualHosts."fullstack.typestrict.dev" = {
    enableACME = true;
    forceSSL = true;

    locations."/deploy/" = {
      proxyPass = "http://127.0.0.1:9010";
      extraConfig = ''
        client_max_body_size 32k;
      '';
    };

    locations."/api/".proxyPass = "http://127.0.0.1:3000";
    locations."/rpc/".proxyPass = "http://127.0.0.1:3000";
    locations."/".proxyPass = "http://127.0.0.1:8080";
  };
}

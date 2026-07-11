{ pkgs, ... }:

let
  appDir = "/var/lib/monobara-codex";
  appEnv = "${appDir}/app.env";
  ghcrEnv = "${appDir}/ghcr.env";
  imageWeb = "ghcr.io/aszusz/monobara-codex-web";
  imageApi = "ghcr.io/aszusz/monobara-codex-api";
  appConfig = pkgs.writeText "monobara-codex-app.json" (builtins.toJSON {
    name = "monobara-codex";
    appEnv = appEnv;
    podman = "${pkgs.podman}/bin/podman";
    systemctl = "${pkgs.systemd}/bin/systemctl";
    curl = "${pkgs.curl}/bin/curl";
    images = {
      web = imageWeb;
      api = imageApi;
    };
    localImages = {
      web = "localhost/monobara-codex-web:current";
      api = "localhost/monobara-codex-api:current";
    };
    migration = {
      image = "api";
      command = [ "bun" "--cwd" "packages/db" "drizzle-kit" "migrate" ];
    };
    restartServices = [ "monobara-codex-api.service" "monobara-codex-web.service" ];
    healthUrl = "http://127.0.0.1:3000/health";
  });
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
      host monobara all 127.0.0.1/32 scram-sha-256
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
      User = "postgres";
      RemainAfterExit = true;
      ExecStart = "${pkgs.python3}/bin/python ${../scripts/ensure-app-db.py} --psql ${pkgs.postgresql_18}/bin/psql";
    };
    unitConfig.ConditionPathExists = appEnv;
  };

  systemd.services.monobara-codex-api = {
    description = "monobara-codex API container";
    after = [ "network-online.target" "monobara-codex-db.service" ];
    wants = [ "network-online.target" ];
    requires = [ "monobara-codex-db.service" ];
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
    serviceConfig = {
      Restart = "always";
      RestartSec = "5s";
      ExecStartPre = "-${pkgs.podman}/bin/podman rm -f monobara-codex-web";
      ExecStart = "${pkgs.podman}/bin/podman run --rm --name monobara-codex-web --add-host api:127.0.0.1 --publish 127.0.0.1:8080:80 localhost/monobara-codex-web:current";
      ExecStop = "${pkgs.podman}/bin/podman stop monobara-codex-web";
    };
  };

  systemd.services.monobara-codex-start = {
    description = "Start monobara-codex containers when deployed images exist";
    after = [ "network-online.target" "monobara-codex-db.service" ];
    wants = [ "network-online.target" ];
    requires = [ "monobara-codex-db.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.python3}/bin/python ${../scripts/start-app.py} ${appConfig}";
    };
  };

  systemd.services."monobara-codex-deploy@" = {
    description = "Deploy monobara-codex image tag %i";
    after = [ "network-online.target" "postgresql.service" ];
    wants = [ "network-online.target" ];
    requires = [ "postgresql.service" ];
    serviceConfig = {
      Type = "oneshot";
      EnvironmentFile = [ appEnv ghcrEnv ];
      ExecStart = "${pkgs.python3}/bin/python ${../scripts/deploy-app.py} ${appConfig} %i";
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

    locations."/health".proxyPass = "http://127.0.0.1:3000";
    locations."/api/".proxyPass = "http://127.0.0.1:3000";
    locations."/rpc/".proxyPass = "http://127.0.0.1:3000";
    locations."/".proxyPass = "http://127.0.0.1:8080";
  };

  services.postgresAdmin.apps.monobara-codex = {
    domain = "monobara-db.admin.typestrict.dev";
    port = 18081;
    readOnlyRole = "monobara_readonly";
    schemas = [ "public" "drizzle" ];
  };

  services.deployWebhook.apps.monobara-codex = {
    repo = "Aszusz/monobara-codex";
  };
}

{ lib, pkgs }:

{
  name,
  domain,
  repo,
  images,
  webPort,
  apiPort,
  composePath ? "docker-compose.yml",
  healthPath ? "/health",
  apiPrefixes ? [ "/api/" "/rpc/" ],
  appDir ? "/var/lib/${name}",
  webhookPort ? 9010,
}:

let
  envFile = "${appDir}/app.env";
  runtimeEnvFile = "${appDir}/images.env";
  registryEnvFile = "${appDir}/ghcr.env";
  currentComposeFile = "${appDir}/docker-compose.yml";
  releasesDir = "${appDir}/releases";
  requestDir = "/run/deploy-webhook/${name}";
  pythonWithYaml = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
  composeDeploy = ../scripts/compose-deploy.py;
  composeStart = ../scripts/compose-start.py;
  composeStop = ../scripts/compose-stop.py;
  validateCompose = ../scripts/validate-compose.py;
  composeEnvironment = [
    "APP_NAME=${name}"
    "APP_REPO=${repo}"
    "APP_DIR=${appDir}"
    "REQUEST_DIR=${requestDir}"
    "APP_ENV_FILE=${envFile}"
    "RUNTIME_ENV_FILE=${runtimeEnvFile}"
    "CURRENT_COMPOSE_FILE=${currentComposeFile}"
    "RELEASES_DIR=${releasesDir}"
    "API_PORT=${toString apiPort}"
    "HEALTH_PATH=${healthPath}"
    "CURL=${pkgs.curl}/bin/curl"
    "DOCKER=${pkgs.docker}/bin/docker"
    "DOCKER_COMPOSE=${pkgs.docker-compose}/bin/docker-compose"
    "FLOCK=${pkgs.util-linux}/bin/flock"
    "PYTHON_WITH_YAML=${pythonWithYaml}/bin/python"
    "SHA256SUM=${pkgs.coreutils}/bin/sha256sum"
    "VALIDATE_COMPOSE=${validateCompose}"
  ];
in
{
  virtualisation.docker.enable = true;
  environment.systemPackages = [ pkgs.docker-compose ];

  systemd.tmpfiles.rules = [
    "d ${appDir} 0700 root root -"
  ];

  systemd.services."${name}-deploy@" = {
    description = "Deploy ${name} image tag %i";
    after = [ "network-online.target" "docker.service" ];
    wants = [ "network-online.target" ];
    requires = [ "docker.service" ];
    serviceConfig = {
      Type = "oneshot";
      EnvironmentFile = registryEnvFile;
      Environment = composeEnvironment;
      ExecStart = "${pkgs.python3}/bin/python ${composeDeploy} %i";
    };
    unitConfig.ConditionPathExists = [ envFile registryEnvFile ];
  };

  systemd.services."${name}-compose" = {
    description = "Start ${name} Compose stack";
    after = [ "network-online.target" "docker.service" ];
    wants = [ "network-online.target" ];
    requires = [ "docker.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Environment = composeEnvironment;
      ExecStart = "${pkgs.python3}/bin/python ${composeStart}";
      ExecStop = "${pkgs.python3}/bin/python ${composeStop}";
    };
    unitConfig.ConditionPathExists = envFile;
  };

  services.deployWebhook.apps.${name} = {
    inherit repo composePath images;
  };

  services.nginx.virtualHosts.${domain} = {
    enableACME = true;
    forceSSL = true;

    locations = {
      "/deploy/" = {
        proxyPass = "http://127.0.0.1:${toString webhookPort}";
        extraConfig = ''
          client_max_body_size 32k;
          limit_req zone=deploy_webhook burst=5 nodelay;
        '';
      };

      ${healthPath}.proxyPass = "http://127.0.0.1:${toString apiPort}";
      "/".proxyPass = "http://127.0.0.1:${toString webPort}";
    } // lib.listToAttrs (map (prefix: {
      name = prefix;
      value.proxyPass = "http://127.0.0.1:${toString apiPort}";
    }) apiPrefixes);
  };
}

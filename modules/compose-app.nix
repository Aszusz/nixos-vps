{ lib, pkgs }:

{
  name,
  domain,
  repo,
  images,
  webPort,
  apiPort,
  healthPath ? "/health",
  apiPrefixes ? [ "/api/" "/rpc/" ],
  appDir ? "/var/lib/${name}",
  webhookPort ? 9010,
}:

let
  repoDir = "${appDir}/repo";
  envFile = "${appDir}/app.env";
  runtimeEnvFile = "${appDir}/images.env";
  registryEnvFile = "${appDir}/ghcr.env";

  imageEnvScript = lib.concatStringsSep "\n" (
    lib.mapAttrsToList
      (envName: image: ''
        printf '%s=%s:%s\n' '${envName}' '${image}' "$tag" >> "$runtime_env"
      '')
      images
  );

  composeArgs = "--project-name ${name} --env-file ${envFile} --env-file ${runtimeEnvFile} -f ${repoDir}/docker-compose.yml";

  deployScript = pkgs.writeShellScript "${name}-deploy" ''
    set -euo pipefail

    tag="''${1:?tag is required}"
    repo_url="https://github.com/${repo}.git"
    runtime_env="${runtimeEnvFile}"

    exec 9>/run/${name}-deploy.lock
    ${pkgs.util-linux}/bin/flock -n 9

    ${pkgs.docker}/bin/docker login ghcr.io \
      --username "$GHCR_USERNAME" \
      --password-stdin < "$GHCR_TOKEN_FILE"

    if [ -d "${repoDir}/.git" ]; then
      ${pkgs.git}/bin/git -C "${repoDir}" fetch --tags origin
    else
      rm -rf "${repoDir}"
      ${pkgs.git}/bin/git clone "$repo_url" "${repoDir}"
      ${pkgs.git}/bin/git -C "${repoDir}" fetch --tags origin
    fi
    ${pkgs.git}/bin/git -C "${repoDir}" checkout --force "$tag"

    rm -f "$runtime_env"
    printf 'TAG=%s\n' "$tag" > "$runtime_env"
    ${imageEnvScript}

    ${pkgs.docker-compose}/bin/docker-compose ${composeArgs} pull
    ${pkgs.docker-compose}/bin/docker-compose ${composeArgs} up -d postgres
    ${pkgs.docker-compose}/bin/docker-compose ${composeArgs} run --rm migrate
    ${pkgs.docker-compose}/bin/docker-compose ${composeArgs} up -d --no-build --remove-orphans

    for attempt in $(${pkgs.coreutils}/bin/seq 1 30); do
      if ${pkgs.curl}/bin/curl -fsS "http://127.0.0.1:${toString apiPort}${healthPath}" >/dev/null; then
        exit 0
      fi
      ${pkgs.coreutils}/bin/sleep 1
    done

    ${pkgs.curl}/bin/curl -fsS "http://127.0.0.1:${toString apiPort}${healthPath}" >/dev/null
  '';

  startScript = pkgs.writeShellScript "${name}-compose-start" ''
    set -euo pipefail

    if [ -f "${repoDir}/docker-compose.yml" ] && [ -f "${runtimeEnvFile}" ]; then
      ${pkgs.docker-compose}/bin/docker-compose ${composeArgs} up -d --no-build --remove-orphans
    fi
  '';
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
      ExecStart = "${deployScript} %i";
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
      ExecStart = startScript;
      ExecStop = "${pkgs.docker-compose}/bin/docker-compose ${composeArgs} stop";
    };
    unitConfig.ConditionPathExists = envFile;
  };

  services.nginx.virtualHosts.${domain} = {
    enableACME = true;
    forceSSL = true;

    locations = {
      "/deploy/" = {
        proxyPass = "http://127.0.0.1:${toString webhookPort}";
        extraConfig = ''
          client_max_body_size 32k;
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

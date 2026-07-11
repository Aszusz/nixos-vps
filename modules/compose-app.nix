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

  imageEnvScript = lib.concatStringsSep "\n" (
    lib.mapAttrsToList
      (envName: _image: ''
        image_ref="$(${pkgs.jq}/bin/jq -r --arg name '${envName}' '.images[$name]' "$request_file")"
        printf '%s=%s\n' '${envName}' "$image_ref" >> "$runtime_env"
      '')
      images
  );

  deployScript = pkgs.writeShellScript "${name}-deploy" ''
    set -euo pipefail

    request_id="''${1:?request id is required}"
    case "$request_id" in
      (*[!0-9a-f]*) echo "invalid request id" >&2; exit 2 ;;
    esac

    request_file="${requestDir}/$request_id.json"
    if [ ! -f "$request_file" ]; then
      echo "missing deploy request: $request_file" >&2
      exit 2
    fi

    tag="$(${pkgs.jq}/bin/jq -r '.tag' "$request_file")"
    commit="$(${pkgs.jq}/bin/jq -r '.commit' "$request_file")"
    compose_path="$(${pkgs.jq}/bin/jq -r '.composePath' "$request_file")"
    expected_sha256="$(${pkgs.jq}/bin/jq -r '.composeSha256' "$request_file")"
    runtime_env="${runtimeEnvFile}"
    release_dir="${releasesDir}/$commit"
    compose_file="$release_dir/docker-compose.yml"
    compose_url="https://raw.githubusercontent.com/${repo}/$commit/$compose_path"

    exec 9>/run/${name}-deploy.lock
    ${pkgs.util-linux}/bin/flock -n 9

    ${pkgs.docker}/bin/docker login ghcr.io \
      --username "$GHCR_USERNAME" \
      --password-stdin < "$GHCR_TOKEN_FILE"

    tmp_compose="$(${pkgs.coreutils}/bin/mktemp)"
    trap 'rm -f "$tmp_compose"' EXIT

    ${pkgs.curl}/bin/curl -fsSL "$compose_url" -o "$tmp_compose"
    actual_sha256="$(${pkgs.coreutils}/bin/sha256sum "$tmp_compose")"
    actual_sha256="''${actual_sha256%% *}"
    if [ "$actual_sha256" != "$expected_sha256" ]; then
      echo "compose checksum mismatch for $compose_url" >&2
      echo "expected: $expected_sha256" >&2
      echo "actual:   $actual_sha256" >&2
      exit 1
    fi

    ${pkgs.coreutils}/bin/mkdir -p "$release_dir"
    ${pkgs.coreutils}/bin/install -m 0644 "$tmp_compose" "$compose_file"
    ${pkgs.coreutils}/bin/cp "$compose_file" "${currentComposeFile}"

    rm -f "$runtime_env"
    printf 'TAG=%s\n' "$tag" > "$runtime_env"
    ${imageEnvScript}

    compose_args=(
      --project-name ${lib.escapeShellArg name}
      --env-file ${lib.escapeShellArg envFile}
      --env-file ${lib.escapeShellArg runtimeEnvFile}
      -f "$compose_file"
    )

    ${pkgs.docker-compose}/bin/docker-compose "''${compose_args[@]}" pull
    ${pkgs.docker-compose}/bin/docker-compose "''${compose_args[@]}" up -d postgres
    ${pkgs.docker-compose}/bin/docker-compose "''${compose_args[@]}" run --rm migrate
    ${pkgs.docker-compose}/bin/docker-compose "''${compose_args[@]}" up -d --no-build --remove-orphans

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

    if [ -f "${currentComposeFile}" ] && [ -f "${runtimeEnvFile}" ]; then
      ${pkgs.docker-compose}/bin/docker-compose \
        --project-name ${lib.escapeShellArg name} \
        --env-file ${lib.escapeShellArg envFile} \
        --env-file ${lib.escapeShellArg runtimeEnvFile} \
        -f ${lib.escapeShellArg currentComposeFile} \
        up -d --no-build --remove-orphans
    fi
  '';

  stopScript = pkgs.writeShellScript "${name}-compose-stop" ''
    set -euo pipefail

    if [ -f "${currentComposeFile}" ] && [ -f "${runtimeEnvFile}" ]; then
      ${pkgs.docker-compose}/bin/docker-compose \
        --project-name ${lib.escapeShellArg name} \
        --env-file ${lib.escapeShellArg envFile} \
        --env-file ${lib.escapeShellArg runtimeEnvFile} \
        -f ${lib.escapeShellArg currentComposeFile} \
        stop
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
      ExecStop = stopScript;
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

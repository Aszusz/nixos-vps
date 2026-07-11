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

  validateCompose = pkgs.writeText "${name}-validate-compose.py" ''
    import os
    import sys
    import yaml

    app_dir = os.path.realpath(sys.argv[1])
    compose_path = sys.argv[2]
    denied_service_keys = {
      "cap_add",
      "devices",
      "ipc",
      "pid",
      "privileged",
      "security_opt",
    }

    def fail(message):
      print(f"compose policy violation: {message}", file=sys.stderr)
      sys.exit(1)

    def is_under_app_dir(path):
      real_path = os.path.realpath(path)
      return real_path == app_dir or real_path.startswith(app_dir + os.sep)

    def check_volume(service_name, volume):
      if isinstance(volume, str):
        if "/var/run/docker.sock" in volume or "/run/docker.sock" in volume:
          fail(f"service {service_name} mounts the Docker socket")
        source = volume.split(":", 1)[0]
        if source.startswith("/") and not is_under_app_dir(source):
          fail(f"service {service_name} bind-mounts {source} outside {app_dir}")
      elif isinstance(volume, dict):
        source = volume.get("source") or volume.get("src")
        target = volume.get("target") or volume.get("dst") or volume.get("destination")
        if source and (source == "/var/run/docker.sock" or source == "/run/docker.sock"):
          fail(f"service {service_name} mounts the Docker socket")
        if target and (target == "/var/run/docker.sock" or target == "/run/docker.sock"):
          fail(f"service {service_name} mounts the Docker socket")
        if volume.get("type") == "bind" and source and source.startswith("/") and not is_under_app_dir(source):
          fail(f"service {service_name} bind-mounts {source} outside {app_dir}")

    def check_port(service_name, port):
      if isinstance(port, int):
        fail(f"service {service_name} publishes public port {port}")
      if isinstance(port, str):
        if "$" in port:
          return
        parts = port.split(":")
        if len(parts) == 1:
          fail(f"service {service_name} publishes public port {port}")
        if len(parts) == 2:
          fail(f"service {service_name} publishes public port {port}; bind to 127.0.0.1")
        if parts[0] not in ("127.0.0.1", "localhost"):
          fail(f"service {service_name} publishes port {port} outside loopback")
      elif isinstance(port, dict):
        host_ip = str(port.get("host_ip", ""))
        if "$" in host_ip:
          return
        if host_ip not in ("127.0.0.1", "localhost"):
          fail(f"service {service_name} publishes a port outside loopback")

    with open(compose_path) as file:
      compose = yaml.safe_load(file) or {}

    services = compose.get("services")
    if not isinstance(services, dict) or not services:
      fail("compose file must define services")

    for service_name, service in services.items():
      if not isinstance(service, dict):
        fail(f"service {service_name} must be an object")
      denied = denied_service_keys.intersection(service.keys())
      if denied:
        fail(f"service {service_name} uses denied keys: {', '.join(sorted(denied))}")
      if service.get("network_mode") == "host":
        fail(f"service {service_name} uses host networking")
      for volume in service.get("volumes", []) or []:
        check_volume(service_name, volume)
      for port in service.get("ports", []) or []:
        check_port(service_name, port)
  '';

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

    ${pythonWithYaml}/bin/python ${validateCompose} ${lib.escapeShellArg appDir} "$tmp_compose"

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

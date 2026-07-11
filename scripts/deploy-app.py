import json
import os
import subprocess
import sys
import time


def run(args, stdin_path=None):
    if stdin_path:
        with open(stdin_path, "rb") as stdin:
            subprocess.run(args, check=True, stdin=stdin)
    else:
        subprocess.run(args, check=True)


def required_env(name):
    value = os.environ.get(name)
    if not value:
        raise SystemExit(f"{name} is required")
    return value


def load_config():
    if len(sys.argv) != 3:
        print("usage: deploy-app.py <app-config-json> <tag>", file=sys.stderr)
        sys.exit(2)

    with open(sys.argv[1]) as file:
        return json.load(file), sys.argv[2]


def podman(config, args, stdin_path=None):
    run([config.get("podman", "podman"), *args], stdin_path=stdin_path)


def systemctl(config, args):
    run([config.get("systemctl", "systemctl"), *args])


def curl(config, args):
    run([config.get("curl", "curl"), *args])


def main():
    config, tag = load_config()
    name = config["name"]
    app_env = config["appEnv"]
    images = config["images"]
    local_images = config["localImages"]

    lock_fd = os.open(f"/run/{name}-deploy.lock", os.O_CREAT | os.O_WRONLY, 0o600)
    try:
        import fcntl

        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise SystemExit("deploy already running")

    podman(
        config,
        [
            "login",
            "ghcr.io",
            "--username",
            required_env("GHCR_USERNAME"),
            "--password-stdin",
        ],
        stdin_path=required_env("GHCR_TOKEN_FILE"),
    )

    for image_name, image in images.items():
        remote_ref = f"{image}:{tag}"
        podman(config, ["pull", remote_ref])
        podman(config, ["tag", remote_ref, local_images[image_name]])

    migration = config.get("migration")
    if migration:
        podman(config, [
            "run",
            "--rm",
            "--network=host",
            "--env-file",
            app_env,
            local_images[migration["image"]],
            *migration["command"],
        ])

    systemctl(config, ["restart", *config["restartServices"]])

    health_url = config["healthUrl"]
    for attempt in range(30):
        try:
            curl(config, ["-fsS", health_url])
            return
        except subprocess.CalledProcessError:
            if attempt == 29:
                raise
            time.sleep(1)

if __name__ == "__main__":
    main()

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time


def env(name):
    value = os.environ.get(name)
    if not value:
        print(f"missing environment variable: {name}", file=sys.stderr)
        sys.exit(2)
    return value


def run(args, **kwargs):
    subprocess.run(args, check=True, **kwargs)


def sha256sum(path):
    result = subprocess.run(
        [env("SHA256SUM"), path],
        check=True,
        text=True,
        capture_output=True,
    )
    return result.stdout.split()[0]


def docker_compose(compose_args, command):
    run([env("DOCKER_COMPOSE"), *compose_args, *command])


def main():
    if len(sys.argv) != 2:
        print("usage: compose-deploy.py <request-id>", file=sys.stderr)
        sys.exit(2)

    request_id = sys.argv[1]
    if not request_id or any(character not in "0123456789abcdef" for character in request_id):
        print("invalid request id", file=sys.stderr)
        sys.exit(2)

    app_name = env("APP_NAME")
    repo = env("APP_REPO")
    app_dir = env("APP_DIR")
    request_dir = env("REQUEST_DIR")
    env_file = env("APP_ENV_FILE")
    runtime_env = env("RUNTIME_ENV_FILE")
    current_compose_file = env("CURRENT_COMPOSE_FILE")
    releases_dir = env("RELEASES_DIR")
    api_port = env("API_PORT")
    health_path = env("HEALTH_PATH")

    request_file = os.path.join(request_dir, f"{request_id}.json")
    if not os.path.isfile(request_file):
        print(f"missing deploy request: {request_file}", file=sys.stderr)
        sys.exit(2)

    with open(request_file) as file:
        request = json.load(file)

    tag = request["tag"]
    commit = request["commit"]
    compose_path = request["composePath"]
    expected_sha256 = request["composeSha256"]
    images = request["images"]
    release_dir = os.path.join(releases_dir, commit)
    compose_file = os.path.join(release_dir, "docker-compose.yml")
    compose_url = f"https://raw.githubusercontent.com/{repo}/{commit}/{compose_path}"

    lock_file = f"/run/{app_name}-deploy.lock"
    with open(lock_file, "w") as lock:
        run([env("FLOCK"), "-n", str(lock.fileno())], pass_fds=(lock.fileno(),))

        with open(env("GHCR_TOKEN_FILE")) as token:
            run(
                [
                    env("DOCKER"),
                    "login",
                    "ghcr.io",
                    "--username",
                    env("GHCR_USERNAME"),
                    "--password-stdin",
                ],
                stdin=token,
            )

        fd, tmp_compose = tempfile.mkstemp()
        os.close(fd)
        try:
            run([env("CURL"), "-fsSL", compose_url, "-o", tmp_compose])

            actual_sha256 = sha256sum(tmp_compose)
            if actual_sha256 != expected_sha256:
                print(f"compose checksum mismatch for {compose_url}", file=sys.stderr)
                print(f"expected: {expected_sha256}", file=sys.stderr)
                print(f"actual:   {actual_sha256}", file=sys.stderr)
                sys.exit(1)

            run([env("PYTHON_WITH_YAML"), env("VALIDATE_COMPOSE"), app_dir, tmp_compose])

            os.makedirs(release_dir, exist_ok=True)
            shutil.copyfile(tmp_compose, compose_file)
            shutil.copyfile(compose_file, current_compose_file)
        finally:
            try:
                os.unlink(tmp_compose)
            except FileNotFoundError:
                pass

        with open(runtime_env, "w") as file:
            file.write(f"TAG={tag}\n")
            for image_name, image_ref in images.items():
                file.write(f"{image_name}={image_ref}\n")

        compose_args = [
            "--project-name",
            app_name,
            "--env-file",
            env_file,
            "--env-file",
            runtime_env,
            "-f",
            compose_file,
        ]

        docker_compose(compose_args, ["pull"])
        docker_compose(compose_args, ["up", "-d", "postgres"])
        docker_compose(compose_args, ["run", "--rm", "migrate"])
        docker_compose(compose_args, ["up", "-d", "--no-build", "--remove-orphans"])

        health_url = f"http://127.0.0.1:{api_port}{health_path}"
        for _attempt in range(30):
            result = subprocess.run([env("CURL"), "-fsS", health_url], stdout=subprocess.DEVNULL)
            if result.returncode == 0:
                return
            time.sleep(1)

        run([env("CURL"), "-fsS", health_url], stdout=subprocess.DEVNULL)


if __name__ == "__main__":
    main()

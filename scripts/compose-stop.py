import os
import subprocess
import sys


def env(name):
    value = os.environ.get(name)
    if not value:
        print(f"missing environment variable: {name}", file=sys.stderr)
        sys.exit(2)
    return value


def main():
    current_compose_file = env("CURRENT_COMPOSE_FILE")
    runtime_env_file = env("RUNTIME_ENV_FILE")
    if not os.path.isfile(current_compose_file) or not os.path.isfile(runtime_env_file):
        return

    subprocess.run(
        [
            env("DOCKER_COMPOSE"),
            "--project-name",
            env("APP_NAME"),
            "--env-file",
            env("APP_ENV_FILE"),
            "--env-file",
            runtime_env_file,
            "-f",
            current_compose_file,
            "stop",
        ],
        check=True,
    )


if __name__ == "__main__":
    main()

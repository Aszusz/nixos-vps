import json
import subprocess
import sys


def load_config():
    if len(sys.argv) != 2:
        print("usage: start-app.py <app-config-json>", file=sys.stderr)
        sys.exit(2)

    with open(sys.argv[1]) as file:
        return json.load(file)


def run(args):
    subprocess.run(args, check=True)


def main():
    config = load_config()
    podman = config.get("podman", "podman")
    systemctl = config.get("systemctl", "systemctl")

    for image in config["localImages"].values():
        result = subprocess.run([podman, "image", "exists", image])
        if result.returncode != 0:
            return

    run([systemctl, "start", *config["restartServices"]])


if __name__ == "__main__":
    main()

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

#!/usr/bin/env python3
"""Render docker-compose.yml from config.yml."""

from __future__ import annotations

from copy import deepcopy
import os
import re
import sys
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError as exc:  # pragma: no cover - startup guard
    print("render: missing dependency 'yaml' (PyYAML).", file=sys.stderr)
    print("Install it with your package manager (python3-yaml / py3-yaml / python-yaml).", file=sys.stderr)
    raise SystemExit(1) from exc

from scripts.shared.config_helpers import BOOLEAN_STATES, as_text, nested_map
from scripts.shared.config_loader import load_merged_config

HEADER = "\n".join(
    [
        "# AUTO-GENERATED from config.yml by render.py. DO NOT EDIT.",
        "# Re-run python3 ./docker/render.py (or just ./start.sh) after changing the runner inventory.",
    ]
)
class ComposeDumper(yaml.SafeDumper):
    pass


def _indent_sequences_as_mappings(dumper: ComposeDumper, flow: bool = False, indentless: bool = False) -> Any:
    return super(ComposeDumper, dumper).increase_indent(flow, False)


ComposeDumper.increase_indent = _indent_sequences_as_mappings


def make_compose_slug(value: str) -> str:
    lowered = value.lower()
    compact = re.sub(r"[^a-z0-9]+", "-", lowered)
    return re.sub(r"(^-+)|(-+$)", "", compact)


def parse_mode(argv: list[str]) -> str:
    if not argv:
        return "write"
    if argv[0] in {"--check", "--stdout"} and len(argv) == 1:
        return argv[0]
    bad = argv[1] if argv and argv[0] in {"--check", "--stdout"} and len(argv) > 1 else argv[0]
    print(f"render: unknown argument: {bad}", file=sys.stderr)
    raise SystemExit(2)


def load_base_compose(base_file: Path) -> tuple[dict[str, Any], dict[str, Any]]:
    if not base_file.is_file():
        raise ValueError(f"render: base compose file missing: {base_file}")
    with base_file.open("r", encoding="utf-8") as handle:
        base = yaml.safe_load(handle) or {}
    if not isinstance(base, dict):
        raise ValueError(f"render: base compose file must contain a top-level object: {base_file}")
    runner_base = base.pop("x-runner-base", {})
    if not isinstance(runner_base, dict):
        runner_base = {}
    for key in ("services", "volumes", "networks"):
        value = base.get(key)
        base[key] = value if isinstance(value, dict) else {}
    return base, runner_base


def collect_image_flags(config: dict[str, object], env_default_image: str) -> tuple[list[str], set[str], set[str]]:
    defaults = config.get("defaults") if isinstance(config.get("defaults"), dict) else {}
    default_image = str(defaults.get("image") or env_default_image or "debian:stable-slim").lower()
    defaults_docker_enabled = BOOLEAN_STATES.get(as_text(nested_map(defaults, "docker").get("enabled", False)).strip().lower(), False)
    defaults_ps_enabled = BOOLEAN_STATES.get(as_text(nested_map(defaults, "persistent_storage").get("enabled", False)).strip().lower(), False)

    runners_obj = config.get("runners")
    runners = runners_obj if isinstance(runners_obj, list) else []

    images: list[str] = []
    docker_images: set[str] = set()
    ps_images: set[str] = set()
    seen: set[str] = set()

    for runner in runners:
        if not isinstance(runner, dict):
            continue
        image = str(runner.get("image") or default_image).strip().lower() or default_image
        if image not in seen:
            seen.add(image)
            images.append(image)
        docker_enabled = BOOLEAN_STATES.get(as_text(nested_map(runner, "docker").get("enabled", defaults_docker_enabled)).strip().lower(), False)
        ps_enabled = BOOLEAN_STATES.get(as_text(nested_map(runner, "persistent_storage").get("enabled", defaults_ps_enabled)).strip().lower(), False)
        if docker_enabled:
            docker_images.add(image)
        if ps_enabled:
            ps_images.add(image)

    if not images:
        images = [default_image]

    return images, docker_images, ps_images


def base_runner_volumes(runner_base: dict[str, Any]) -> list[str]:
    volumes = runner_base.get("volumes")
    return list(volumes) if isinstance(volumes, list) else []


def build_runner_service(runner_base: dict[str, Any], image: str, tag: str, runner_version: str) -> dict[str, Any]:
    service = deepcopy(runner_base)
    service.update(
        {
            "build": {
                "context": "..",
                "dockerfile": "docker/Dockerfile",
                "args": {
                    "RUNNER_VERSION": runner_version,
                    "BASE_IMAGE": image,
                    "RUNNER_IMAGE_FLAVOR": image,
                },
            },
            "image": f"github-multirunner:{tag}",
            "container_name": f"github-multirunner-{tag}",
            "hostname": f"github-multirunner-{tag}",
            "environment": {
                "GITHUB_PAT": "${GITHUB_PAT:-}",
                "RUNNER_IMAGE_FLAVOR": image,
                "HOST_HOSTNAME": "${HOST_HOSTNAME:-}",
            },
        }
    )
    return service


def apply_docker_runner_bits(service: dict[str, Any], tag: str, ps_enabled: bool, runner_base: dict[str, Any]) -> None:
    environment = service.setdefault("environment", {})
    environment.update(
        {
            "DOCKER_HOST": f"tcp://dind-{tag}:2376",
            "DOCKER_TLS_VERIFY": "1",
            "DOCKER_CERT_PATH": "/certs/client",
        }
    )
    service["depends_on"] = {f"dind-{tag}": {"condition": "service_healthy"}}
    service["networks"] = ["default", f"dind-{tag}"]
    service["cap_drop"] = ["NET_RAW"]
    service["security_opt"] = ["no-new-privileges=false"]
    volumes = base_runner_volumes(runner_base)
    volumes.extend([
        f"dind-{tag}-certs:/certs:ro",
        f"runner-workspace-{tag}:/home/github-runner",
    ])
    if ps_enabled:
        volumes.append(f"runner-storage-{tag}:/runner-storage")
    service["volumes"] = volumes
    service["tmpfs"] = []


def apply_persistent_runner_bits(service: dict[str, Any], tag: str, runner_base: dict[str, Any]) -> None:
    volumes = base_runner_volumes(runner_base)
    volumes.append(f"runner-storage-{tag}:/runner-storage")
    service["volumes"] = volumes


def build_dind_service(tag: str, ps_enabled: bool) -> dict[str, Any]:
    volumes = [
        f"dind-{tag}-certs:/certs",
        f"dind-{tag}-data:/var/lib/docker",
        f"runner-workspace-{tag}:/home/github-runner",
    ]
    if ps_enabled:
        volumes.append(f"runner-storage-{tag}:/runner-storage")
    return {
        "image": "docker:dind",
        "container_name": f"github-multirunner-dind-{tag}",
        "hostname": f"dind-{tag}",
        "restart": "unless-stopped",
        "privileged": True,
        "environment": {"DOCKER_TLS_CERTDIR": "/certs"},
        "volumes": volumes,
        "networks": [f"dind-{tag}"],
        # Cap DinD daemon logs so they don't fill the host disk over time.
        "logging": {
            "driver": "json-file",
            "options": {"max-size": "10m", "max-file": "3"},
        },
        "healthcheck": {
            "test": ["CMD", "docker", "-H", "unix:///var/run/docker.sock", "version"],
            "interval": "5s",
            "timeout": "3s",
            "retries": 30,
            "start_period": "10s",
        },
    }


def patch_compose(base_compose: dict[str, Any], runner_base: dict[str, Any], images: list[str], docker_images: set[str], ps_images: set[str], runner_version: str) -> dict[str, Any]:
    compose = deepcopy(base_compose)
    services = compose.setdefault("services", {})
    volumes = compose.setdefault("volumes", {})
    networks = compose.setdefault("networks", {})

    services.clear()
    for key in [name for name in volumes if name != "runner-state"]:
        del volumes[key]
    networks.clear()

    for image in images:
        tag = make_compose_slug(image)
        docker_enabled = image in docker_images
        ps_enabled = image in ps_images

        runner_service = build_runner_service(runner_base, image, tag, runner_version)
        services[f"runners-{tag}"] = runner_service
        if docker_enabled:
            apply_docker_runner_bits(runner_service, tag, ps_enabled, runner_base)
            services[f"dind-{tag}"] = build_dind_service(tag, ps_enabled)
            volumes[f"dind-{tag}-certs"] = {}
            volumes[f"dind-{tag}-data"] = {}
            volumes[f"runner-workspace-{tag}"] = {}
            networks[f"dind-{tag}"] = {"driver": "bridge"}
        elif ps_enabled:
            apply_persistent_runner_bits(runner_service, tag, runner_base)

        if ps_enabled:
            volumes[f"runner-storage-{tag}"] = {}

    return compose


def render_compose(compose: dict[str, Any]) -> str:
    body = yaml.dump(
        compose,
        Dumper=ComposeDumper,
        default_flow_style=False,
        sort_keys=False,
        indent=2,
        width=1000,
    ).rstrip()
    return f"{HEADER}\n\n{body}"


def main() -> int:
    mode = parse_mode(sys.argv[1:])

    script_dir = Path(__file__).resolve().parent
    config_file = Path(os.environ.get("CONFIG_FILE", "../config.yml"))
    if not config_file.is_absolute():
        config_file = (script_dir / config_file).resolve()

    output_file = Path(os.environ.get("OUTPUT_FILE", "docker-compose.yml"))
    if not output_file.is_absolute():
        output_file = (script_dir / output_file).resolve()

    base_file = Path(os.environ.get("BASE_COMPOSE_FILE", "docker-compose.base.yml"))
    if not base_file.is_absolute():
        base_file = (script_dir / base_file).resolve()

    runner_version = os.environ.get("RUNNER_VERSION", "2.334.0")
    default_image = os.environ.get("DEFAULT_IMAGE", "debian:stable-slim")

    if not config_file.is_file():
        print(f"render: {config_file} does not exist", file=sys.stderr)
        return 1

    try:
        merged = load_merged_config(str(config_file), str(script_dir / "scripts" / "parse-config.py"))
        base_compose, runner_base = load_base_compose(base_file)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    images, docker_images, ps_images = collect_image_flags(merged, default_image)
    compose = patch_compose(base_compose, runner_base, images, docker_images, ps_images, runner_version)
    rendered = render_compose(compose)

    if mode == "--stdout":
        print(rendered)
        return 0

    if mode == "--check":
        current = output_file.read_text(encoding="utf-8") if output_file.exists() else ""
        if current.strip() != rendered.strip():
            print(f"render: {output_file} is out of date; re-run python3 ./docker/render.py", file=sys.stderr)
            return 1
        return 0

    output_file.write_text(f"{rendered}\n", encoding="utf-8")
    sfx = "" if len(images) == 1 else "s"
    print(f"render: wrote {output_file} ({len(images)} service{sfx})")
    for image in images:
        print(f"  - runners-{make_compose_slug(image)}  ({image})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Parse config and launch runner pools inside the container."""

from __future__ import annotations

import os
import platform
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from shared.github_api import delete_runner
from shared.runner_records import RunnerRecord, load_runner_records
from shared.runner_store_lib import list_records, remove_record
from shared.runtime_helpers import derive_workdir, merge_auto_labels, resolve_within, sanitize_component


def log(message: str) -> None:
    print(message, flush=True)


def env_path(name: str, default: str) -> Path:
    return Path(os.environ.get(name, default))


def stage_template(source_dir: Path, target_dir: Path) -> None:
    if target_dir.is_dir() and any(target_dir.iterdir()):
        return
    log(f"entrypoint: staging template at {target_dir}")
    target_dir.mkdir(parents=True, exist_ok=True)
    if subprocess.run(["cp", "-a", f"{source_dir}/.", str(target_dir)], check=False).returncode != 0:
        print(f"entrypoint: failed to stage template from {source_dir} into {target_dir}", file=sys.stderr)
        raise SystemExit(1)


def title_storage_component(title: str) -> str:
    component = sanitize_component(title).strip("._-")
    return component or "runner"


def persistent_storage_dir(root: Path, record: RunnerRecord) -> Path:
    relative = "shared"
    if record.persistent_storage_scope == "title":
        relative = f"title/{title_storage_component(record.title)}"
    return resolve_within(root, relative)


def matching_runners(records: list[RunnerRecord], flavor: str) -> list[RunnerRecord]:
    return [record for record in records if record.image == flavor]


def sweep_stale_runners(records: list[RunnerRecord], flavor: str) -> None:
    repo_pat = {record.repo_url: record.pat for record in records if record.pat}
    stale_total = 0
    stale_cleaned = 0
    for record in list_records():
        record_flavor = str(record.get("flavor") or "")
        if record_flavor and record_flavor != flavor:
            continue
        stale_total += 1
        repo_url = str(record.get("repo_url") or "")
        runner_id = str(record.get("id") or "")
        runner_name = str(record.get("name") or "")
        pat = repo_pat.get(repo_url, "")
        if not pat:
            print(f"entrypoint: no PAT in config for {repo_url}, skipping stale runner {runner_name} (id={runner_id})", file=sys.stderr)
            continue
        _, response = delete_runner(repo_url, pat, runner_id)
        if response.status in {204, 404}:
            stale_cleaned += 1
            remove_record(runner_id)
    if stale_total:
        log(f"entrypoint[{flavor}]: cleaned {stale_cleaned}/{stale_total} stale runner(s) from previous run")


def ensure_docker_sidecar(records: list[RunnerRecord]) -> None:
    if not any(record.docker_enabled for record in records):
        return
    docker_host = os.environ.get("DOCKER_HOST", "")
    if not docker_host:
        print("entrypoint: docker.enabled=true but DOCKER_HOST is not set.", file=sys.stderr)
        print("entrypoint: re-run python3 ./docker/render.py + ./start.sh so the compose file is regenerated with the DinD sidecar.", file=sys.stderr)
        raise SystemExit(1)
    wait_for_docker_certs()
    install_docker_cli_if_missing()
    wait_for_dind_daemon(docker_host)


def wait_for_docker_certs() -> None:
    cert_path = os.environ.get("DOCKER_CERT_PATH", "")
    if os.environ.get("DOCKER_TLS_VERIFY") != "1" or not cert_path:
        return
    log(f"entrypoint: waiting for DinD TLS client certs at {cert_path}")
    for _ in range(60):
        if all((Path(cert_path) / name).is_file() for name in ("ca.pem", "cert.pem", "key.pem")):
            return
        time.sleep(1)
    print(f"entrypoint: TLS client certs did not appear at {cert_path} within 60s", file=sys.stderr)
    raise SystemExit(1)


def install_docker_cli_if_missing() -> None:
    if shutil.which("docker") is not None:
        return
    version = os.environ.get("DOCKER_CLI_VERSION", "27.3.1")
    arch_map = {"x86_64": "x86_64", "aarch64": "aarch64", "armv7l": "armhf"}
    machine = platform.machine()
    if machine not in arch_map:
        print(f"entrypoint: unsupported arch for docker static binary: {machine}", file=sys.stderr)
        raise SystemExit(1)
    url = f"https://download.docker.com/linux/static/stable/{arch_map[machine]}/docker-{version}.tgz"
    log(f"entrypoint: installing docker CLI {version} ({arch_map[machine]}) from {url}")
    tmp_dir = Path(tempfile.mkdtemp())
    try:
        if subprocess.run(["curl", "-fsSL", "-o", str(tmp_dir / "docker.tgz"), url], check=False).returncode != 0:
            print("entrypoint: failed to download docker CLI tarball", file=sys.stderr)
            raise SystemExit(1)
        if subprocess.run(["tar", "-xzf", str(tmp_dir / "docker.tgz"), "-C", str(tmp_dir)], check=False).returncode != 0:
            raise SystemExit(1)
        docker_bin = tmp_dir / "docker" / "docker"
        if docker_bin.is_file():
            if subprocess.run(["sudo", "-n", "install", "-m", "0755", str(docker_bin), "/usr/local/bin/docker"], check=False).returncode != 0:
                print("entrypoint: failed to install docker CLI into /usr/local/bin", file=sys.stderr)
                raise SystemExit(1)
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


def wait_for_dind_daemon(docker_host: str) -> None:
    log(f"entrypoint: waiting for DinD daemon at {docker_host}")
    for _ in range(60):
        if subprocess.run(["docker", "version"], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
            return
        time.sleep(1)
    print(f"entrypoint: DinD sidecar at {docker_host} did not become ready in 60s.", file=sys.stderr)
    raise SystemExit(1)


def install_additional_packages(records: list[RunnerRecord]) -> None:
    done_file = env_path("PKGS_DONE_FILE", "/var/lib/github-runners/packages.done")
    done_file.parent.mkdir(parents=True, exist_ok=True)
    done_file.touch(exist_ok=True)
    completed = {line.strip() for line in done_file.read_text(encoding="utf-8", errors="replace").splitlines() if line.strip()}
    packages: list[str] = []
    seen: set[str] = set()
    for record in records:
        for package in record.additional_packages.split():
            if package and package not in seen and package not in completed:
                seen.add(package)
                packages.append(package)
    if not packages:
        return
    log(f"entrypoint: installing additional_packages: {' '.join(packages)}")
    proc = subprocess.run(["sudo", "-n", "python3", "/usr/local/bin/install-packages.py", *packages], check=False)
    if proc.returncode != 0:
        print("entrypoint: additional_packages install failed", file=sys.stderr)
        raise SystemExit(1)
    with done_file.open("a", encoding="utf-8") as handle:
        for package in packages:
            handle.write(f"{package}\n")


def run_startup_scripts(records: list[RunnerRecord]) -> None:
    startup_dir = env_path("STARTUP_SCRIPTS_DIR", "/etc/github-runners/startup")
    done_file = env_path("STARTUP_DONE_FILE", "/var/lib/github-runners/startup.done")
    done_file.parent.mkdir(parents=True, exist_ok=True)
    done_file.touch(exist_ok=True)
    completed = {line.strip() for line in done_file.read_text(encoding="utf-8", errors="replace").splitlines() if line.strip()}
    seen: set[str] = set()
    for record in records:
        script_name = record.startup_script.strip()
        if not script_name or script_name in seen:
            continue
        seen.add(script_name)
        try:
            script_path = resolve_within(startup_dir, script_name)
        except ValueError:
            print(f"entrypoint: startup_script escapes startup-scripts/: {script_name}", file=sys.stderr)
            raise SystemExit(1)
        if not script_path.is_file():
            print(f"entrypoint: startup_script not found: {script_path}", file=sys.stderr)
            print("entrypoint: create it under ./startup-scripts/ on the host", file=sys.stderr)
            raise SystemExit(1)
        if script_name in completed:
            log(f"entrypoint: startup_script {script_name} already applied, skipping")
            continue
        log(f"entrypoint: running startup_script {script_name}")
        if subprocess.run(["sudo", "-n", "bash", str(script_path)], check=False).returncode != 0:
            print(f"entrypoint: startup_script {script_name} failed", file=sys.stderr)
            raise SystemExit(1)
        with done_file.open("a", encoding="utf-8") as handle:
            handle.write(f"{script_name}\n")


def arch_label() -> str:
    machine = platform.machine()
    mapping = {"x86_64": "x64", "aarch64": "arm64", "arm64": "arm64", "armv7l": "arm", "armv6l": "arm", "i386": "x86", "i686": "x86"}
    return mapping.get(machine, machine)


def prepare_persistent_storage(records: list[RunnerRecord]) -> str:
    root = env_path("PERSISTENT_STORAGE_ROOT", "/runner-storage")
    if not any(record.persistent_storage_enabled for record in records):
        return str(root)
    if not root.is_dir():
        print(f"entrypoint: persistent_storage enabled but {root} is missing.", file=sys.stderr)
        print("entrypoint: re-run python3 ./docker/render.py + ./start.sh so the compose file is regenerated with the runner-storage volume.", file=sys.stderr)
        raise SystemExit(1)
    if subprocess.run(["sudo", "-n", "chown", "github-runner:github-runner", str(root)], check=False).returncode != 0:
        print(f"entrypoint: failed to chown persistent storage root {root}", file=sys.stderr)
        raise SystemExit(1)
    if subprocess.run(["sudo", "-n", "chmod", "0755", str(root)], check=False).returncode != 0:
        print(f"entrypoint: failed to chmod persistent storage root {root}", file=sys.stderr)
        raise SystemExit(1)
    for record in records:
        prepare_persistent_dir(root, record)
    return str(root)


def prepare_persistent_dir(root: Path, record: RunnerRecord) -> None:
    if not record.persistent_storage_enabled:
        return
    subdir = persistent_storage_dir(root, record)
    subdir.mkdir(parents=True, exist_ok=True)
    if record.persistent_storage_ttl <= 0:
        return
    cutoff = time.time() - record.persistent_storage_ttl
    for path in sorted(subdir.rglob("*"), reverse=True):
        try:
            if path.stat().st_mtime > cutoff:
                continue
            if path.is_dir():
                path.rmdir()
            else:
                path.unlink()
        except OSError:
            continue


def spawn_pools(records: list[RunnerRecord], runners_base: str, persistent_root: str) -> list[subprocess.Popen[str]]:
    host_label = os.environ.get("HOST_HOSTNAME") or subprocess.run(["hostname"], check=False, stdout=subprocess.PIPE, text=True).stdout.strip()
    architecture = arch_label()
    runners_root = Path(runners_base).resolve()
    persistent_storage_root = Path(persistent_root).resolve()
    procs: list[subprocess.Popen[str]] = []
    for record in records:
        workdir = record.workdir or derive_workdir(record.title, record.repo_url)
        runner_dir = str(resolve_within(runners_root, workdir))
        ps_path = ""
        if record.persistent_storage_enabled:
            ps_path = str(persistent_storage_dir(persistent_storage_root, record))
        labels = merge_auto_labels(
            record.labels,
            [
                ("architecture", architecture),
                ("image", record.image),
                ("host", host_label),
                ("docker", "true" if record.docker_enabled else "false"),
            ],
        )
        env = os.environ.copy()
        env.update(
            {
                "EPHEMERAL": "1" if record.ephemeral else "0",
                "PAT": record.pat,
                "RUNNER_LABELS": labels,
                "RUNNER_GROUP_ID": record.group,
                "IDLE_REGENERATION": str(record.idle_regeneration),
                "WATCHDOG_ENABLED": "1" if record.watchdog_enabled else "0",
                "WATCHDOG_INTERVAL": str(record.watchdog_interval),
                "RUNNER_IMAGE_FLAVOR": record.image,
                "POOL_MIN": str(record.instances_min),
                "POOL_MAX": str(record.instances_max),
                "POOL_HEADROOM": str(record.instances_headroom),
                "PERSISTENT_STORAGE_PATH": ps_path,
                "PERSISTENT_STORAGE_TTL": str(record.persistent_storage_ttl),
            }
        )
        proc = subprocess.Popen(
            ["python3", "/usr/local/bin/pool-manager.py", record.title, record.repo_url, record.token, runner_dir],
            env=env,
            text=True,
        )
        procs.append(proc)
    return procs


def main() -> int:
    config_file = env_path("CONFIG_FILE", "/etc/github-runners/config.yml")
    runners_base = os.environ.get("RUNNERS_BASE", "/home/github-runner")
    state_file = env_path("RUNNER_STATE_FILE", "/var/lib/github-runners/runners.jsonl")
    source_template_dir = env_path("TEMPLATE_DIR", "/opt/actions-runner")
    template_dir = Path(runners_base) / ".template"
    os.environ["RUNNER_STATE_FILE"] = str(state_file)
    os.environ["TEMPLATE_DIR"] = str(template_dir)
    if not config_file.is_file():
        print(f"entrypoint: config file not readable: {config_file}", file=sys.stderr)
        return 1

    stage_template(source_template_dir, template_dir)
    flavor = os.environ.get("RUNNER_IMAGE_FLAVOR", "debian:stable-slim")
    os.environ["RUNNER_IMAGE_FLAVOR"] = flavor
    records = load_runner_records(str(config_file), "/usr/local/bin/parse-config.py")
    matched = matching_runners(records, flavor)
    if not matched:
        log(f"entrypoint[{flavor}]: no runners target this image flavor, idling")
        return idle_forever()

    sweep_stale_runners(matched, flavor)
    # Build a summary of runners being started with their repos
    runner_summary = ", ".join(f"{r.title} ({r.repo_url})" for r in matched)
    log(f"entrypoint[{flavor}]: starting {len(matched)} runner(s): {runner_summary}")
    ensure_docker_sidecar(matched)
    install_additional_packages(matched)
    run_startup_scripts(matched)
    persistent_root = prepare_persistent_storage(matched)
    procs = spawn_pools(matched, runners_base, persistent_root)

    def shutdown(_signum: int, _frame: object) -> None:
        log(f"entrypoint: received shutdown, stopping {len(procs)} runner(s)")
        for proc in procs:
            if proc.poll() is None:
                proc.terminate()
        for proc in procs:
            try:
                proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                proc.kill()
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    wait_for_children(procs)
    return 0


def idle_forever() -> int:
    def idle_stop(_signum: int, _frame: object) -> None:
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, idle_stop)
    signal.signal(signal.SIGINT, idle_stop)
    while True:
        time.sleep(3600)


def wait_for_children(procs: list[subprocess.Popen[str]]) -> None:
    remaining = set(procs)
    while remaining:
        for proc in tuple(remaining):
            if proc.poll() is not None:
                remaining.remove(proc)
        time.sleep(1)


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""In-container runner status probe."""

from __future__ import annotations

import json
import os

from shared.proc_utils import cwd_under, proc_pid_dirs, read_cmdline, read_comm
from shared.runtime_helpers import derive_workdir, singleton_pool


US = "\x1f"


def load_runners(config_file: str) -> list[list[str]]:
    import subprocess

    proc = subprocess.run(
        ["python3", "/usr/local/bin/parse-config.py", config_file],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    if proc.returncode != 0:
        return []
    rows: list[list[str]] = []
    for line in proc.stdout.splitlines():
        if line:
            rows.append(line.split(US))
    return rows


def build_process_index() -> tuple[dict[str, int], list[int], list[int]]:
    sup_by_title: dict[str, int] = {}
    listeners: list[int] = []
    workers: list[int] = []
    for proc_dir in proc_pid_dirs():
        pid = int(proc_dir.name)
        argv = read_cmdline(pid)
        if len(argv) >= 2:
            if argv[0].endswith("start-runner.py"):
                sup_by_title[argv[1]] = pid
            elif len(argv) >= 3 and argv[1].endswith("start-runner.py"):
                sup_by_title[argv[2]] = pid
        comm = read_comm(pid)
        if comm == "Runner.Listener":
            listeners.append(pid)
        elif comm == "Runner.Worker":
            workers.append(pid)
    return sup_by_title, listeners, workers


def any_under(root: str, pids: list[int]) -> bool:
    return any(cwd_under(pid, root) for pid in pids)


def parse_row(row: list[str]) -> dict[str, str]:
    keys = [
        "title",
        "repo_url",
        "token",
        "workdir",
        "ephemeral",
        "pat",
        "labels",
        "group",
        "idle_regen",
        "image",
        "startup_script",
        "add_pkgs",
        "wd_enabled",
        "wd_interval",
        "docker_enabled",
        "instances_min",
        "instances_max",
        "instances_headroom",
        "ps_enabled",
        "ps_ttl",
        "ps_scope",
    ]
    return dict(zip(keys, row, strict=False))


def instance_roster(title: str, base_runner_dir: str, sup_by_title: dict[str, int], min_count: int, max_count: int, headroom: int) -> list[tuple[str, str]]:
    if singleton_pool(min_count, max_count, headroom):
        return [(title, base_runner_dir)]
    out: list[tuple[str, str]] = []
    for instance_title in sorted(sup_by_title):
        if instance_title.startswith(f"{title}-"):
            suffix = instance_title.rsplit("-", 1)[-1]
            out.append((instance_title, f"{base_runner_dir}-{suffix}"))
    return out or [(title, base_runner_dir)]


def emit_runner_status(
    data: dict[str, str],
    runners_base: str,
    sup_by_title: dict[str, int],
    listeners: list[int],
    workers: list[int],
) -> None:
    title = data["title"]
    repo_url = data["repo_url"]
    workdir = data["workdir"] or derive_workdir(title, repo_url)
    base_runner_dir = f"{runners_base}/{workdir}"
    min_count = int(data["instances_min"] or "1")
    max_count = int(data["instances_max"] or data["instances_min"] or "1")
    headroom = int(data["instances_headroom"] or "0")
    for instance_title, runner_dir in instance_roster(title, base_runner_dir, sup_by_title, min_count, max_count, headroom):
        sup_pid = sup_by_title.get(instance_title)
        listener = any_under(runner_dir, listeners)
        worker = any_under(runner_dir, workers)
        print(
            json.dumps(
                {
                    "title": instance_title,
                    "repo_url": repo_url,
                    "workdir": runner_dir,
                    "labels": data["labels"],
                    "ephemeral": data["ephemeral"] == "1",
                    "image": data["image"],
                    "sup_pid": sup_pid,
                    "listener": listener,
                    "worker": worker,
                    "runtime": {
                        "source": "local",
                        "supervisor": sup_pid is not None,
                        "listener": listener,
                        "worker": worker,
                    },
                    "watchdog": data["wd_enabled"] == "1",
                    "idle_regeneration": int(data["idle_regen"] or "0"),
                    "pool": {"min": min_count, "max": max_count, "headroom": headroom},
                },
                separators=(",", ":"),
            )
        )


def main() -> None:
    config_file = os.environ.get("CONFIG_FILE", "/etc/github-runners/config.yml")
    runners_base = os.environ.get("RUNNERS_BASE", "/home/github-runner")
    flavor = os.environ.get("RUNNER_IMAGE_FLAVOR", "")
    if not os.path.isfile(config_file):
        return

    rows = load_runners(config_file)
    sup_by_title, listeners, workers = build_process_index()

    for row in rows:
        data = parse_row(row)
        if flavor and data["image"] != flavor:
            continue
        emit_runner_status(data, runners_base, sup_by_title, listeners, workers)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""In-container runner status probe."""

from __future__ import annotations

import json
import os
from pathlib import Path

from shared.proc_utils import cwd_under, proc_pid_dirs, read_comm
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


def _raw_cmdline(pid: int) -> list[str]:
    """Read /proc/<pid>/cmdline preserving positional empty args.

    proc_utils.read_cmdline filters empty strings which corrupts positional
    indexing when, e.g., a runner is launched with an empty token argument.
    """
    try:
        data = Path(f"/proc/{pid}/cmdline").read_bytes()
    except OSError:
        return []
    parts = data.decode("utf-8", errors="replace").split("\x00")
    # /proc cmdline has a trailing NUL, yielding an empty last element.
    if parts and parts[-1] == "":
        parts.pop()
    return parts


def build_process_index() -> tuple[dict[str, int], dict[str, tuple[str, int]], list[int], list[int]]:
    """Scan /proc once and index supervisors by title and by runner directory.

    Returns:
      sup_by_title: instance-title -> supervisor pid
      sup_by_dir:   runner-directory -> (instance-title, supervisor pid)
      listeners, workers: pids
    """
    sup_by_title: dict[str, int] = {}
    sup_by_dir: dict[str, tuple[str, int]] = {}
    listeners: list[int] = []
    workers: list[int] = []
    for proc_dir in proc_pid_dirs():
        pid = int(proc_dir.name)
        argv = _raw_cmdline(pid)
        title = ""
        directory = ""
        # start-runner.py takes exactly 4 positional args: title, repo_url,
        # token, directory. Depending on interpreter invocation the script
        # path appears at argv[0] or argv[1].
        if len(argv) >= 5 and argv[0].endswith("start-runner.py"):
            title = argv[1]
            directory = argv[4]
        elif len(argv) >= 6 and argv[1].endswith("start-runner.py"):
            title = argv[2]
            directory = argv[5]
        if title:
            sup_by_title[title] = pid
            if directory:
                sup_by_dir[directory] = (title, pid)
        comm = read_comm(pid)
        if comm == "Runner.Listener":
            listeners.append(pid)
        elif comm == "Runner.Worker":
            workers.append(pid)
    return sup_by_title, sup_by_dir, listeners, workers


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


def instance_roster(base_runner_dir: str, fallback_title: str, sup_by_dir: dict[str, tuple[str, int]], min_count: int, max_count: int, headroom: int) -> list[tuple[str, str, int | None]]:
    """Enumerate instance entries belonging to one pool identified by its base dir.

    Matches supervisors whose runner directory is either exactly
    ``base_runner_dir`` (singleton pool) or ``{base_runner_dir}-NN`` (multi).
    Returns (instance_title, runner_dir, sup_pid). When no supervisors are
    found, emits a single placeholder row so callers still render the pool.
    """
    out: list[tuple[str, str, int | None]] = []
    if singleton_pool(min_count, max_count, headroom):
        info = sup_by_dir.get(base_runner_dir)
        if info is not None:
            out.append((info[0], base_runner_dir, info[1]))
        else:
            out.append((fallback_title, base_runner_dir, None))
        return out
    prefix = f"{base_runner_dir}-"
    for directory in sorted(sup_by_dir):
        if directory.startswith(prefix):
            title, pid = sup_by_dir[directory]
            out.append((title, directory, pid))
    if not out:
        out.append((fallback_title, base_runner_dir, None))
    return out


def emit_runner_status(
    data: dict[str, str],
    slot: str,
    runners_base: str,
    sup_by_dir: dict[str, tuple[str, int]],
    listeners: list[int],
    workers: list[int],
) -> None:
    title = data["title"]
    repo_url = data["repo_url"]
    workdir = data["workdir"] or derive_workdir(title, repo_url)
    if slot:
        workdir = f"{workdir}{slot}"
    base_runner_dir = f"{runners_base}/{workdir}"
    fallback_title = f"{title}{slot}"
    min_count = int(data["instances_min"] or "1")
    max_count = int(data["instances_max"] or data["instances_min"] or "1")
    headroom = int(data["instances_headroom"] or "0")
    for instance_title, runner_dir, sup_pid in instance_roster(base_runner_dir, fallback_title, sup_by_dir, min_count, max_count, headroom):
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


def assign_pool_slots(rows: list[dict[str, str]]) -> list[str]:
    """Mirror entrypoint.assign_pool_slots for the config-row shape used here."""
    counts: dict[str, int] = {}
    for row in rows:
        counts[row["title"]] = counts.get(row["title"], 0) + 1
    running: dict[str, int] = {}
    slots: list[str] = []
    for row in rows:
        if counts[row["title"]] <= 1:
            slots.append("")
            continue
        idx = running.get(row["title"], 0) + 1
        running[row["title"]] = idx
        slots.append(f"-p{idx:02d}")
    return slots


def main() -> None:
    config_file = os.environ.get("CONFIG_FILE", "/etc/github-runners/config.yml")
    runners_base = os.environ.get("RUNNERS_BASE", "/home/github-runner")
    flavor = os.environ.get("RUNNER_IMAGE_FLAVOR", "")
    if not os.path.isfile(config_file):
        return

    rows = load_runners(config_file)
    _, sup_by_dir, listeners, workers = build_process_index()

    parsed = [parse_row(row) for row in rows]
    matched = [data for data in parsed if not flavor or data["image"] == flavor]
    slots = assign_pool_slots(matched)
    for data, slot in zip(matched, slots, strict=True):
        emit_runner_status(data, slot, runners_base, sup_by_dir, listeners, workers)


if __name__ == "__main__":
    main()

"""Shared JSONL-backed runner store operations."""

from __future__ import annotations

import fcntl
import json
import os
import tempfile
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class RunnerStorePaths:
    store_file: Path
    lock_file: Path


def resolve_paths(store_file: str | None = None) -> RunnerStorePaths:
    target = Path(store_file or os.environ.get("RUNNER_STATE_FILE", "/var/lib/github-runners/runners.jsonl"))
    return RunnerStorePaths(store_file=target, lock_file=target.with_suffix(target.suffix + ".lock"))


def ensure_store(paths: RunnerStorePaths) -> None:
    paths.store_file.parent.mkdir(parents=True, exist_ok=True)
    paths.store_file.touch(exist_ok=True)
    paths.lock_file.touch(exist_ok=True)


def _load_records(paths: RunnerStorePaths) -> list[dict[str, object]]:
    out: list[dict[str, object]] = []
    for line in paths.store_file.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line.strip():
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            out.append(value)
    return out


def _write_records(paths: RunnerStorePaths, records: list[dict[str, object]]) -> None:
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False, dir=str(paths.store_file.parent)) as handle:
        for record in records:
            handle.write(json.dumps(record, separators=(",", ":")))
            handle.write("\n")
        temp_name = handle.name
    os.replace(temp_name, paths.store_file)


def with_lock(paths: RunnerStorePaths, shared: bool):
    ensure_store(paths)
    handle = paths.lock_file.open("r+", encoding="utf-8")
    fcntl.flock(handle.fileno(), fcntl.LOCK_SH if shared else fcntl.LOCK_EX)
    return handle


def add_record(repo_url: str, runner_id: int, runner_name: str, flavor: str = "", store_file: str | None = None) -> None:
    paths = resolve_paths(store_file)
    with with_lock(paths, shared=False):
        records = _load_records(paths)
        records.append({"repo_url": repo_url, "id": runner_id, "name": runner_name, "flavor": flavor})
        _write_records(paths, records)


def remove_record(runner_id: str, store_file: str | None = None) -> None:
    paths = resolve_paths(store_file)
    with with_lock(paths, shared=False):
        records = [record for record in _load_records(paths) if str(record.get("id", "")) != str(runner_id)]
        _write_records(paths, records)


def list_records(store_file: str | None = None) -> list[dict[str, object]]:
    paths = resolve_paths(store_file)
    with with_lock(paths, shared=True):
        return _load_records(paths)


def clear_records(store_file: str | None = None) -> None:
    paths = resolve_paths(store_file)
    with with_lock(paths, shared=False):
        _write_records(paths, [])

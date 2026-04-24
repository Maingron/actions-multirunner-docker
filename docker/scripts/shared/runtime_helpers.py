"""Runner runtime helpers shared by entrypoint, pool manager, and status."""

from __future__ import annotations

from pathlib import Path
import re
from typing import Iterable


def sanitize_component(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]", "_", value)


def resolve_within(root: Path, relative: str) -> Path:
    resolved_root = root.resolve()
    candidate = (resolved_root / relative).resolve()
    try:
        candidate.relative_to(resolved_root)
    except ValueError as exc:
        raise ValueError(f"path escapes base directory: {relative}") from exc
    return candidate


def derive_workdir(title: str, repo_url: str) -> str:
    repo_name = repo_url.rstrip("/").split("/")[-1]
    if repo_name.endswith(".git"):
        repo_name = repo_name[:-4]
    return f"{sanitize_component(repo_name)}/{sanitize_component(title)}"


def merge_auto_labels(labels_csv: str, auto_pairs: Iterable[tuple[str, str]]) -> str:
    seen_keys: set[str] = set()
    out: list[str] = []
    for item in labels_csv.split(","):
        stripped = item.strip()
        if not stripped:
            continue
        out.append(stripped)
        if ":" in stripped:
            seen_keys.add(stripped.split(":", 1)[0])
    for key, value in auto_pairs:
        if not value or key in seen_keys:
            continue
        out.append(f"{key}:{value}")
        seen_keys.add(key)
    return ",".join(out)


def singleton_pool(instances_min: int, instances_max: int, instances_headroom: int) -> bool:
    return instances_min == 1 and instances_max == 1 and instances_headroom == 0

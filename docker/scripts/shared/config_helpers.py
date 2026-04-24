"""Shared config helper functions."""

from __future__ import annotations

from collections.abc import Iterable
from configparser import ConfigParser
from pathlib import PurePosixPath
from typing import Any


BOOLEAN_STATES = ConfigParser.BOOLEAN_STATES


def as_text(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


def to_int_or(value: Any, fallback: int) -> int:
    try:
        return int(as_text(value).strip())
    except Exception:
        return fallback


def split_listish(value: Any) -> list[str]:
    if value is None:
        return []
    if isinstance(value, list):
        parts = [as_text(v).strip() for v in value]
    else:
        raw = as_text(value).replace(",", " ")
        parts = [p.strip() for p in raw.split()]
    return [p for p in parts if p]


def merge_unique_tokens(*groups: Iterable[str]) -> str:
    seen: set[str] = set()
    out: list[str] = []
    for group in groups:
        for token in group:
            if token in seen:
                continue
            seen.add(token)
            out.append(token)
    return " ".join(out)


def normalize_repo_url(value: Any) -> str:
    repo = as_text(value).rstrip("/")
    if repo.endswith(".git"):
        repo = repo[:-4]
    return repo


def normalize_relative_path(value: Any) -> str:
    raw = as_text(value).strip()
    if not raw:
        return ""

    candidate = PurePosixPath(raw)
    if candidate.is_absolute():
        raise ValueError(f"path must be relative: {raw}")

    parts: list[str] = []
    for part in candidate.parts:
        if part in {"", "."}:
            continue
        if part == "..":
            raise ValueError(f"path may not contain '..': {raw}")
        parts.append(part)

    return "/".join(parts)


def nested_map(root: dict[str, Any], key: str) -> dict[str, Any]:
    value = root.get(key)
    return value if isinstance(value, dict) else {}

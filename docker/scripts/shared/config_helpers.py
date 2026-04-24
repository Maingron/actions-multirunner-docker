"""Shared config helper functions."""

from __future__ import annotations

from collections.abc import Iterable
from configparser import ConfigParser
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


def nested_map(root: dict[str, Any], key: str) -> dict[str, Any]:
    value = root.get(key)
    return value if isinstance(value, dict) else {}

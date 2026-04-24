"""Shared config loading helpers for YAML + default overlay."""

from __future__ import annotations

import copy
import json
from pathlib import Path
from typing import Any

import yaml

DEFAULT_CONFIG_FILENAME = "default-config.json"
FALLBACK_CONFIG_PATH = Path("/etc/github-runners/default-config.json")


def deep_merge(base: Any, override: Any) -> Any:
    if isinstance(base, dict) and isinstance(override, dict):
        merged = copy.deepcopy(base)
        for key, value in override.items():
            merged[key] = deep_merge(merged.get(key), value)
        return merged
    if isinstance(override, list):
        return copy.deepcopy(override)
    return copy.deepcopy(override)


def default_config_path(module_file: str) -> Path:
    module_path = Path(module_file).resolve()
    candidates = [
        module_path.parent / DEFAULT_CONFIG_FILENAME,
        module_path.parent.parent / DEFAULT_CONFIG_FILENAME,
    ]
    for local_path in candidates:
        if local_path.is_file():
            return local_path
    return FALLBACK_CONFIG_PATH


def load_default_config(module_file: str) -> dict[str, Any]:
    config_path = default_config_path(module_file)
    if not config_path.is_file():
        raise ValueError(
            f"parse-config: default config not found: {config_path} or {FALLBACK_CONFIG_PATH}"
        )
    with config_path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError("parse-config: default-config.json must contain a top-level object")
    return data


def load_merged_config(config_path: str, module_file: str) -> dict[str, Any]:
    defaults = load_default_config(module_file)
    with open(config_path, "r", encoding="utf-8") as handle:
        raw = yaml.safe_load(handle) or {}
    if not isinstance(raw, dict):
        raw = {}
    merged = deep_merge(defaults, raw)
    if not isinstance(merged, dict):
        return defaults
    return merged

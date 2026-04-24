#!/usr/bin/env python3
"""Parse config.yml and emit normalized runner records.

Config loading model:
- Load canonical defaults from default-config.json.
- Parse user YAML config.yml.
- Deep-merge user values on top of defaults.
- Normalize the merged object.

Usage:
    parse-config.py [<config.yml>]
    parse-config.py --get <dotted.key> [<config.yml>]
    parse-config.py --dump-merged-json [<config.yml>]
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import dataclass
from typing import Any

from shared.config_helpers import (
    BOOLEAN_STATES,
    as_text,
    merge_unique_tokens,
    nested_map,
    normalize_relative_path,
    normalize_repo_url,
    split_listish,
    to_int_or,
)
from shared.config_loader import load_merged_config

US = "\x1f"
DEFAULT_LABELS = "self-hosted,linux,x64"
DEFAULT_IMAGE = "debian:stable-slim"


def eprint(msg: str) -> None:
    print(msg, file=sys.stderr)


@dataclass
class NormalizedConfig:
    general_autoprune: str
    defaults_image: str
    defaults_pat: str
    defaults_ephemeral: str
    defaults_labels: str
    defaults_startup_script: str
    runners: list[list[str]]


def normalize_instances(runner: dict[str, Any], defaults: dict[str, Any]) -> tuple[int, int, int]:
    instances_defaults = nested_map(defaults, "instances")
    instances_runner = nested_map(runner, "instances")
    min_raw = instances_runner.get("min", instances_defaults.get("min", "1"))
    max_raw = instances_runner.get("max", instances_defaults.get("max", ""))
    head_raw = instances_runner.get("headroom", instances_defaults.get("headroom", "0"))

    min_v = max(to_int_or(min_raw, 1), 1)
    max_v = to_int_or(max_raw, min_v) if as_text(max_raw) != "" else min_v
    max_v = max(max_v, min_v)
    head_v = max(to_int_or(head_raw, 0), 0)
    return min_v, max_v, head_v


def normalize_persistent_storage(runner: dict[str, Any], defaults: dict[str, Any]) -> tuple[str, int, str]:
    ps_defaults = nested_map(defaults, "persistent_storage")
    ps_runner = nested_map(runner, "persistent_storage")

    enabled = "1" if BOOLEAN_STATES.get(as_text(ps_runner.get("enabled", ps_defaults.get("enabled", False))).strip().lower(), False) else "0"
    ttl = to_int_or(ps_runner.get("ttl", ps_defaults.get("ttl", "3600")), 3600)
    if ttl < 0:
        ttl = 3600

    scope = as_text(ps_runner.get("scope", ps_defaults.get("scope", "shared"))).lower()
    if scope not in {"title", "shared"}:
        scope = "shared"

    return enabled, ttl, scope


def normalize_workdir(title: str, repo: str, runner: dict[str, Any]) -> str:
    try:
        return normalize_relative_path(runner.get("workdir"))
    except ValueError as exc:
        raise ValueError(f"parse-config: runner {title} ({repo}): invalid workdir: {exc}") from exc


def normalize_startup_script(title: str, repo: str, runner: dict[str, Any], defaults: dict[str, Any]) -> str:
    startup_script = as_text(runner.get("startup_script", defaults["startup_script"]))
    if startup_script and startup_script != os.path.basename(startup_script):
        raise ValueError(
            f"parse-config: runner {title} ({repo}): startup_script must name a file directly under startup-scripts/"
        )
    return startup_script


def validate_runner_auth(title: str, repo: str, eph: str, token: str, pat: str) -> None:
    if eph == "1" and not pat:
        raise ValueError(
            f"parse-config: runner {title} ({repo}): ephemeral runners require pat (per-runner, defaults.pat, or $GITHUB_PAT)"
        )
    if eph == "0" and not token and not pat:
        raise ValueError(f"parse-config: runner {title} ({repo}): persistent runners need token or pat")


def normalize_runner_row(
    index: int,
    runner: dict[str, Any],
    defaults: dict[str, Any],
    github_pat: str,
) -> list[str]:
    title = as_text(runner.get("title"))
    repo = normalize_repo_url(runner.get("repo_url"))
    if not title or not repo:
        raise ValueError(f"parse-config: invalid runner entry (missing title/repo_url) at item {index}")

    token = as_text(runner.get("token"))
    workdir = normalize_workdir(title, repo, runner)

    ephemeral_src = runner["ephemeral"] if "ephemeral" in runner else defaults["ephemeral"]
    eph = "1" if BOOLEAN_STATES.get(as_text(ephemeral_src).strip().lower(), False) else "0"

    pat = as_text(runner.get("pat", defaults["pat"]))
    if not pat:
        pat = github_pat

    # Merge labels from defaults and runner config, preserving all unique labels
    # including the essential "self-hosted" label from defaults
    labels_merged = merge_unique_tokens(
        split_listish(defaults.get("labels")),
        split_listish(runner.get("labels")),
    )
    # Convert space-separated tokens back to CSV format for GitHub API
    labels = labels_merged.replace(" ", ",") if labels_merged else DEFAULT_LABELS
    group = as_text(runner.get("runner_group_id", defaults["runner_group_id"])) or "1"
    idle = as_text(runner.get("idle_regeneration", defaults["idle_regeneration"])) or "0"

    image = as_text(runner.get("image", defaults["image"]))
    image = image.lower() if image else DEFAULT_IMAGE

    startup_script = normalize_startup_script(title, repo, runner, defaults)
    packages = merge_unique_tokens(
        split_listish(defaults.get("additional_packages")),
        split_listish(runner.get("additional_packages")),
    )

    wd_defaults = nested_map(defaults, "watchdog")
    wd_runner = nested_map(runner, "watchdog")
    wd_enabled = "1" if BOOLEAN_STATES.get(as_text(wd_runner.get("enabled", wd_defaults.get("enabled", False))).strip().lower(), False) else "0"
    wd_interval = as_text(wd_runner.get("interval", wd_defaults.get("interval", "0"))) or "0"

    docker_defaults = nested_map(defaults, "docker")
    docker_runner = nested_map(runner, "docker")
    docker_enabled = "1" if BOOLEAN_STATES.get(as_text(docker_runner.get("enabled", docker_defaults.get("enabled", False))).strip().lower(), False) else "0"

    min_v, max_v, head_v = normalize_instances(runner, defaults)
    ps_enabled, ps_ttl, ps_scope = normalize_persistent_storage(runner, defaults)

    validate_runner_auth(title, repo, eph, token, pat)

    return [
        title,
        repo,
        token,
        workdir,
        eph,
        pat,
        labels,
        group,
        idle,
        image,
        startup_script,
        packages,
        wd_enabled,
        wd_interval,
        docker_enabled,
        str(min_v),
        str(max_v),
        str(head_v),
        ps_enabled,
        str(ps_ttl),
        ps_scope,
    ]


def normalize_config(merged: dict[str, Any], github_pat: str) -> NormalizedConfig:
    general = merged.get("general") if isinstance(merged.get("general"), dict) else {}
    defaults = merged.get("defaults") if isinstance(merged.get("defaults"), dict) else {}

    defaults["image"] = as_text(defaults.get("image") or DEFAULT_IMAGE).lower()
    defaults["pat"] = as_text(defaults.get("pat"))
    defaults["labels"] = as_text(defaults.get("labels") or DEFAULT_LABELS)
    defaults["startup_script"] = as_text(defaults.get("startup_script"))

    runners_obj = merged.get("runners")
    runners_list = runners_obj if isinstance(runners_obj, list) else []
    normalized_rows: list[list[str]] = []

    for idx, runner in enumerate(runners_list, start=1):
        if not isinstance(runner, dict):
            raise ValueError(f"parse-config: invalid runner entry at item {idx}")
        normalized_rows.append(normalize_runner_row(idx, runner, defaults, github_pat))

    autoprune = "true" if BOOLEAN_STATES.get(as_text(general.get("autoprune", False)).strip().lower(), False) else "false"
    defaults_ephemeral = "true" if BOOLEAN_STATES.get(as_text(defaults.get("ephemeral", True)).strip().lower(), False) else "false"

    return NormalizedConfig(
        general_autoprune=autoprune,
        defaults_image=as_text(defaults.get("image") or DEFAULT_IMAGE),
        defaults_pat=as_text(defaults.get("pat")),
        defaults_ephemeral=defaults_ephemeral,
        defaults_labels=as_text(defaults.get("labels") or DEFAULT_LABELS),
        defaults_startup_script=as_text(defaults.get("startup_script")),
        runners=normalized_rows,
    )


def main() -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--get", dest="get_key", default=None)
    parser.add_argument("--dump-merged-json", action="store_true")
    parser.add_argument("config", nargs="?")
    args = parser.parse_args()

    if args.get_key and args.dump_merged_json:
        eprint("parse-config: --get and --dump-merged-json are mutually exclusive")
        return 2

    config_file = args.config or os.environ.get("CONFIG_FILE", "/etc/github-runners/config.yml")
    if not os.path.isfile(config_file) or not os.access(config_file, os.R_OK):
        eprint(f"parse-config: config file not readable: {config_file}")
        return 1

    try:
        merged = load_merged_config(config_file, __file__)
        normalized = normalize_config(merged, os.environ.get("GITHUB_PAT", ""))
    except ValueError as exc:
        eprint(str(exc))
        return 1

    if args.dump_merged_json:
        print(json.dumps(merged, indent=2, sort_keys=True))
        return 0

    if args.get_key is not None:
        get_map = {
            "general.autoprune": normalized.general_autoprune,
            "defaults.image": normalized.defaults_image,
            "defaults.pat": normalized.defaults_pat,
            "defaults.ephemeral": normalized.defaults_ephemeral,
            "defaults.labels": normalized.defaults_labels,
            "defaults.startup_script": normalized.defaults_startup_script,
        }
        print(get_map.get(args.get_key, ""))
        return 0

    for row in normalized.runners:
        print(US.join(row))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

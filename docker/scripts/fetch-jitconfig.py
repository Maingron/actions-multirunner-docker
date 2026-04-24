#!/usr/bin/env python3
"""Mint a just-in-time runner configuration for an ephemeral runner."""

from __future__ import annotations

import os
import sys

from shared.github_api import fetch_jit_config, split_csv_labels


def main() -> int:
    if len(sys.argv) not in {5, 6}:
        print("usage: fetch-jitconfig.py <repo_url> <pat> <name> <labels_csv> [runner_group_id]", file=sys.stderr)
        return 2

    repo_url, token, name, labels_csv = sys.argv[1:5]
    runner_group_id = int(sys.argv[5]) if len(sys.argv) == 6 else 1

    target, response = fetch_jit_config(repo_url, token, name, split_csv_labels(labels_csv), runner_group_id)
    if response.status not in {200, 201}:
        print(f"fetch-jitconfig: API call failed ({target.scope}) HTTP {response.status}", file=sys.stderr)
        print(f"fetch-jitconfig: endpoint: https://api.github.com/{target.base_path}/actions/runners/generate-jitconfig", file=sys.stderr)
        print(f"fetch-jitconfig: response: {response.body}", file=sys.stderr)
        return 1

    payload = response.json() or {}
    encoded = payload.get("encoded_jit_config") or ""
    if not encoded:
        print(f"fetch-jitconfig: no encoded_jit_config in response: {response.body}", file=sys.stderr)
        return 1

    runner_id = str(((payload.get("runner") or {}).get("id") or "")).strip()
    id_file = os.environ.get("JITCONFIG_ID_FILE", "")
    if id_file and runner_id:
        with open(id_file, "w", encoding="utf-8") as handle:
            handle.write(f"{runner_id}\n")

    if os.environ.get("RUNNER_DEBUG") == "1":
        print(f"fetch-jitconfig: minted JIT config for runner id={runner_id or '?'} ({target.scope})", file=sys.stderr)

    print(encoded)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

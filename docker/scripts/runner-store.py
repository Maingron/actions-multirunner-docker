#!/usr/bin/env python3
"""Persistent JSONL store of JIT runners we've minted."""

from __future__ import annotations

import json
import sys
from shared.runner_store_lib import add_record, clear_records, list_records, remove_record


def main() -> int:
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""

    if cmd == "add":
        if len(sys.argv) != 5:
            print("usage: runner-store.py add <repo_url> <runner_id> <runner_name>", file=sys.stderr)
            return 2
        repo_url, runner_id, runner_name = sys.argv[2:5]
        if not runner_id:
            return 0
        add_record(repo_url, int(runner_id), runner_name, flavor=os.environ.get("RUNNER_IMAGE_FLAVOR", ""))
        return 0

    if cmd == "remove":
        if len(sys.argv) != 3:
            print("usage: runner-store.py remove <runner_id>", file=sys.stderr)
            return 2
        runner_id = sys.argv[2]
        if not runner_id:
            return 0
        remove_record(runner_id)
        return 0

    if cmd == "list":
        for record in list_records():
            print(json.dumps(record, separators=(",", ":")))
        return 0

    if cmd == "clear":
        clear_records()
        return 0

    print(f"runner-store: unknown command: {cmd}", file=sys.stderr)
    print("usage: runner-store.py {add|remove|list|clear} ...", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())

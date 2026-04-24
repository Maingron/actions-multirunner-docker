#!/usr/bin/env python3
"""Deregister a self-hosted runner via the GitHub API."""

from __future__ import annotations

import sys

from shared.github_api import delete_runner


def main() -> int:
    if len(sys.argv) != 4:
        print("usage: delete-runner.py <repo_url> <pat> <runner_id>", file=sys.stderr)
        return 2

    repo_url, token, runner_id = sys.argv[1:4]
    if not runner_id or runner_id == "?":
        return 0

    target, response = delete_runner(repo_url, token, runner_id)
    if response.status in {204, 404}:
        return 0

    print(
        f"delete-runner: failed to deregister runner {runner_id} ({target.scope}) HTTP {response.status}",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())

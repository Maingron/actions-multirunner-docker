#!/usr/bin/env python3
"""Fetch a fresh runner registration token from the GitHub API."""

from __future__ import annotations

import os
import sys

from shared.github_api import fetch_registration_token, mask_secret


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: fetch-token.py <repo_url> <pat>", file=sys.stderr)
        return 2

    repo_url, token = sys.argv[1], sys.argv[2]
    target, response = fetch_registration_token(repo_url, token)
    if response.status not in {200, 201}:
        print(f"fetch-token: API call failed ({target.scope}) HTTP {response.status}", file=sys.stderr)
        print(f"fetch-token: endpoint: https://api.github.com/{target.base_path}/actions/runners/registration-token", file=sys.stderr)
        print(f"fetch-token: body: {response.body}", file=sys.stderr)
        return 1

    payload = response.json() or {}
    reg_token = payload.get("token") or ""
    if not reg_token:
        print(f"fetch-token: empty token in response: {response.body}", file=sys.stderr)
        return 1

    if os.environ.get("RUNNER_DEBUG") == "1":
        expires = payload.get("expires_at", "?")
        print(
            f"fetch-token: minted registration token {mask_secret(reg_token)} (scope={target.scope}, expires={expires})",
            file=sys.stderr,
        )
    print(reg_token)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

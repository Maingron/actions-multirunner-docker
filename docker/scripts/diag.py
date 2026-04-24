#!/usr/bin/env python3
"""Diagnose registration/auth failures against the GitHub runner APIs."""

from __future__ import annotations

import json
import os
import sys
from urllib import request

from shared.github_api import get_authenticated_user, get_visibility, fetch_registration_token, github_request, parse_target


def pretty_json(text: str) -> str:
    try:
        return json.dumps(json.loads(text), indent=2, sort_keys=True)
    except Exception:
        return text


def direct_registration_probe(repo_url: str, reg_token: str) -> tuple[int, str]:
    response = github_request(
        "https://api.github.com/actions/runner-registration",
        reg_token,
        method="POST",
        json_body={"url": repo_url, "runner_event": "register"},
        extra_headers={"Authorization": f"RemoteAuth {reg_token}"},
    )
    return response.status, response.body


def main() -> int:
    repo_url = sys.argv[1] if len(sys.argv) > 1 else ""
    token = sys.argv[2] if len(sys.argv) > 2 else os.environ.get("GITHUB_PAT", "")
    if not repo_url or not token:
        print("usage: diag.py <repo_url> <pat>   (or set GITHUB_PAT)", file=sys.stderr)
        return 2

    print("=== 1. Identity check ===")
    whoami = get_authenticated_user(token)
    print(pretty_json(whoami.body))
    print()

    print("=== 2. PAT scopes (classic only) ===")
    scope_probe = request.Request(
        "https://api.github.com/user",
        headers={"Authorization": f"Bearer {token}"},
        method="HEAD",
    )
    try:
        with request.urlopen(scope_probe, timeout=10) as response:
            for key, value in response.headers.items():
                lowered = key.lower()
                if lowered.startswith("x-oauth-scope") or lowered.startswith("x-github-sso") or lowered.startswith("x-accepted"):
                    print(f"{key}: {value}")
    except Exception:
        pass
    print("(fine-grained PATs do not expose scopes here; that's normal)")
    print()

    print("=== 3. Can the PAT see the target? ===")
    target, visibility = get_visibility(repo_url, token)
    print(f"GET https://api.github.com/{target.base_path}")
    print(f"HTTP {visibility.status}")
    print(pretty_json(visibility.body))
    print()

    print("=== 4. Mint registration token ===")
    target, reg = fetch_registration_token(repo_url, token)
    print(f"POST https://api.github.com/{target.base_path}/actions/runners/registration-token")
    print(f"HTTP {reg.status}")
    payload = reg.json() or {}
    reg_token = payload.get("token") or ""
    if not reg_token:
        print("could not mint registration token:")
        print(reg.body)
        return 1
    print(f"got registration token: {reg_token[:6]}...{reg_token[-4:]}")
    print(f"expires: {payload.get('expires_at', '?')}")
    print()

    print("=== 5. Probe /actions/runner-registration directly ===")
    status, body = direct_registration_probe(repo_url, reg_token)
    print(f"HTTP {status}")
    print(body)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

"""GitHub Actions runner API helpers."""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any
from urllib import error, request


API_VERSION = "2022-11-28"
API_ACCEPT = "application/vnd.github+json"


@dataclass(frozen=True)
class GitHubTarget:
    owner: str
    repo: str | None

    @property
    def scope(self) -> str:
        if self.repo:
            return f"repo:{self.owner}/{self.repo}"
        return f"org:{self.owner}"

    @property
    def base_path(self) -> str:
        if self.repo:
            return f"repos/{self.owner}/{self.repo}"
        return f"orgs/{self.owner}"


@dataclass
class GitHubResponse:
    status: int
    body: str
    headers: dict[str, str]

    def json(self) -> Any:
        if not self.body:
            return None
        return json.loads(self.body)


def parse_target(repo_url: str) -> GitHubTarget:
    path = repo_url.split("://", 1)[-1]
    path = path.split("/", 1)[-1].rstrip("/")
    if path.endswith(".git"):
        path = path[:-4]
    parts = [part for part in path.split("/") if part]
    if not parts:
        raise ValueError(f"github-api: invalid repo_url: {repo_url}")
    if len(parts) == 1:
        return GitHubTarget(owner=parts[0], repo=None)
    return GitHubTarget(owner=parts[0], repo=parts[1])


def api_url(path: str) -> str:
    return f"https://api.github.com/{path}"


def github_request(
    url: str,
    token: str,
    *,
    method: str = "GET",
    json_body: Any | None = None,
    extra_headers: dict[str, str] | None = None,
    timeout: int = 15,
) -> GitHubResponse:
    body_bytes: bytes | None = None
    headers = {
        "Accept": API_ACCEPT,
        "Authorization": f"Bearer {token}",
        "X-GitHub-Api-Version": API_VERSION,
    }
    if json_body is not None:
        body_bytes = json.dumps(json_body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    if extra_headers:
        headers.update(extra_headers)

    req = request.Request(url, data=body_bytes, headers=headers, method=method)
    try:
        with request.urlopen(req, timeout=timeout) as resp:
            return GitHubResponse(
                status=resp.getcode(),
                body=resp.read().decode("utf-8", errors="replace"),
                headers=dict(resp.headers.items()),
            )
    except error.HTTPError as exc:
        return GitHubResponse(
            status=exc.code,
            body=exc.read().decode("utf-8", errors="replace"),
            headers=dict(exc.headers.items()),
        )
    except error.URLError:
        return GitHubResponse(status=0, body="", headers={})


def fetch_registration_token(repo_url: str, token: str) -> tuple[GitHubTarget, GitHubResponse]:
    target = parse_target(repo_url)
    response = github_request(api_url(f"{target.base_path}/actions/runners/registration-token"), token, method="POST")
    return target, response


def fetch_jit_config(
    repo_url: str,
    token: str,
    name: str,
    labels: list[str],
    runner_group_id: int,
) -> tuple[GitHubTarget, GitHubResponse]:
    target = parse_target(repo_url)
    response = github_request(
        api_url(f"{target.base_path}/actions/runners/generate-jitconfig"),
        token,
        method="POST",
        json_body={
            "name": name,
            "runner_group_id": runner_group_id,
            "labels": labels,
            "work_folder": "_work",
        },
    )
    return target, response


def delete_runner(repo_url: str, token: str, runner_id: str) -> tuple[GitHubTarget, GitHubResponse]:
    target = parse_target(repo_url)
    response = github_request(api_url(f"{target.base_path}/actions/runners/{runner_id}"), token, method="DELETE")
    return target, response


def list_runners(repo_url: str, token: str, *, timeout: int = 6) -> tuple[GitHubTarget, GitHubResponse]:
    target = parse_target(repo_url)
    response = github_request(
        api_url(f"{target.base_path}/actions/runners?per_page=100"),
        token,
        timeout=timeout,
    )
    return target, response


def get_visibility(repo_url: str, token: str) -> tuple[GitHubTarget, GitHubResponse]:
    target = parse_target(repo_url)
    response = github_request(api_url(target.base_path), token)
    return target, response


def get_authenticated_user(token: str) -> GitHubResponse:
    return github_request(api_url("user"), token)


def split_csv_labels(labels_csv: str) -> list[str]:
    return [part.strip() for part in labels_csv.split(",") if part.strip()]


def mask_secret(value: str) -> str:
    if len(value) <= 10:
        return "***"
    return f"{value[:6]}...{value[-4:]}"

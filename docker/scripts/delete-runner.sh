#!/usr/bin/env bash
# Deregister a self-hosted runner via the GitHub API.
#
# Usage: delete-runner.sh <repo_url> <pat> <runner_id>
#
# Used on container shutdown to remove ephemeral/JIT runners that were
# killed before their job completed. Runners that finished a job cleanly
# auto-deregister, so calling this on an already-gone id just returns 404.

set -uo pipefail

repo_url="$1"
pat="$2"
runner_id="$3"

if [[ -z "$runner_id" || "$runner_id" == "?" ]]; then
    exit 0
fi

path="${repo_url#*://}"
path="${path#*/}"
path="${path%/}"
path="${path%.git}"

owner="${path%%/*}"
rest="${path#*/}"

if [[ "$rest" == "$owner" || -z "$rest" ]]; then
    api_url="https://api.github.com/orgs/${owner}/actions/runners/${runner_id}"
    scope="org:${owner}"
else
    repo="${rest%%/*}"
    api_url="https://api.github.com/repos/${owner}/${repo}/actions/runners/${runner_id}"
    scope="repo:${owner}/${repo}"
fi

http_code="$(
    curl -sS -o /dev/null -w '%{http_code}' -X DELETE \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer ${pat}" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "$api_url" || echo 000
)"

# 204 = deleted, 404 = already gone (auto-deregistered), both fine.
case "$http_code" in
    204|404) exit 0 ;;
    *)
        echo "delete-runner: failed to deregister runner ${runner_id} (${scope}) HTTP ${http_code}" >&2
        exit 1
        ;;
esac

#!/usr/bin/env bash
# Fetch a fresh runner registration token from the GitHub API.
#
# Usage: fetch-token.sh <repo_url> <pat>
#
# <repo_url> may point at a repository (…/owner/repo) or an organization
# (…/org). A PAT with `repo` scope (for repo runners) or `admin:org` scope
# (for org runners) is required; a GitHub App installation token works too.
#
# Prints the registration token on stdout. Exits non-zero on failure.

set -euo pipefail

repo_url="$1"
pat="$2"

# Strip scheme + host, trailing slash, trailing .git
path="${repo_url#*://}"
path="${path#*/}"
path="${path%/}"
path="${path%.git}"

owner="${path%%/*}"
rest="${path#*/}"

if [[ "$rest" == "$owner" || -z "$rest" ]]; then
    # org-level runner
    scope="org:${owner}"
    api_url="https://api.github.com/orgs/${owner}/actions/runners/registration-token"
else
    repo="${rest%%/*}"
    scope="repo:${owner}/${repo}"
    api_url="https://api.github.com/repos/${owner}/${repo}/actions/runners/registration-token"
fi

http_code=0
response="$(
    curl -sS -o /tmp/ght.$$ -w '%{http_code}' -X POST \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer ${pat}" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "$api_url"
)" || true
http_code="$response"
body="$(cat /tmp/ght.$$ 2>/dev/null || true)"
rm -f /tmp/ght.$$

if [[ "$http_code" != "201" && "$http_code" != "200" ]]; then
    echo "fetch-token: API call failed (${scope}) HTTP ${http_code}" >&2
    echo "fetch-token: endpoint: ${api_url}" >&2
    echo "fetch-token: body: ${body}" >&2
    exit 1
fi

token="$(printf '%s' "$body" | jq -r '.token // empty')"
if [[ -z "$token" ]]; then
    echo "fetch-token: empty token in response: ${body}" >&2
    exit 1
fi

if [[ "${RUNNER_DEBUG:-0}" == "1" ]]; then
    expires="$(printf '%s' "$body" | jq -r '.expires_at // "?"')"
    masked="${token:0:6}...${token: -4}"
    echo "fetch-token: minted registration token ${masked} (scope=${scope}, expires=${expires})" >&2
fi

printf '%s\n' "$token"

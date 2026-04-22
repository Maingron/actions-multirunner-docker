#!/usr/bin/env bash
# Diagnose a 404 / auth failure during runner registration.
#
# Usage (inside the container):
#   docker compose exec runners /usr/local/bin/diag.sh <repo_url> <pat>
#
# It will:
#   1. Call the API to mint a fresh registration token with your PAT.
#   2. Show which endpoint was used and what the API returned.
#   3. POST that token directly to /actions/runner-registration the same way
#      config.sh does, so we can see the backend's response without the
#      runner's own error wrapping.

set -uo pipefail

repo_url="${1:-}"
pat="${2:-${GITHUB_PAT:-}}"

if [[ -z "$repo_url" || -z "$pat" ]]; then
    echo "usage: $0 <repo_url> <pat>   (or set GITHUB_PAT)" >&2
    exit 2
fi

echo "=== 1. Identity check ==="
curl -sS -H "Authorization: Bearer $pat" \
        -H "Accept: application/vnd.github+json" \
        https://api.github.com/user | jq '{login,type,id}'
echo

echo "=== 2. PAT scopes (classic only) ==="
curl -sSI -H "Authorization: Bearer $pat" https://api.github.com/user \
    | awk '/^[Xx]-[Oo][Aa][Uu][Tt][Hh]-[Ss]cope|^[Xx]-[Gg][Ii][Tt][Hh][Uu][Bb]-[Ss][Ss][Oo]|^[Xx]-[Aa]ccepted/{print}'
echo "(fine-grained PATs do not expose scopes here; that's normal)"
echo

echo "=== 3. Can the PAT see the target? ==="
path="${repo_url#*://}"; path="${path#*/}"; path="${path%/}"; path="${path%.git}"
owner="${path%%/*}"; rest="${path#*/}"
if [[ "$rest" == "$owner" || -z "$rest" ]]; then
    visibility_url="https://api.github.com/orgs/${owner}"
    reg_url="https://api.github.com/orgs/${owner}/actions/runners/registration-token"
else
    repo="${rest%%/*}"
    visibility_url="https://api.github.com/repos/${owner}/${repo}"
    reg_url="https://api.github.com/repos/${owner}/${repo}/actions/runners/registration-token"
fi
echo "GET $visibility_url"
curl -sS -o /tmp/v.$$ -w 'HTTP %{http_code}\n' \
    -H "Authorization: Bearer $pat" \
    -H "Accept: application/vnd.github+json" "$visibility_url"
jq '{full_name, private, permissions}' </tmp/v.$$ 2>/dev/null || cat /tmp/v.$$
rm -f /tmp/v.$$
echo

echo "=== 4. Mint registration token ==="
echo "POST $reg_url"
curl -sS -o /tmp/r.$$ -w 'HTTP %{http_code}\n' -X POST \
    -H "Authorization: Bearer $pat" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$reg_url"
body="$(cat /tmp/r.$$)"
rm -f /tmp/r.$$
reg_token="$(printf '%s' "$body" | jq -r '.token // empty')"
if [[ -z "$reg_token" ]]; then
    echo "could not mint registration token:"
    echo "$body"
    exit 1
fi
echo "got registration token: ${reg_token:0:6}...${reg_token: -4}"
echo "expires: $(printf '%s' "$body" | jq -r '.expires_at')"
echo

echo "=== 5. Probe /actions/runner-registration directly ==="
# This is the endpoint config.sh hits. Auth uses the REGISTRATION TOKEN,
# not the PAT. Any failure here is a token/URL problem, not a PAT problem.
curl -sS -o /tmp/p.$$ -w 'HTTP %{http_code}\n' -X POST \
    -H "Authorization: RemoteAuth ${reg_token}" \
    -H "Content-Type: application/json" \
    https://api.github.com/actions/runner-registration \
    -d "{\"url\":\"${repo_url}\",\"runner_event\":\"register\"}"
cat /tmp/p.$$; echo
rm -f /tmp/p.$$

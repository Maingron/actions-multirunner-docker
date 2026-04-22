#!/usr/bin/env bash
# Mint a just-in-time (JIT) runner configuration for an ephemeral runner.
#
# Usage: fetch-jitconfig.sh <repo_url> <pat> <name> <labels_csv> [runner_group_id]
#
# Prints the opaque `encoded_jit_config` value on stdout. Pass that directly to
# `./run.sh --jitconfig <value>`; the runner becomes ephemeral automatically,
# runs exactly one job, then exits. GitHub removes it from the UI on its own.
#
# Works with:
#   - classic PAT          (repo / admin:org scope)
#   - fine-grained PAT     (Administration: write / Self-hosted runners: write)
#   - GitHub App install token

set -uo pipefail

repo_url="$1"
pat="$2"
name="$3"
labels_csv="$4"
runner_group_id="${5:-1}"

# Strip scheme + host, trailing slash / .git
path="${repo_url#*://}"
path="${path#*/}"
path="${path%/}"
path="${path%.git}"

owner="${path%%/*}"
rest="${path#*/}"

if [[ "$rest" == "$owner" || -z "$rest" ]]; then
    scope="org:${owner}"
    api_url="https://api.github.com/orgs/${owner}/actions/runners/generate-jitconfig"
else
    repo="${rest%%/*}"
    scope="repo:${owner}/${repo}"
    api_url="https://api.github.com/repos/${owner}/${repo}/actions/runners/generate-jitconfig"
fi

# Turn "a,b,c" into JSON array ["a","b","c"]
labels_json="$(printf '%s' "$labels_csv" | jq -Rc 'split(",") | map(select(length > 0))')"

body_json="$(jq -nc \
    --arg name "$name" \
    --argjson group "$runner_group_id" \
    --argjson labels "$labels_json" \
    '{name: $name, runner_group_id: $group, labels: $labels, work_folder: "_work"}')"

http_code=0
resp_file="$(mktemp)"
http_code="$(
    curl -sS -o "$resp_file" -w '%{http_code}' -X POST \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer ${pat}" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        -d "$body_json" \
        "$api_url" || echo 000
)"
body="$(cat "$resp_file")"
rm -f "$resp_file"

if [[ "$http_code" != "201" && "$http_code" != "200" ]]; then
    echo "fetch-jitconfig: API call failed (${scope}) HTTP ${http_code}" >&2
    echo "fetch-jitconfig: endpoint: ${api_url}" >&2
    echo "fetch-jitconfig: request:  ${body_json}" >&2
    echo "fetch-jitconfig: response: ${body}" >&2
    exit 1
fi

cfg="$(printf '%s' "$body" | jq -r '.encoded_jit_config // empty')"
if [[ -z "$cfg" ]]; then
    echo "fetch-jitconfig: no encoded_jit_config in response: ${body}" >&2
    exit 1
fi

rid="$(printf '%s' "$body" | jq -r '.runner.id // empty')"

# Let callers recover the server-side runner id (needed to deregister a JIT
# runner that was killed before its job finished). Opt-in via env var.
if [[ -n "${JITCONFIG_ID_FILE:-}" && -n "$rid" ]]; then
    printf '%s\n' "$rid" > "$JITCONFIG_ID_FILE"
fi

if [[ "${RUNNER_DEBUG:-0}" == "1" ]]; then
    echo "fetch-jitconfig: minted JIT config for runner id=${rid:-?} (${scope})" >&2
fi

printf '%s\n' "$cfg"

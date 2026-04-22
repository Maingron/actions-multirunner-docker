#!/usr/bin/env bash
# Persistent record of every JIT runner we've minted.
#
# Purpose: GitHub keeps runners in the UI until the owning job finishes or
# someone explicitly deletes them. If the container crashes while a runner
# is idle / mid-job, the entry lingers as "offline" forever. We write each
# minted runner id to a small JSONL file, and the entrypoint sweeps that
# file on startup to delete anything that's still there.
#
# Usage:
#   runner-store.sh add    <repo_url> <runner_id> <runner_name>
#   runner-store.sh remove <runner_id>
#   runner-store.sh list                     # prints each record as JSON
#   runner-store.sh clear
#
# File: $RUNNER_STATE_FILE (default /var/lib/github-runners/runners.jsonl)

set -uo pipefail

STORE_FILE="${RUNNER_STATE_FILE:-/var/lib/github-runners/runners.jsonl}"
LOCK_FILE="${STORE_FILE}.lock"

mkdir -p "$(dirname "$STORE_FILE")"
: >> "$STORE_FILE"
: >> "$LOCK_FILE"

cmd="${1:-}"
shift || true

case "$cmd" in
    add)
        repo_url="$1"; runner_id="$2"; runner_name="$3"
        flavor="${RUNNER_IMAGE_FLAVOR:-}"
        [[ -z "$runner_id" ]] && exit 0
        line="$(jq -nc \
            --arg repo_url "$repo_url" \
            --arg name     "$runner_name" \
            --arg flavor   "$flavor" \
            --argjson id   "$runner_id" \
            '{repo_url: $repo_url, id: $id, name: $name, flavor: $flavor}')"
        (
            flock -x 9
            printf '%s\n' "$line" >> "$STORE_FILE"
        ) 9>"$LOCK_FILE"
        ;;
    remove)
        runner_id="$1"
        [[ -z "$runner_id" ]] && exit 0
        (
            flock -x 9
            tmp="$(mktemp "${STORE_FILE}.XXXXXX")"
            jq -c --argjson id "$runner_id" \
                'select(.id != $id)' "$STORE_FILE" > "$tmp" || true
            mv "$tmp" "$STORE_FILE"
        ) 9>"$LOCK_FILE"
        ;;
    list)
        (
            flock -s 9
            cat "$STORE_FILE"
        ) 9>"$LOCK_FILE"
        ;;
    clear)
        (
            flock -x 9
            : > "$STORE_FILE"
        ) 9>"$LOCK_FILE"
        ;;
    *)
        echo "runner-store: unknown command: ${cmd}" >&2
        echo "usage: runner-store.sh {add|remove|list|clear} ..." >&2
        exit 2
        ;;
esac

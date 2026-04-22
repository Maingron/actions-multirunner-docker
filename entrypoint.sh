#!/usr/bin/env bash
# Parses $CONFIG_FILE and launches one supervised runner per entry.
# Forwards SIGTERM/SIGINT to all children so `docker stop` is clean.

set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/github-runners/config.yml}"
RUNNERS_BASE="${RUNNERS_BASE:-/home/github-runner}"

if [[ ! -r "$CONFIG_FILE" ]]; then
    echo "entrypoint: config file not readable: $CONFIG_FILE" >&2
    exit 1
fi

# Emit one line per runner, fields separated by ASCII Unit Separator (\x1f)
# so empty fields (e.g. unset token) are preserved by `read`. Tab cannot be
# used because bash treats it as whitespace in IFS and collapses runs of it.
#   title \x1f repo_url \x1f token \x1f workdir \x1f ephemeral \x1f pat \x1f labels \x1f group
# token / workdir / pat may be empty; ephemeral is "1" or "0".
mapfile -t RUNNERS < <(python3 - "$CONFIG_FILE" <<'PY'
import os, sys, yaml

with open(sys.argv[1]) as fh:
    doc = yaml.safe_load(fh) or {}

defaults = doc.get("defaults", {}) or {}
default_ephemeral = bool(defaults.get("ephemeral", True))
default_pat = str(defaults.get("pat", "") or os.environ.get("GITHUB_PAT", "")).strip()
default_labels = str(defaults.get("labels", "") or "self-hosted,linux,x64").strip()
default_group = int(defaults.get("runner_group_id", 1) or 1)

for r in doc.get("runners", []) or []:
    title    = str(r["title"]).strip()
    repo_url = str(r["repo_url"]).strip().rstrip("/")
    if repo_url.endswith(".git"):
        repo_url = repo_url[:-4]
    token    = str(r.get("token", "") or "").strip()
    workdir  = str(r.get("workdir", "") or "").strip().lstrip("/")
    ephemeral = bool(r.get("ephemeral", default_ephemeral))
    pat      = str(r.get("pat", "") or default_pat).strip()
    labels   = str(r.get("labels", "") or default_labels).strip()
    group    = int(r.get("runner_group_id", default_group) or default_group)

    if not title or not repo_url:
        sys.exit(f"invalid runner entry (missing title/repo_url): {r!r}")
    if ephemeral and not pat:
        sys.exit(f"runner {title!r}: ephemeral runners require `pat` "
                 f"(per-runner, defaults.pat, or $GITHUB_PAT)")
    if not ephemeral and not token and not pat:
        sys.exit(f"runner {title!r}: persistent runners need either `token` "
                 f"or a `pat` to fetch one")

    print("\x1f".join([title, repo_url, token, workdir,
                       "1" if ephemeral else "0", pat, labels, str(group)]))
PY
)

if [[ ${#RUNNERS[@]} -eq 0 ]]; then
    echo "entrypoint: no runners defined in $CONFIG_FILE" >&2
    exit 1
fi

echo "entrypoint: starting ${#RUNNERS[@]} runner(s)"

declare -a PIDS=()

shutdown() {
    echo "entrypoint: received shutdown, stopping ${#PIDS[@]} runner(s)"
    for pid in "${PIDS[@]}"; do
        kill -TERM "$pid" 2>/dev/null || true
    done
    wait
    exit 0
}
trap shutdown SIGTERM SIGINT

for line in "${RUNNERS[@]}"; do
    IFS=$'\x1f' read -r title repo_url token workdir ephemeral pat labels group <<<"$line"

    if [[ -z "$workdir" ]]; then
        repo_name="${repo_url##*/}"
        repo_name="${repo_name%.git}"
        workdir="${repo_name}/${title}"
    fi

    runner_dir="${RUNNERS_BASE}/${workdir}"

    EPHEMERAL="$ephemeral" PAT="$pat" \
    RUNNER_LABELS="$labels" RUNNER_GROUP_ID="$group" \
        /usr/local/bin/start-runner.sh \
            "$title" "$repo_url" "$token" "$runner_dir" &
    PIDS+=($!)
done

remaining=${#PIDS[@]}
while (( remaining > 0 )); do
    if wait -n; then :; fi
    remaining=$((remaining - 1))
done

#!/usr/bin/env bash
# Parses $CONFIG_FILE and launches one supervised runner per entry.
# Forwards SIGTERM/SIGINT to all children so `docker stop` is clean.

set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/github-runners/config.yml}"
RUNNERS_BASE="${RUNNERS_BASE:-/home/github-runner}"
RUNNER_STATE_FILE="${RUNNER_STATE_FILE:-/var/lib/github-runners/runners.jsonl}"
export RUNNER_STATE_FILE
# Source template baked into the image (set via Dockerfile ENV).
SOURCE_TEMPLATE_DIR="${TEMPLATE_DIR:-/opt/actions-runner}"
# Staged copy that lives on the same filesystem as the per-runner instance
# dirs, so `cp -al` (hardlink farm) works.
TEMPLATE_DIR="${RUNNERS_BASE}/.template"

if [[ ! -r "$CONFIG_FILE" ]]; then
    echo "entrypoint: config file not readable: $CONFIG_FILE" >&2
    exit 1
fi

# Stage the template onto the same filesystem as the per-runner instance
# dirs. If the image's template lives on an overlay FS and instance dirs
# are on tmpfs, `cp -al` hits EXDEV -- so we copy once here, then every
# runner hardlinks from this staged copy.
if [[ ! -d "$TEMPLATE_DIR" || -z "$(ls -A "$TEMPLATE_DIR" 2>/dev/null || true)" ]]; then
    echo "entrypoint: staging template at $TEMPLATE_DIR"
    mkdir -p "$TEMPLATE_DIR"
    cp -a "$SOURCE_TEMPLATE_DIR/." "$TEMPLATE_DIR/"
fi
export TEMPLATE_DIR

# Emit one line per runner, fields separated by ASCII Unit Separator (\x1f)
# so empty fields (e.g. unset token) are preserved by `read`. Tab cannot be
# used because bash treats it as whitespace in IFS and collapses runs of it.
#   title \x1f repo_url \x1f token \x1f workdir \x1f ephemeral \x1f pat \x1f labels \x1f group \x1f idle_regeneration
# token / workdir / pat may be empty; ephemeral is "1" or "0";
# idle_regeneration is seconds (0 = disabled).
mapfile -t RUNNERS < <(python3 - "$CONFIG_FILE" <<'PY'
import os, sys, yaml

with open(sys.argv[1]) as fh:
    doc = yaml.safe_load(fh) or {}

defaults = doc.get("defaults", {}) or {}
default_ephemeral = bool(defaults.get("ephemeral", True))
default_pat = str(defaults.get("pat", "") or os.environ.get("GITHUB_PAT", "")).strip()
default_labels = str(defaults.get("labels", "") or "self-hosted,linux,x64").strip()
default_group = int(defaults.get("runner_group_id", 1) or 1)
default_idle = int(defaults.get("idle_regeneration", 0) or 0)

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
    idle     = int(r.get("idle_regeneration", default_idle) or 0)

    if not title or not repo_url:
        sys.exit(f"invalid runner entry (missing title/repo_url): {r!r}")
    if ephemeral and not pat:
        sys.exit(f"runner {title!r}: ephemeral runners require `pat` "
                 f"(per-runner, defaults.pat, or $GITHUB_PAT)")
    if not ephemeral and not token and not pat:
        sys.exit(f"runner {title!r}: persistent runners need either `token` "
                 f"or a `pat` to fetch one")

    print("\x1f".join([title, repo_url, token, workdir,
                       "1" if ephemeral else "0", pat, labels, str(group),
                       str(idle)]))
PY
)

if [[ ${#RUNNERS[@]} -eq 0 ]]; then
    echo "entrypoint: no runners defined in $CONFIG_FILE" >&2
    exit 1
fi

# Sweep stale runners from previous container lifetimes. A JIT runner that
# was killed mid-idle or whose container crashed stays in the GitHub UI as
# "offline" forever. We persisted each minted id in $RUNNER_STATE_FILE, so
# iterate that list now and DELETE anything that's still there. The PAT is
# resolved per repo_url from the current config.
declare -A REPO_PAT=()
for line in "${RUNNERS[@]}"; do
    IFS=$'\x1f' read -r _ r_url _ _ _ r_pat _ _ _ <<<"$line"
    [[ -n "$r_pat" ]] && REPO_PAT["$r_url"]="$r_pat"
done

if [[ -s "$RUNNER_STATE_FILE" ]]; then
    stale_total=0
    stale_cleaned=0
    while IFS= read -r rec; do
        [[ -z "$rec" ]] && continue
        stale_total=$((stale_total + 1))
        r_url="$(jq -r '.repo_url' <<<"$rec")"
        r_id="$(jq -r '.id'       <<<"$rec")"
        r_name="$(jq -r '.name'   <<<"$rec")"
        r_pat="${REPO_PAT[$r_url]:-}"
        if [[ -z "$r_pat" ]]; then
            echo "entrypoint: no PAT in config for ${r_url}, skipping stale runner ${r_name} (id=${r_id})" >&2
            continue
        fi
        if /usr/local/bin/delete-runner.sh "$r_url" "$r_pat" "$r_id"; then
            stale_cleaned=$((stale_cleaned + 1))
        fi
    done < <(/usr/local/bin/runner-store.sh list)
    if (( stale_total > 0 )); then
        echo "entrypoint: cleaned ${stale_cleaned}/${stale_total} stale runner(s) from previous run"
    fi
    /usr/local/bin/runner-store.sh clear
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
    IFS=$'\x1f' read -r title repo_url token workdir ephemeral pat labels group idle_regeneration <<<"$line"

    if [[ -z "$workdir" ]]; then
        repo_name="${repo_url##*/}"
        repo_name="${repo_name%.git}"
        workdir="${repo_name}/${title}"
    fi

    runner_dir="${RUNNERS_BASE}/${workdir}"

    EPHEMERAL="$ephemeral" PAT="$pat" \
    RUNNER_LABELS="$labels" RUNNER_GROUP_ID="$group" \
    IDLE_REGENERATION="$idle_regeneration" \
        /usr/local/bin/start-runner.sh \
            "$title" "$repo_url" "$token" "$runner_dir" &
    PIDS+=($!)
done

remaining=${#PIDS[@]}
while (( remaining > 0 )); do
    if wait -n; then :; fi
    remaining=$((remaining - 1))
done

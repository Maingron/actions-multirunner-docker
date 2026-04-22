#!/usr/bin/env bash
# Supervises one GitHub Actions runner.
#
# Two modes:
#
#   EPHEMERAL=1 (default)
#     Uses the "just-in-time runner config" API. No config.sh call, no
#     registration token, no /actions/runner-registration round-trip. A fresh
#     JIT config blob is minted per job and passed straight to ./run.sh via
#     --jitconfig. Runner is inherently one-shot and auto-deregisters.
#     Works with fine-grained PATs (Administration: write).
#     Requires PAT to be set.
#
#   EPHEMERAL=0
#     Classic flow: config.sh registers the runner once, run.sh loops.
#     Uses a registration token (fetched via PAT if provided, otherwise the
#     static `token:` from config.yml).
#
# Env:
#   EPHEMERAL        "1" or "0"  (default "1")
#   PAT              long-lived credential (classic PAT, fine-grained PAT,
#                    GitHub App installation token). Required for ephemeral.
#   RUNNER_LABELS    CSV of labels (default "self-hosted,linux,x64")
#   RUNNER_GROUP_ID  runner group id for JIT config (default 1)

set -uo pipefail

title="$1"
repo_url="$2"
static_token="$3"
runner_dir="$4"

TEMPLATE_DIR="${TEMPLATE_DIR:-/home/github-runner/.template}"
RESTART_DELAY="${RUNNER_RESTART_DELAY:-5}"
EPHEMERAL="${EPHEMERAL:-1}"
PAT="${PAT:-}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux,x64}"
RUNNER_GROUP_ID="${RUNNER_GROUP_ID:-1}"
# Idle-regeneration timeout (seconds). If >0, the ephemeral runner is killed
# and rotated after this many seconds of inactivity (no Runner.Worker).
# 0 = disabled.
IDLE_REGENERATION="${IDLE_REGENERATION:-0}"
IDLE_POLL_INTERVAL="${IDLE_POLL_INTERVAL:-10}"

log() { printf '[%s] %s\n' "$title" "$*"; }

# True iff a Runner.Worker process is currently running for this runner_dir.
# Workers are spawned by Runner.Listener with the runner dir as CWD, so we
# match on /proc/<pid>/cwd to avoid collisions between sibling runners.
worker_active() {
    local pid cwd
    for pid in $(pgrep -x Runner.Worker 2>/dev/null || true); do
        cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null || true)"
        if [[ "$cwd" == "$runner_dir" || "$cwd" == "$runner_dir"/* ]]; then
            return 0
        fi
    done
    return 1
}

materialise() {
    rm -rf "$runner_dir"
    mkdir -p "$(dirname "$runner_dir")"
    # Hardlink farm: same-FS hardlinks keep disk/RAM usage flat regardless
    # of runner count. The template is staged onto the instance FS by
    # entrypoint.sh specifically so this always succeeds -- a symlink
    # fallback would make every runner share the template's state files.
    if ! cp -al "$TEMPLATE_DIR" "$runner_dir"; then
        echo "start-runner: failed to hardlink template ($TEMPLATE_DIR) into $runner_dir" >&2
        echo "start-runner: template must live on the same filesystem as $runner_dir" >&2
        exit 1
    fi
}

get_reg_token() {
    if [[ -n "$PAT" ]]; then
        /usr/local/bin/fetch-token.sh "$repo_url" "$PAT"
    else
        printf '%s\n' "$static_token"
    fi
}

CURRENT_RUNNER_ID=""
JIT_ID_FILE=""

stop_child() {
    if [[ -n "${RUN_PID:-}" ]] && kill -0 "$RUN_PID" 2>/dev/null; then
        kill -TERM "$RUN_PID" 2>/dev/null || true
        wait "$RUN_PID" 2>/dev/null || true
    fi
    if [[ "$EPHEMERAL" == "1" ]]; then
        # JIT runners auto-deregister after a completed job, but if we were
        # killed mid-idle (registered, no job yet) GitHub keeps the entry
        # listed as "offline" forever. Delete it via API.
        if [[ -n "$CURRENT_RUNNER_ID" && -n "$PAT" ]]; then
            log "deregistering JIT runner id=${CURRENT_RUNNER_ID}"
            /usr/local/bin/delete-runner.sh "$repo_url" "$PAT" "$CURRENT_RUNNER_ID" || true
            /usr/local/bin/runner-store.sh remove "$CURRENT_RUNNER_ID" || true
        fi
        [[ -n "$JIT_ID_FILE" ]] && rm -f "$JIT_ID_FILE"
    elif [[ -d "$runner_dir" ]]; then
        # Persistent cleanup: deregister via classic flow.
        local tok
        if tok="$(get_reg_token 2>/dev/null)"; then
            log "deregistering persistent runner"
            (cd "$runner_dir" && ./config.sh remove --token "$tok") >/dev/null 2>&1 || true
        fi
    fi
    exit 0
}
trap stop_child SIGTERM SIGINT

if [[ "$EPHEMERAL" == "1" ]]; then
    if [[ -z "$PAT" ]]; then
        log "ephemeral mode requires a PAT (config.yml 'pat:' or \$GITHUB_PAT)"
        exit 1
    fi

    JIT_ID_FILE="$(mktemp)"

    # Each iteration = one ephemeral runner, one job, full flush.
    iter=0
    while true; do
        iter=$((iter + 1))
        # Unique runner name per registration. GitHub rejects duplicate names
        # within a scope, and ephemeral runners only disappear server-side
        # after the job finishes -- so a pure "$title" would collide if we
        # loop fast.
        runner_name="${title}-$(date +%s)-${iter}"

        log "minting JIT config for ${runner_name}"
        : > "$JIT_ID_FILE"
        if ! jitcfg="$(JITCONFIG_ID_FILE="$JIT_ID_FILE" \
                       /usr/local/bin/fetch-jitconfig.sh \
                        "$repo_url" "$PAT" \
                        "$runner_name" "$RUNNER_LABELS" \
                        "$RUNNER_GROUP_ID")"; then
            log "jitconfig request failed; retrying in ${RESTART_DELAY}s"
            sleep "$RESTART_DELAY"
            continue
        fi
        CURRENT_RUNNER_ID="$(cat "$JIT_ID_FILE" 2>/dev/null || true)"
        if [[ -n "$CURRENT_RUNNER_ID" ]]; then
            /usr/local/bin/runner-store.sh add \
                "$repo_url" "$CURRENT_RUNNER_ID" "$runner_name" || true
        fi

        materialise
        cd "$runner_dir"

        log "running (ephemeral, one job then exit)"
        ./run.sh --jitconfig "$jitcfg" &
        RUN_PID=$!

        # Optional idle watchdog: rotate a runner that's been waiting for a
        # job for too long. Resets whenever a Runner.Worker is seen.
        WATCHDOG_PID=""
        if (( IDLE_REGENERATION > 0 )); then
            (
                last_active=$(date +%s)
                while kill -0 "$RUN_PID" 2>/dev/null; do
                    if worker_active; then
                        last_active=$(date +%s)
                    fi
                    now=$(date +%s)
                    if (( now - last_active >= IDLE_REGENERATION )); then
                        log "idle for ${IDLE_REGENERATION}s, rotating runner"
                        kill -TERM "$RUN_PID" 2>/dev/null || true
                        exit 0
                    fi
                    sleep "$IDLE_POLL_INTERVAL"
                done
            ) &
            WATCHDOG_PID=$!
        fi

        wait "$RUN_PID" || true
        unset RUN_PID
        if [[ -n "$WATCHDOG_PID" ]]; then
            kill "$WATCHDOG_PID" 2>/dev/null || true
            wait "$WATCHDOG_PID" 2>/dev/null || true
            WATCHDOG_PID=""
        fi

        # Always best-effort deregister. If a job completed the runner is
        # already gone server-side (delete-runner.sh treats 404 as success);
        # if we killed it on idle / crash, this cleans up the "offline"
        # entry. Also drop it from the persistent store so a future startup
        # sweep doesn't retry.
        if [[ -n "$CURRENT_RUNNER_ID" ]]; then
            if [[ -n "$PAT" ]]; then
                /usr/local/bin/delete-runner.sh "$repo_url" "$PAT" "$CURRENT_RUNNER_ID" || true
            fi
            /usr/local/bin/runner-store.sh remove "$CURRENT_RUNNER_ID" || true
        fi
        CURRENT_RUNNER_ID=""

        log "runner exited, flushing state"
        sleep "$RESTART_DELAY"
    done
else
    # Persistent runner: register once, keep run.sh alive across jobs.
    materialise
    cd "$runner_dir"

    register_persistent() {
        local tok
        if ! tok="$(get_reg_token)"; then
            log "could not obtain registration token"
            return 1
        fi
        log "config.sh --url $repo_url"
        ./config.sh \
            --unattended --replace \
            --url    "$repo_url" \
            --token  "$tok" \
            --name   "$title" \
            --work   "_work" \
            --labels "$RUNNER_LABELS"
    }

    log "registering (persistent)"
    until register_persistent; do
        log "registration failed; retrying in ${RESTART_DELAY}s"
        sleep "$RESTART_DELAY"
    done

    while true; do
        log "running (persistent)"
        ./run.sh &
        RUN_PID=$!
        wait "$RUN_PID" || true
        unset RUN_PID
        log "run.sh exited; restarting in ${RESTART_DELAY}s"
        sleep "$RESTART_DELAY"
    done
fi

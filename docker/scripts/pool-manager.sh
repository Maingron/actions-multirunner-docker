#!/usr/bin/env bash
# Pool manager for a single runner config entry. Maintains a dynamic set of
# start-runner.sh supervisors so that there are always at least
# POOL_HEADROOM *idle* (free) workers ready to pick up a job, subject to
# POOL_MIN / POOL_MAX bounds.
#
#   desired = clamp(busy + POOL_HEADROOM, POOL_MIN, POOL_MAX)
#
# `busy` is the number of instances that currently have a Runner.Worker
# live under their runner_dir. Every tick:
#   * if alive < desired -> spawn (headroom is being eaten by jobs)
#   * if alive > desired -> drain idle instances (busy ones are never
#                           interrupted mid-job)
#
# Args (same as start-runner.sh): <title> <repo_url> <token> <workdir>
#
# Env (on top of start-runner.sh's env):
#   POOL_MIN           floor -- never go below this many workers alive
#                      (default 1), regardless of load.
#   POOL_MAX           ceiling -- never exceed this many workers alive
#                      (default POOL_MIN).
#   POOL_HEADROOM      minimum number of IDLE workers to keep ready at
#                      all times (default 0). When fewer than this many
#                      workers are free, new ones are spawned up to
#                      POOL_MAX. 0 = no auto-scale beyond POOL_MIN.
#   POOL_POLL_INTERVAL seconds between scale evaluations (default 15)
#
# When POOL_MIN == POOL_MAX == 1 the pool runs a single supervisor with
# the original title / workdir unchanged (backwards compatible). Otherwise
# each instance gets a 2-digit suffix: `<title>-01`, `<workdir>-01`, etc.
#
# Scale-down policy: only idle instances (no live Runner.Worker) are sent
# SIGTERM; busy instances are never interrupted mid-job. If all instances
# are busy the pool simply stays at its current size until one drains.

set -uo pipefail

base_title="$1"
repo_url="$2"
static_token="$3"
base_workdir="$4"

POOL_MIN="${POOL_MIN:-1}"
POOL_MAX="${POOL_MAX:-$POOL_MIN}"
POOL_HEADROOM="${POOL_HEADROOM:-0}"
POOL_POLL_INTERVAL="${POOL_POLL_INTERVAL:-5}"
# Log every tick's (busy/alive/desired) state even when no action is
# taken. Off by default (noisy); set POOL_VERBOSE=1 to enable.
POOL_VERBOSE="${POOL_VERBOSE:-0}"

if ! [[ "$POOL_MIN"      =~ ^[0-9]+$ ]]; then POOL_MIN=1; fi
if ! [[ "$POOL_MAX"      =~ ^[0-9]+$ ]]; then POOL_MAX="$POOL_MIN"; fi
if ! [[ "$POOL_HEADROOM" =~ ^[0-9]+$ ]]; then POOL_HEADROOM=0; fi
(( POOL_MIN < 1 ))          && POOL_MIN=1
(( POOL_MAX < POOL_MIN ))   && POOL_MAX=$POOL_MIN

SINGLETON=0
if (( POOL_MIN == 1 && POOL_MAX == 1 && POOL_HEADROOM == 0 )); then
    SINGLETON=1
fi

declare -A PIDS=()   # idx -> pid
declare -A DIRS=()   # idx -> runner_dir

log() { printf '[pool:%s] %s\n' "$base_title" "$*"; }

instance_title() {
    local idx="$1"
    if (( SINGLETON == 1 )); then
        printf '%s' "$base_title"
    else
        printf '%s-%02d' "$base_title" "$idx"
    fi
}

instance_dir() {
    local idx="$1"
    if (( SINGLETON == 1 )); then
        printf '%s' "$base_workdir"
    else
        printf '%s-%02d' "$base_workdir" "$idx"
    fi
}

# True iff a Runner.Worker process has its cwd under $1. Scans /proc
# directly so this works even if `pgrep`/procps isn't installed in the
# container. Matches on the kernel's 15-char `comm` (TASK_COMM_LEN-1),
# which fits "Runner.Worker" (13 chars) fully.
worker_active_in_dir() {
    local dir="$1" pid comm cwd
    for pid_dir in /proc/[0-9]*; do
        [[ -r "$pid_dir/comm" ]] || continue
        read -r comm < "$pid_dir/comm" 2>/dev/null || continue
        [[ "$comm" == "Runner.Worker" ]] || continue
        cwd="$(readlink "$pid_dir/cwd" 2>/dev/null || true)"
        if [[ -n "$cwd" && ( "$cwd" == "$dir" || "$cwd" == "$dir"/* ) ]]; then
            return 0
        fi
    done
    return 1
}

find_free_idx() {
    local i
    for ((i = 1; i <= POOL_MAX; i++)); do
        [[ -z "${PIDS[$i]:-}" ]] && { printf '%s' "$i"; return 0; }
    done
    return 1
}

spawn_instance() {
    local idx
    if ! idx="$(find_free_idx)"; then
        return 1
    fi
    local title dir
    title="$(instance_title "$idx")"
    dir="$(instance_dir "$idx")"
    log "spawning instance ${idx} (title=${title})"
    /usr/local/bin/start-runner.sh "$title" "$repo_url" "$static_token" "$dir" &
    PIDS[$idx]=$!
    DIRS[$idx]="$dir"
}

reap_dead() {
    local idx
    for idx in "${!PIDS[@]}"; do
        if ! kill -0 "${PIDS[$idx]}" 2>/dev/null; then
            wait "${PIDS[$idx]}" 2>/dev/null || true
            log "instance ${idx} exited"
            unset 'PIDS[$idx]' 'DIRS[$idx]'
        fi
    done
}

shutdown() {
    log "shutting down pool (${#PIDS[@]} instance(s))"
    local pid
    for pid in "${PIDS[@]}"; do
        kill -TERM "$pid" 2>/dev/null || true
    done
    wait
    exit 0
}
trap shutdown SIGTERM SIGINT

log "starting pool (min=${POOL_MIN} max=${POOL_MAX} headroom=${POOL_HEADROOM})"

# Initial fill to POOL_MIN.
for ((i = 0; i < POOL_MIN; i++)); do
    spawn_instance || break
done

# Main scale loop.
while true; do
    # Non-blocking sleep so the SIGTERM trap fires promptly.
    sleep "$POOL_POLL_INTERVAL" &
    wait $! 2>/dev/null || true

    reap_dead

    busy=0
    idle_idxs=()
    for idx in "${!PIDS[@]}"; do
        if worker_active_in_dir "${DIRS[$idx]}"; then
            busy=$((busy + 1))
        else
            idle_idxs+=("$idx")
        fi
    done
    alive=${#PIDS[@]}

    desired=$((busy + POOL_HEADROOM))
    (( desired < POOL_MIN )) && desired=$POOL_MIN
    (( desired > POOL_MAX )) && desired=$POOL_MAX

    if (( POOL_VERBOSE == 1 )); then
        log "tick: busy=${busy} idle=$((alive - busy)) alive=${alive} desired=${desired} (min=${POOL_MIN} max=${POOL_MAX} headroom=${POOL_HEADROOM})"
    fi

    if (( alive < desired )); then
        need=$((desired - alive))
        log "scale up: busy=${busy} alive=${alive} -> spawning ${need} (desired=${desired})"
        for ((k = 0; k < need; k++)); do
            spawn_instance || break
        done
    elif (( alive > desired )); then
        excess=$((alive - desired))
        # Only drain idle instances; busy ones keep running until their
        # current job finishes (then they'll be reaped on the next tick
        # in ephemeral mode, or stay alive in persistent mode).
        for idx in "${idle_idxs[@]}"; do
            (( excess <= 0 )) && break
            log "scale down: draining idle instance ${idx} (pid=${PIDS[$idx]})"
            kill -TERM "${PIDS[$idx]}" 2>/dev/null || true
            excess=$((excess - 1))
        done
    fi
done

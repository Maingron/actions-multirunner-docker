#!/usr/bin/env bash
# In-container runner status probe. Emits one JSON object per runner
# matching this container's $RUNNER_IMAGE_FLAVOR, one per line. Consumed
# by ../status.sh on the host.
#
# Per-runner fields:
#   title, repo_url, workdir, labels, ephemeral, image
#   sup_pid     -- pid of start-runner.sh supervising this title (or null)
#   listener    -- Runner.Listener with cwd under runner_dir (bool)
#   worker      -- Runner.Worker   with cwd under runner_dir (bool)
#   watchdog    -- per-runner watchdog enabled? (bool)
#   idle_regeneration -- seconds, 0 if disabled
#   api         -- null if no PAT, else {reachable, matches:[{id,name,status,busy}]}
#                  (matched by "<title>-" prefix for ephemeral, exact for
#                  persistent)

set -uo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/github-runners/config.yml}"
RUNNERS_BASE="${RUNNERS_BASE:-/home/github-runner}"
FLAVOR="${RUNNER_IMAGE_FLAVOR:-}"

[[ -r "$CONFIG_FILE" ]] || exit 0

mapfile -t RUNNERS < <(/usr/local/bin/parse-config.sh "$CONFIG_FILE" 2>/dev/null || true)

# -- process index -----------------------------------------------------------
# Single pass over /proc for supervisor / listener / worker detection.

declare -A SUP_BY_TITLE=()
declare -a LISTENER_PIDS=()
declare -a WORKER_PIDS=()

for d in /proc/[0-9]*; do
    pid="${d##*/}"

    if [[ -r "$d/cmdline" ]]; then
        mapfile -d '' -t argv < "$d/cmdline" 2>/dev/null || argv=()
        if (( ${#argv[@]} >= 2 )); then
            # Match both  `start-runner.sh <title> ...`  and
            #             `bash /usr/local/bin/start-runner.sh <title> ...`
            if [[ "${argv[0]}" == */start-runner.sh ]]; then
                t="${argv[1]}"
                [[ -n "$t" ]] && SUP_BY_TITLE["$t"]="$pid"
            elif [[ "${argv[1]:-}" == */start-runner.sh ]] && (( ${#argv[@]} >= 3 )); then
                t="${argv[2]}"
                [[ -n "$t" ]] && SUP_BY_TITLE["$t"]="$pid"
            fi
        fi
    fi

    if [[ -r "$d/comm" ]]; then
        comm=""
        read -r comm < "$d/comm" 2>/dev/null || true
        case "$comm" in
            Runner.Listener) LISTENER_PIDS+=("$pid") ;;
            Runner.Worker)   WORKER_PIDS+=("$pid")   ;;
        esac
    fi
done

pid_cwd_under() {
    local pid="$1" dir="$2" cwd
    cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null || true)"
    [[ -n "$cwd" && ( "$cwd" == "$dir" || "$cwd" == "$dir"/* ) ]]
}

any_under() {
    local dir="$1"; shift
    local p
    for p in "$@"; do
        pid_cwd_under "$p" "$dir" && return 0
    done
    return 1
}

# -- GitHub API (cached per repo_url) ---------------------------------------

declare -A API_BODY=()
declare -A API_OK=()

api_fetch() {
    local repo_url="$1" pat="$2"
    [[ -n "${API_BODY[$repo_url]+x}" ]] && return 0

    local path owner rest endpoint code body tmp
    path="${repo_url#*://}"; path="${path#*/}"; path="${path%/}"; path="${path%.git}"
    owner="${path%%/*}"; rest="${path#*/}"
    if [[ "$rest" == "$owner" || -z "$rest" ]]; then
        endpoint="https://api.github.com/orgs/${owner}/actions/runners?per_page=100"
    else
        endpoint="https://api.github.com/repos/${owner}/${rest%%/*}/actions/runners?per_page=100"
    fi

    tmp="$(mktemp)"
    code="$(curl -sS --max-time 6 -o "$tmp" -w '%{http_code}' \
        -H "Authorization: Bearer $pat" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "$endpoint" 2>/dev/null || echo 000)"
    body="$(cat "$tmp" 2>/dev/null || true)"
    rm -f "$tmp"

    if [[ "$code" == "200" ]]; then
        API_BODY[$repo_url]="$body"
        API_OK[$repo_url]=1
    else
        API_BODY[$repo_url]=""
        API_OK[$repo_url]=0
    fi
}

# -- emit one record per runner ---------------------------------------------

for line in "${RUNNERS[@]}"; do
    [[ -z "$line" ]] && continue
    IFS=$'\x1f' read -r title repo_url token workdir ephemeral pat \
                       labels group idle_regen image startup_script \
                       add_pkgs wd_enabled wd_interval <<<"$line"

    # Only report runners that target this container's image flavor.
    [[ -n "$FLAVOR" && "$image" != "$FLAVOR" ]] && continue

    if [[ -z "$workdir" ]]; then
        repo_name="${repo_url##*/}"; repo_name="${repo_name%.git}"
        workdir="${repo_name}/${title}"
    fi
    runner_dir="${RUNNERS_BASE}/${workdir}"

    sup_pid="${SUP_BY_TITLE[$title]:-}"
    listener=false; worker=false
    any_under "$runner_dir" "${LISTENER_PIDS[@]:-}" && listener=true
    any_under "$runner_dir" "${WORKER_PIDS[@]:-}"   && worker=true

    api_json='null'
    eff_pat="${pat:-${GITHUB_PAT:-}}"
    if [[ -n "$eff_pat" ]]; then
        api_fetch "$repo_url" "$eff_pat"
        if [[ "${API_OK[$repo_url]:-0}" == "1" ]]; then
            body="${API_BODY[$repo_url]}"
            if [[ "$ephemeral" == "1" ]]; then
                matches="$(jq -c --arg prefix "${title}-" '
                    [.runners[]? | select(.name | startswith($prefix)) |
                     {id, name, status, busy}]' <<<"$body" 2>/dev/null || echo '[]')"
            else
                matches="$(jq -c --arg name "$title" '
                    [.runners[]? | select(.name == $name) |
                     {id, name, status, busy}]' <<<"$body" 2>/dev/null || echo '[]')"
            fi
            api_json="$(jq -nc --argjson m "$matches" \
                '{reachable:true, matches:$m}')"
        else
            api_json='{"reachable":false,"matches":[]}'
        fi
    fi

    jq -nc \
        --arg title "$title" \
        --arg repo_url "$repo_url" \
        --arg workdir "$runner_dir" \
        --arg labels "$labels" \
        --arg ephemeral "$ephemeral" \
        --arg image "$image" \
        --arg sup_pid "$sup_pid" \
        --arg wd_enabled "$wd_enabled" \
        --arg idle_regen "$idle_regen" \
        --argjson listener "$listener" \
        --argjson worker "$worker" \
        --argjson api "$api_json" \
        '{
          title:$title, repo_url:$repo_url, workdir:$workdir, labels:$labels,
          ephemeral:($ephemeral=="1"), image:$image,
          sup_pid:(if $sup_pid == "" then null else ($sup_pid|tonumber) end),
          listener:$listener, worker:$worker,
          watchdog:($wd_enabled=="1"),
          idle_regeneration:(if $idle_regen == "" then 0 else ($idle_regen|tonumber) end),
          api:$api
        }'
done

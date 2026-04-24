#!/usr/bin/env bash
# Pretty runner status dashboard.
#
# Usage (from repo root):
#   ./start.sh status              # one-shot colored table
#   ./start.sh status --watch      # live, auto-refreshing view (Ctrl-C to exit)
#   ./start.sh status --watch 5    # custom refresh interval (seconds)
#   ./start.sh status --json       # machine-readable, one JSON object/runner
#   ./start.sh status --plain      # no colors

set -uo pipefail

cd "$(dirname "$0")/.."

COMPOSE_FILE="docker/docker-compose.yml"

MODE="pretty"
WATCH=0
WATCH_INTERVAL=3

while (( $# > 0 )); do
    case "$1" in
        --json)   MODE="json";  shift ;;
        --plain)  MODE="plain"; shift ;;
        --watch|-w)
            WATCH=1
            if [[ "${2:-}" =~ ^[0-9]+$ ]]; then
                WATCH_INTERVAL="$2"; shift
            fi
            shift
            ;;
        -h|--help)
            cat <<EOF
Usage: ./start.sh status [--watch [N]] [--json|--plain]

  (default)         one-shot colored table
  --watch [N]       refresh every N seconds (default 2), Ctrl-C to exit
  --json            machine-readable (one JSON object per runner per line)
  --plain           no ANSI colors
EOF
            exit 0
            ;;
        *) echo "status: unknown argument: $1" >&2; exit 2 ;;
    esac
done

[[ -f "$COMPOSE_FILE" ]] || ./docker/render.sh >/dev/null

# --- colors -----------------------------------------------------------------

init_colors() {
    if [[ "$MODE" == "pretty" && -t 1 ]]; then
        C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
        C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'
        C_BLUE=$'\e[34m'; C_MAGENTA=$'\e[35m'; C_CYAN=$'\e[36m'; C_GREY=$'\e[90m'
        C_RESET=$'\e[0m'
    else
        C_BOLD=; C_DIM=; C_RED=; C_GREEN=; C_YELLOW=; C_BLUE=; C_MAGENTA=; C_CYAN=; C_GREY=; C_RESET=
    fi
}
init_colors

# --- helpers ----------------------------------------------------------------

# Strip ANSI so we can compute visible width.
_strip_ansi() { sed $'s/\x1b\\[[0-9;]*m//g' <<<"$1"; }

# Truncate visible text (ANSI-safe) to $2 chars with '…' if overflowing.
trunc() {
    local text="$1" max="$2" plain
    plain="$(_strip_ansi "$text")"
    if (( ${#plain} <= max )); then
        printf '%s' "$text"
        return
    fi
    # Can't safely truncate colored text mid-sequence; fall back to plain.
    printf '%s…' "${plain:0:max-1}"
}

# Pad ANSI-colored text to visible width $2.
pad_r() {
    local text="$1" width="$2" plain n
    plain="$(_strip_ansi "$text")"
    n=$(( width - ${#plain} ))
    (( n < 0 )) && n=0
    printf '%s%*s' "$text" "$n" ""
}

fmt_duration() {
    local s="$1"
    (( s < 0 )) && s=0
    if   (( s < 60 ));    then printf '%ds'     "$s"
    elif (( s < 3600 ));  then printf '%dm%ds'  $((s/60))    $((s%60))
    elif (( s < 86400 )); then printf '%dh%dm'  $((s/3600))  $(((s%3600)/60))
    else                       printf '%dd%dh'  $((s/86400)) $(((s%86400)/3600))
    fi
}

hr() {
    local ch="${1:-─}" w="${2:-78}" i out=""
    for (( i=0; i<w; i++ )); do out+="$ch"; done
    printf '%s' "$out"
}

term_width() {
    local w
    w="$(tput cols 2>/dev/null || echo)"
    [[ -z "$w" || ! "$w" =~ ^[0-9]+$ ]] && w="${COLUMNS:-100}"
    (( w < 60 )) && w=60
    printf '%s' "$w"
}

# --- data collection --------------------------------------------------------

collect_containers_json() {
    # Emit one JSON object per container service: { service, container,
    # flavor, state, started_at, restarts, runners:[...] }
    local services_json svc cname flavor
    services_json="$(docker compose -f "$COMPOSE_FILE" config --format json 2>/dev/null || echo '{}')"

    jq -r '
        .services // {} | to_entries[] |
        "\(.key)\t\(.value.container_name // .key)\t\(.value.environment.RUNNER_IMAGE_FLAVOR // "")"
    ' <<<"$services_json" 2>/dev/null | while IFS=$'\t' read -r svc cname flavor; do
        [[ -z "$svc" ]] && continue

        local inspect state started_at restarts runners_json=""
        inspect="$(docker inspect --format \
            '{{.State.Status}}|{{.State.StartedAt}}|{{.RestartCount}}' \
            "$cname" 2>/dev/null || true)"
        if [[ -z "$inspect" ]]; then
            state="missing"; started_at=""; restarts=0
        else
            state="${inspect%%|*}"
            local rest="${inspect#*|}"
            started_at="${rest%%|*}"
            restarts="${rest##*|}"
        fi

        if [[ "$state" == "running" ]]; then
            runners_json="$(docker exec "$cname" /usr/local/bin/status.sh 2>/dev/null || true)"
        fi

        jq -nc \
            --arg svc "$svc" --arg cname "$cname" --arg flavor "$flavor" \
            --arg state "$state" --arg started_at "$started_at" \
            --arg restarts "$restarts" --arg runners "$runners_json" \
            '{service:$svc, container:$cname, flavor:$flavor, state:$state,
              started_at:$started_at, restarts:($restarts|tonumber? // 0),
              runners:($runners|split("\n")|map(select(length>0)|fromjson? // empty))}'
    done
}

# --- classification (pure, no side effects) --------------------------------
# Echoes:  <kind> <colored_label>
#   kind = idle | busy | down | starting
classify_runner() {
    local sup="$1" listener="$2" worker="$3" api_busy="$4"

    if [[ "$sup" == "null" || -z "$sup" ]]; then
        printf 'down\t%s○ down%s' "$C_RED" "$C_RESET"; return
    fi
    if [[ "$worker" == "true" ]] || (( api_busy > 0 )); then
        printf 'busy\t%s● busy%s' "$C_CYAN" "$C_RESET"; return
    fi
    if [[ "$listener" == "true" ]]; then
        printf 'idle\t%s● idle%s' "$C_GREEN" "$C_RESET"; return
    fi
    printf 'starting\t%s◐ start%s' "$C_YELLOW" "$C_RESET"
}

# Echoes colored "online · N reg" / "busy" / "offline" / etc.
fmt_api_cell() {
    local api_json="$1" ephemeral="$2"
    if [[ "$api_json" == "null" ]]; then
        printf '%s—%s' "$C_DIM" "$C_RESET"; return
    fi
    local reachable matches_n online_n busy_n
    reachable="$(jq -r '.reachable' <<<"$api_json")"
    if [[ "$reachable" != "true" ]]; then
        printf '%sunreachable%s' "$C_RED" "$C_RESET"; return
    fi
    matches_n="$(jq -r '.matches | length' <<<"$api_json")"
    online_n="$(jq   -r '[.matches[]|select(.status=="online")]|length' <<<"$api_json")"
    busy_n="$(jq     -r '[.matches[]|select(.busy==true)]|length'       <<<"$api_json")"
    if (( matches_n == 0 )); then
        printf '%sno regs%s' "$C_DIM" "$C_RESET"; return
    fi

    local word color
    if   (( busy_n   > 0 )); then word="busy";    color="$C_CYAN"
    elif (( online_n > 0 )); then word="online";  color="$C_GREEN"
    else                         word="offline"; color="$C_YELLOW"
    fi

    printf '%s%s%s' "$color" "$word" "$C_RESET"
}

# --- render -----------------------------------------------------------------

render_dashboard() {
    local COLS; COLS="$(term_width)"
    # Horizontal rules sit after a 2-space indent; keep them from wrapping.
    local BAR_W=$(( COLS - 4 ))
    (( BAR_W > 96 )) && BAR_W=96
    (( BAR_W < 40 )) && BAR_W=40

    # Column widths. Title grows with viewport; REPO only shows on wide terms.
    local W_TITLE=24 W_STATUS=10 W_JOB=10 W_REPO=0
    (( COLS >= 110 )) && W_TITLE=32
    (( COLS >= 130 )) && W_TITLE=40
    # REPO column only when there's ~20 chars of slack over the baseline.
    if (( COLS >= 140 )); then W_REPO=30
    elif (( COLS >= 120 )); then W_REPO=24
    fi
    (( COLS >= 160 )) && W_REPO=36

    # Collect data first so our counters survive.
    local -a CONTAINERS=()
    while IFS= read -r rec; do
        [[ -n "$rec" ]] && CONTAINERS+=("$rec")
    done < <(collect_containers_json)

    local container_total=${#CONTAINERS[@]}
    local container_up=0 container_down=0
    local total_runners=0 total_idle=0 total_busy=0 total_down=0 total_start=0

    # Header.
    local now_str; now_str="$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf '\n'
    printf '  %s%sgithub-multirunner%s  %s· %s%s' \
        "$C_BOLD" "$C_MAGENTA" "$C_RESET" "$C_DIM" "$now_str" "$C_RESET"
    if (( WATCH )); then
        printf '  %s(refresh %ds · Ctrl-C to exit)%s' "$C_DIM" "$WATCH_INTERVAL" "$C_RESET"
    fi
    printf '\n  %s%s%s\n' "$C_GREY" "$(hr '━' "$BAR_W")" "$C_RESET"

    if (( container_total == 0 )); then
        printf '\n  %sNo containers defined. Run ./start.sh to build + start.%s\n\n' \
            "$C_YELLOW" "$C_RESET"
        return
    fi

    local rec
    for rec in "${CONTAINERS[@]}"; do
        local cname state started_at restarts flavor runners_n
        cname="$(jq -r '.container'     <<<"$rec")"
        state="$(jq -r '.state'         <<<"$rec")"
        started_at="$(jq -r '.started_at' <<<"$rec")"
        restarts="$(jq -r '.restarts'   <<<"$rec")"
        flavor="$(jq -r '.flavor'       <<<"$rec")"
        runners_n="$(jq -r '.runners|length' <<<"$rec")"

        # Container header.
        local dot label uptime=""
        case "$state" in
            running)
                dot="${C_GREEN}●${C_RESET}"; label="${C_GREEN}${C_BOLD}UP${C_RESET}"
                container_up=$(( container_up + 1 ))
                if [[ -n "$started_at" && "$started_at" != "0001-01-01T00:00:00Z" ]]; then
                    local s_e n_e
                    s_e="$(date -d "$started_at" +%s 2>/dev/null || echo 0)"
                    n_e="$(date +%s)"
                    (( s_e > 0 )) && uptime="$(fmt_duration $(( n_e - s_e )))"
                fi
                ;;
            missing)
                dot="${C_DIM}○${C_RESET}"; label="${C_DIM}NOT CREATED${C_RESET}"
                container_down=$(( container_down + 1 )) ;;
            exited|dead)
                dot="${C_RED}○${C_RESET}"; label="${C_RED}${C_BOLD}DOWN${C_RESET}"
                container_down=$(( container_down + 1 )) ;;
            restarting)
                dot="${C_YELLOW}◐${C_RESET}"; label="${C_YELLOW}${C_BOLD}RESTARTING${C_RESET}"
                container_down=$(( container_down + 1 )) ;;
            paused|created)
                local up; up="$(printf '%s' "$state" | tr '[:lower:]' '[:upper:]')"
                dot="${C_YELLOW}○${C_RESET}"; label="${C_YELLOW}${C_BOLD}${up}${C_RESET}"
                container_down=$(( container_down + 1 )) ;;
            *)
                local up; up="$(printf '%s' "$state" | tr '[:lower:]' '[:upper:]')"
                dot="${C_RED}○${C_RESET}"; label="${C_RED}${up}${C_RESET}"
                container_down=$(( container_down + 1 )) ;;
        esac

        # Container header shares the same column grid as runner rows.
        # Runner indent = 6 spaces; container indent = "  ● " = 4 chars.
        # => pad cname to (W_TITLE + 2) so STATUS/UP land in the same col.
        local cname_disp
        cname_disp="$(trunc "${C_BOLD}${cname}${C_RESET}" $(( W_TITLE + 1 )))"
        printf '\n  %s ' "$dot"
        pad_r "$cname_disp" $(( W_TITLE + 2 ))
        pad_r "$label"      "$W_STATUS"
        if [[ -n "$uptime" ]]; then
            printf '%s%-12s%s' "$C_DIM" "$uptime" "$C_RESET"
        fi
        if [[ "$restarts" != "0" && "$state" == "running" ]]; then
            printf ' %s%s restarts%s' "$C_YELLOW" "$restarts" "$C_RESET"
        fi
        printf '\n'

        [[ "$state" != "running" ]] && continue
        (( runners_n == 0 )) && continue

        local i
        for (( i=0; i<runners_n; i++ )); do
            local r title eph sup listener worker api api_busy repo_url repo_short
            r="$(jq -c ".runners[$i]" <<<"$rec")"
            title="$(jq -r     '.title'     <<<"$r")"
            eph="$(jq -r       '.ephemeral' <<<"$r")"
            repo_url="$(jq -r  '.repo_url'  <<<"$r")"
            sup="$(jq -r       '.sup_pid // "null"' <<<"$r")"
            listener="$(jq -r  '.listener'  <<<"$r")"
            worker="$(jq -r    '.worker'    <<<"$r")"
            api="$(jq -c       '.api'       <<<"$r")"

            # Strip scheme + host, leaving "owner/repo" or "owner" (org).
            repo_short="${repo_url#*://}"
            repo_short="${repo_short#*/}"
            repo_short="${repo_short%/}"
            repo_short="${repo_short%.git}"

            if [[ "$api" != "null" ]]; then
                api_busy="$(jq -r '[.matches[]?|select(.busy==true)]|length' <<<"$api")"
            else
                api_busy=0
            fi

            # classify without a subshell losing counters
            local classification kind status_txt
            classification="$(classify_runner "$sup" "$listener" "$worker" "$api_busy")"
            kind="${classification%%$'\t'*}"
            status_txt="${classification#*$'\t'}"

            case "$kind" in
                idle)     total_idle=$((  total_idle  + 1 )) ;;
                busy)     total_busy=$((  total_busy  + 1 )) ;;
                down)     total_down=$((  total_down  + 1 )) ;;
                starting) total_start=$(( total_start + 1 )) ;;
            esac
            total_runners=$(( total_runners + 1 ))

            local job_txt
            if [[ "$worker" == "true" ]]; then
                job_txt="${C_CYAN}● running${C_RESET}"
            else
                job_txt="${C_DIM}—${C_RESET}"
            fi

            local title_disp
            title_disp="$(trunc "${C_BOLD}${title}${C_RESET}" $(( W_TITLE - 1 )))"

            # Column order: TITLE  STATUS  API  JOB  [REPO]
            printf '      '
            pad_r "$title_disp" "$W_TITLE"
            pad_r "$status_txt" "$W_STATUS"
            # API cell has variable width; pad it to a fixed column so JOB
            # lines up across rows.
            local api_cell
            api_cell="$(fmt_api_cell "$api" "$eph")"
            pad_r "$api_cell"   12
            pad_r "$job_txt"    "$W_JOB"
            if (( W_REPO > 0 )); then
                local repo_disp
                repo_disp="$(trunc "${C_DIM}${repo_short}${C_RESET}" $(( W_REPO - 1 )))"
                pad_r "$repo_disp" "$W_REPO"
            fi
            printf '\n'
        done
    done

    # Footer: one compact summary line.
    printf '\n  %s%s%s\n' "$C_GREY" "$(hr '━' "$BAR_W")" "$C_RESET"
    printf '  %s%d runners%s  %s%d idle%s  %s%d busy%s  %s%d starting%s  %s%d down%s   %s· %d/%d containers up%s\n\n' \
        "$C_BOLD" "$total_runners" "$C_RESET" \
        "$C_GREEN"  "$total_idle"  "$C_RESET" \
        "$C_CYAN"   "$total_busy"  "$C_RESET" \
        "$C_YELLOW" "$total_start" "$C_RESET" \
        "$C_RED"    "$total_down"  "$C_RESET" \
        "$C_DIM"    "$container_up" "$container_total" "$C_RESET"
}

# --- JSON mode --------------------------------------------------------------

render_json() {
    local rec
    while IFS= read -r rec; do
        [[ -z "$rec" ]] && continue
        jq -c '. as $c | .runners[] |
               . + {container:$c.container, flavor:$c.flavor,
                    container_state:$c.state}' <<<"$rec"
    done < <(collect_containers_json)
}

# --- dispatch ---------------------------------------------------------------

if [[ "$MODE" == "json" ]]; then
    render_json
    exit 0
fi

if (( WATCH == 0 )); then
    render_dashboard
    exit 0
fi

# Watch mode. Two tricks to kill flicker:
#   1. Render the whole frame into a variable first (data collection +
#      all jq + docker calls finish before anything hits the terminal).
#   2. Between frames: cursor-home + "clear to end of screen" (ED 0)
#      instead of "clear screen" (ED 2). ED 2 flashes the background;
#      ED 0 just overwrites from the top and the static parts of the
#      frame stay on-screen the entire time.
if [[ -t 1 ]]; then
    printf '\e[?1049h'            # enter alternate screen buffer
    printf '\e[?25l'              # hide cursor
    cleanup() {
        printf '\e[?25h\e[?1049l' # show cursor + leave alt buffer
    }
    # EXIT cleans up terminal state. INT/TERM additionally exit the loop
    # immediately -- without this, `read -t` eats the signal (returning
    # non-zero) and the `|| true` below would keep us spinning.
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    # SIGWINCH: break the `read -t` sleep so we redraw at the new size.
    trap ':' WINCH
    # Initial wipe of the alt buffer exactly once.
    printf '\e[2J\e[H'
fi

while true; do
    # Collect + format off-screen.
    frame="$(render_dashboard)"
    if [[ -t 1 ]]; then
        # Clear from home down *first* (including any wrapped lines left
        # over from a previous, wider frame), then blit. Two-step so we
        # never see half-cleared garbage.
        printf '\e[H\e[J%s' "$frame"
    else
        printf '%s\n' "$frame"
    fi
    # Interruptible sleep so Ctrl-C and SIGWINCH react immediately.
    read -r -t "$WATCH_INTERVAL" _discard 2>/dev/null </dev/null || true
done

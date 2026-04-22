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

# This container runs one specific base image (e.g. debian:stable-slim,
# ubuntu:24.04). Runners in config.yml can opt into an image via their
# `image:` field; we only launch the ones that match this container.
RUNNER_IMAGE_FLAVOR="${RUNNER_IMAGE_FLAVOR:-debian:stable-slim}"
export RUNNER_IMAGE_FLAVOR

# Emit one line per runner, fields separated by ASCII Unit Separator (\x1f)
# so empty fields (e.g. unset token) are preserved by `read`. Tab cannot be
# used because bash treats it as whitespace in IFS and collapses runs of it.
#   title \x1f repo_url \x1f token \x1f workdir \x1f ephemeral \x1f pat \x1f labels \x1f group \x1f idle_regeneration \x1f image \x1f startup_script \x1f additional_packages
# token / workdir / pat / startup_script / additional_packages may be empty;
# ephemeral is "1" or "0"; idle_regeneration is seconds (0 = disabled);
# image is a flavor name; additional_packages is a space-separated list.
RUNNERS=()
while IFS= read -r __runner_line; do
    [[ -z "$__runner_line" ]] && continue
    RUNNERS+=("$__runner_line")
done < <(/usr/local/bin/parse-config.sh "$CONFIG_FILE")
unset __runner_line

if [[ ${#RUNNERS[@]} -eq 0 ]]; then
    echo "entrypoint: no runners defined in $CONFIG_FILE" >&2
    exit 1
fi

# Keep only runners whose image flavor matches this container.
MATCHED=()
for line in "${RUNNERS[@]}"; do
    IFS=$'\x1f' read -r _ _ _ _ _ _ _ _ _ r_img _ _ <<<"$line"
    if [[ "$r_img" == "$RUNNER_IMAGE_FLAVOR" ]]; then
        MATCHED+=("$line")
    fi
done
RUNNERS=("${MATCHED[@]}")

# Sweep stale runners from previous container lifetimes. A JIT runner that
# was killed mid-idle or whose container crashed stays in the GitHub UI as
# "offline" forever. We persisted each minted id in $RUNNER_STATE_FILE, so
# iterate that list now and DELETE anything that's still there. The PAT is
# resolved per repo_url from the current config. Only sweep entries minted
# by this flavor -- sibling containers handle their own.
declare -A REPO_PAT=()
for line in "${RUNNERS[@]}"; do
    IFS=$'\x1f' read -r _ r_url _ _ _ r_pat _ _ _ _ _ _ <<<"$line"
    [[ -n "$r_pat" ]] && REPO_PAT["$r_url"]="$r_pat"
done

if [[ -s "$RUNNER_STATE_FILE" ]]; then
    stale_total=0
    stale_cleaned=0
    while IFS= read -r rec; do
        [[ -z "$rec" ]] && continue
        r_flavor="$(jq -r '.flavor // ""' <<<"$rec")"
        if [[ -n "$r_flavor" && "$r_flavor" != "$RUNNER_IMAGE_FLAVOR" ]]; then
            continue
        fi
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
            /usr/local/bin/runner-store.sh remove "$r_id" || true
        fi
    done < <(/usr/local/bin/runner-store.sh list)
    if (( stale_total > 0 )); then
        echo "entrypoint[${RUNNER_IMAGE_FLAVOR}]: cleaned ${stale_cleaned}/${stale_total} stale runner(s) from previous run"
    fi
fi

if [[ ${#RUNNERS[@]} -eq 0 ]]; then
    echo "entrypoint[${RUNNER_IMAGE_FLAVOR}]: no runners target this image flavor, idling"
    # Stay alive so `restart: unless-stopped` doesn't thrash. Exit cleanly
    # on SIGTERM.
    trap 'exit 0' SIGTERM SIGINT
    while true; do sleep 3600 & wait $!; done
fi

echo "entrypoint[${RUNNER_IMAGE_FLAVOR}]: starting ${#RUNNERS[@]} runner(s)"

# ---------------------------------------------------------------------------
# Install `additional_packages` from config.yml.
#
# Every runner can list packages to install; we merge the full set across
# runners (deduped), skip anything already installed in a previous run,
# and hand the remainder to install-packages.sh -- which autodetects the
# container's package manager (apt/dnf/apk/zypper/pacman/...).
#
# Progress is recorded in $PKGS_DONE_FILE on the `runner-state` volume so
# container restarts do not re-install what's already there. Wipe the
# volume (`docker compose down -v`) to force a re-install.
# ---------------------------------------------------------------------------
PKGS_DONE_FILE="${PKGS_DONE_FILE:-/var/lib/github-runners/packages.done}"
touch "$PKGS_DONE_FILE" 2>/dev/null || sudo -n touch "$PKGS_DONE_FILE" || true

declare -A PKG_SEEN=()
declare -a PKGS_TO_INSTALL=()
for line in "${RUNNERS[@]}"; do
    IFS=$'\x1f' read -r _ _ _ _ _ _ _ _ _ _ _ r_pkgs <<<"$line"
    [[ -z "$r_pkgs" ]] && continue
    for pkg in $r_pkgs; do
        [[ -n "${PKG_SEEN[$pkg]:-}" ]] && continue
        PKG_SEEN["$pkg"]=1
        if grep -qxF "$pkg" "$PKGS_DONE_FILE" 2>/dev/null; then
            continue
        fi
        PKGS_TO_INSTALL+=("$pkg")
    done
done

if (( ${#PKGS_TO_INSTALL[@]} > 0 )); then
    echo "entrypoint: installing additional_packages: ${PKGS_TO_INSTALL[*]}"
    if sudo -n /usr/local/bin/install-packages.sh "${PKGS_TO_INSTALL[@]}"; then
        for pkg in "${PKGS_TO_INSTALL[@]}"; do
            printf '%s\n' "$pkg" | sudo -n tee -a "$PKGS_DONE_FILE" >/dev/null || \
                printf '%s\n' "$pkg" >> "$PKGS_DONE_FILE" || true
        done
    else
        echo "entrypoint: additional_packages install failed" >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Run per-runner startup scripts (custom shell logic) once per container.
#
# Scripts live under $STARTUP_SCRIPTS_DIR (mounted from ./startup-scripts on
# the host). Each runner's `startup_script:` names a file in that dir.
# Duplicates across runners are deduped -- each unique script runs once.
# Completion is recorded in $STARTUP_DONE_FILE so container restarts don't
# re-run them.
#
# Scripts are executed as root via sudo (see /etc/sudoers.d/github-runner)
# so they can install packages without the user prepending `sudo` inside
# the script.
# ---------------------------------------------------------------------------
STARTUP_SCRIPTS_DIR="${STARTUP_SCRIPTS_DIR:-/etc/github-runners/startup}"
STARTUP_DONE_FILE="${STARTUP_DONE_FILE:-/var/lib/github-runners/startup.done}"
touch "$STARTUP_DONE_FILE" 2>/dev/null || sudo -n touch "$STARTUP_DONE_FILE" || true

declare -A STARTUP_SEEN=()
for line in "${RUNNERS[@]}"; do
    IFS=$'\x1f' read -r _ _ _ _ _ _ _ _ _ _ r_startup _ <<<"$line"
    [[ -z "$r_startup" ]] && continue
    [[ -n "${STARTUP_SEEN[$r_startup]:-}" ]] && continue
    STARTUP_SEEN["$r_startup"]=1

    script_path="$STARTUP_SCRIPTS_DIR/$r_startup"
    if [[ ! -f "$script_path" ]]; then
        echo "entrypoint: startup_script not found: $script_path" >&2
        echo "entrypoint: create it under ./startup-scripts/ on the host" >&2
        exit 1
    fi
    if grep -qxF "$r_startup" "$STARTUP_DONE_FILE" 2>/dev/null; then
        echo "entrypoint: startup_script ${r_startup} already applied, skipping"
        continue
    fi

    echo "entrypoint: running startup_script ${r_startup}"
    if sudo -n bash "$script_path"; then
        printf '%s\n' "$r_startup" | sudo -n tee -a "$STARTUP_DONE_FILE" >/dev/null || \
            printf '%s\n' "$r_startup" >> "$STARTUP_DONE_FILE" || true
    else
        echo "entrypoint: startup_script ${r_startup} failed" >&2
        exit 1
    fi
done

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
    IFS=$'\x1f' read -r title repo_url token workdir ephemeral pat labels group idle_regeneration image startup_script additional_packages <<<"$line"

    if [[ -z "$workdir" ]]; then
        repo_name="${repo_url##*/}"
        repo_name="${repo_name%.git}"
        workdir="${repo_name}/${title}"
    fi

    runner_dir="${RUNNERS_BASE}/${workdir}"

    EPHEMERAL="$ephemeral" PAT="$pat" \
    RUNNER_LABELS="$labels" RUNNER_GROUP_ID="$group" \
    IDLE_REGENERATION="$idle_regeneration" \
    RUNNER_IMAGE_FLAVOR="$image" \
        /usr/local/bin/start-runner.sh \
            "$title" "$repo_url" "$token" "$runner_dir" &
    PIDS+=($!)
done

remaining=${#PIDS[@]}
while (( remaining > 0 )); do
    if wait -n; then :; fi
    remaining=$((remaining - 1))
done

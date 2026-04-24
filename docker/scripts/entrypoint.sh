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
#   title \x1f repo_url \x1f token \x1f workdir \x1f ephemeral \x1f pat
#       \x1f labels \x1f group \x1f idle_regeneration \x1f image
#       \x1f startup_script \x1f additional_packages
#       \x1f watchdog_enabled \x1f watchdog_interval
#       \x1f docker_enabled
# token / workdir / pat / startup_script / additional_packages may be empty;
# ephemeral / watchdog_enabled / docker_enabled are "1" or "0";
# idle_regeneration and watchdog_interval are seconds (0 = disabled);
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
    IFS=$'\x1f' read -r _ _ _ _ _ _ _ _ _ r_img _ _ _ _ _ _ _ _ _ _ _ <<<"$line"
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
    IFS=$'\x1f' read -r _ r_url _ _ _ r_pat _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ <<<"$line"
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
# Docker-in-Docker (isolated sidecar).
#
# Any runner with `docker.enabled: true` opts the service into talking to
# a dedicated `docker:dind` sidecar (rendered by render.sh). The runner
# talks to it via DOCKER_HOST=tcp://dind-<slug>:2375 on a private compose
# network -- the runner container is NOT given access to the host's
# docker socket, so jobs can neither see nor control containers that
# belong to the host or to sibling services. Each image group gets its
# own DinD daemon + /var/lib/docker volume, so containers and images
# spawned by one group are invisible to every other group.
#
# At runtime we only need to:
#   1. Install the `docker` CLI if it isn't already in the image.
#      We fetch the distro-independent static binary from download.docker.com
#      so this works on debian / ubuntu / alpine / fedora / etc. with no
#      extra repo setup.
#   2. Wait for the DinD daemon to come up (compose's health check covers
#      the first start; this handles restart races).
# ---------------------------------------------------------------------------
ANY_DOCKER=0
for line in "${RUNNERS[@]}"; do
    IFS=$'\x1f' read -r _ _ _ _ _ _ _ _ _ _ _ _ _ _ r_docker _ _ _ _ _ _ <<<"$line"
    [[ "$r_docker" == "1" ]] && { ANY_DOCKER=1; break; }
done

if (( ANY_DOCKER == 1 )); then
    if [[ -z "${DOCKER_HOST:-}" ]]; then
        echo "entrypoint: docker.enabled=true but DOCKER_HOST is not set." >&2
        echo "entrypoint: re-run ./render.sh + ./start.sh so the compose file is regenerated with the DinD sidecar." >&2
        exit 1
    fi

    # If TLS is expected (standard case: mTLS to the DinD sidecar), wait
    # for the client cert material to appear. The sidecar's unix-socket
    # healthcheck can flip to healthy before the client cert has finished
    # being written to the shared volume, so we can't rely solely on
    # depends_on here.
    if [[ "${DOCKER_TLS_VERIFY:-}" == "1" && -n "${DOCKER_CERT_PATH:-}" ]]; then
        echo "entrypoint: waiting for DinD TLS client certs at ${DOCKER_CERT_PATH}"
        for i in $(seq 1 60); do
            if [[ -r "${DOCKER_CERT_PATH}/ca.pem" \
               && -r "${DOCKER_CERT_PATH}/cert.pem" \
               && -r "${DOCKER_CERT_PATH}/key.pem" ]]; then
                break
            fi
            sleep 1
        done
        if [[ ! -r "${DOCKER_CERT_PATH}/cert.pem" ]]; then
            echo "entrypoint: TLS client certs did not appear at ${DOCKER_CERT_PATH} within 60s" >&2
            exit 1
        fi
    fi

    if ! command -v docker >/dev/null 2>&1; then
        DOCKER_CLI_VERSION="${DOCKER_CLI_VERSION:-27.3.1}"
        DOCKER_CLI_ARCH="$(uname -m)"
        case "$DOCKER_CLI_ARCH" in
            x86_64)  dl_arch="x86_64" ;;
            aarch64) dl_arch="aarch64" ;;
            armv7l)  dl_arch="armhf" ;;
            *) echo "entrypoint: unsupported arch for docker static binary: $DOCKER_CLI_ARCH" >&2; exit 1 ;;
        esac
        url="https://download.docker.com/linux/static/stable/${dl_arch}/docker-${DOCKER_CLI_VERSION}.tgz"
        echo "entrypoint: installing docker CLI ${DOCKER_CLI_VERSION} (${dl_arch}) from ${url}"
        tmp_dir="$(mktemp -d)"
        if ! curl -fsSL -o "${tmp_dir}/docker.tgz" "$url"; then
            echo "entrypoint: failed to download docker CLI tarball" >&2
            rm -rf "$tmp_dir"
            exit 1
        fi
        tar -xzf "${tmp_dir}/docker.tgz" -C "$tmp_dir"
        for bin in docker; do
            if [[ -f "${tmp_dir}/docker/${bin}" ]]; then
                sudo -n install -m 0755 "${tmp_dir}/docker/${bin}" "/usr/local/bin/${bin}"
            fi
        done
        rm -rf "$tmp_dir"
    fi

    # Wait for the sidecar dockerd to accept connections. compose's
    # healthcheck + depends_on handle cold starts, but during sidecar
    # restarts the runner survives and we need to block until it's back.
    echo "entrypoint: waiting for DinD daemon at ${DOCKER_HOST}"
    for i in $(seq 1 60); do
        if docker version >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done
    if ! docker version >/dev/null 2>&1; then
        echo "entrypoint: DinD sidecar at ${DOCKER_HOST} did not become ready in 60s." >&2
        exit 1
    fi
    echo "entrypoint: docker CLI ready, $(docker --version), daemon at ${DOCKER_HOST}"
fi

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
    IFS=$'\x1f' read -r _ _ _ _ _ _ _ _ _ _ _ r_pkgs _ _ _ _ _ _ _ _ _ <<<"$line"
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
    IFS=$'\x1f' read -r _ _ _ _ _ _ _ _ _ _ r_startup _ _ _ _ _ _ _ _ _ _ <<<"$line"
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

# ---------------------------------------------------------------------------
# Persistent storage (`persistent_storage.enabled: true`).
#
# Mounted into the container at $PERSISTENT_STORAGE_ROOT (default
# /runner-storage) via a docker named volume declared by render.sh.
# Each opted-in runner sees `$RUNNER_PERSISTENT_STORAGE` in its job env,
# pointing at a subdirectory determined by `persistent_storage.scope`:
#
#   scope=shared  (default) -> $PERSISTENT_STORAGE_ROOT/shared
#                              All opted-in runners in this image group
#                              share the same directory. Use when you
#                              need to hand files from one runner (e.g.
#                              "build-01") to another ("deploy-01").
#   scope=title             -> $PERSISTENT_STORAGE_ROOT/title/<title>
#                              Pool instances of the same title share
#                              the directory; siblings are isolated.
#
# Semi-persistent: any file untouched for longer than
# `persistent_storage.ttl` seconds is deleted, both at container start
# and again by start-runner.sh before every ephemeral job iteration.
# Set ttl: 0 to keep forever. NOT an artifact service; there are no
# guarantees beyond best-effort local retention.
# ---------------------------------------------------------------------------
PERSISTENT_STORAGE_ROOT="${PERSISTENT_STORAGE_ROOT:-/runner-storage}"
export PERSISTENT_STORAGE_ROOT

ANY_PS=0
for line in "${RUNNERS[@]}"; do
    IFS=$'\x1f' read -r _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ r_ps _ _ <<<"$line"
    [[ "$r_ps" == "1" ]] && { ANY_PS=1; break; }
done

if (( ANY_PS == 1 )); then
    if [[ ! -d "$PERSISTENT_STORAGE_ROOT" ]]; then
        echo "entrypoint: persistent_storage enabled but $PERSISTENT_STORAGE_ROOT is missing." >&2
        echo "entrypoint: re-run ./render.sh + ./start.sh so the compose file is regenerated with the runner-storage volume." >&2
        exit 1
    fi
    # The named volume is owned by root on first mount; the runner runs
    # as github-runner (uid 1000) and needs write access.
    sudo -n chown github-runner:github-runner "$PERSISTENT_STORAGE_ROOT" 2>/dev/null || \
        chown github-runner:github-runner "$PERSISTENT_STORAGE_ROOT" 2>/dev/null || true
    sudo -n chmod 0755 "$PERSISTENT_STORAGE_ROOT" 2>/dev/null || true

    # Initial TTL sweep: start-runner.sh also sweeps per-iteration, but a
    # container restart after a long idle should reclaim space immediately.
    # Only whole minutes are expressible via find -mmin; sub-minute TTLs
    # are rounded up to 1 minute.
    for line in "${RUNNERS[@]}"; do
        IFS=$'\x1f' read -r t_title _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ r_ps r_ttl r_scope <<<"$line"
        [[ "$r_ps" == "1" ]] || continue
        case "$r_scope" in
            title) sub="title/$t_title" ;;
            *)     sub="shared" ;;
        esac
        dir="$PERSISTENT_STORAGE_ROOT/$sub"
        mkdir -p "$dir" 2>/dev/null || sudo -n mkdir -p "$dir"
        chown -R github-runner:github-runner "$dir" 2>/dev/null || \
            sudo -n chown -R github-runner:github-runner "$dir" 2>/dev/null || true
        if [[ "$r_ttl" =~ ^[0-9]+$ ]] && (( r_ttl > 0 )); then
            mmin=$(( (r_ttl + 59) / 60 ))
            # -depth so we remove files before their enclosing (now-empty)
            # dirs; -mindepth 1 keeps the root itself. Errors are swallowed
            # -- races between the sweep and live jobs are expected.
            find "$dir" -depth -mindepth 1 -mmin "+${mmin}" -delete 2>/dev/null || true
        fi
    done
fi

for line in "${RUNNERS[@]}"; do
    IFS=$'\x1f' read -r title repo_url token workdir ephemeral pat labels group idle_regeneration image startup_script additional_packages watchdog_enabled watchdog_interval docker_enabled instances_min instances_max instances_headroom ps_enabled ps_ttl ps_scope <<<"$line"

    if [[ -z "$workdir" ]]; then
        repo_name="${repo_url##*/}"
        repo_name="${repo_name%.git}"
        # Sanitize: the GitHub Actions runner invokes steps via a shell that
        # ends up splitting on whitespace in the work-folder path (bash sees
        # only the first word of $0 and fails with "Is a directory"). Collapse
        # anything outside [A-Za-z0-9._-] to '_' so the default path is always
        # shell-safe. Users who set an explicit workdir: in config.yml are on
        # their own -- we respect it verbatim.
        safe_title="${title//[^A-Za-z0-9._-]/_}"
        safe_repo="${repo_name//[^A-Za-z0-9._-]/_}"
        workdir="${safe_repo}/${safe_title}"
    fi

    runner_dir="${RUNNERS_BASE}/${workdir}"

    # Per-runner persistent storage path (empty if disabled).
    ps_path=""
    if [[ "$ps_enabled" == "1" ]]; then
        case "$ps_scope" in
            title) ps_path="$PERSISTENT_STORAGE_ROOT/title/$title" ;;
            *)     ps_path="$PERSISTENT_STORAGE_ROOT/shared" ;;
        esac
    fi

    EPHEMERAL="$ephemeral" PAT="$pat" \
    RUNNER_LABELS="$labels" RUNNER_GROUP_ID="$group" \
    IDLE_REGENERATION="$idle_regeneration" \
    WATCHDOG_ENABLED="$watchdog_enabled" \
    WATCHDOG_INTERVAL="$watchdog_interval" \
    RUNNER_IMAGE_FLAVOR="$image" \
    POOL_MIN="$instances_min" \
    POOL_MAX="$instances_max" \
    POOL_HEADROOM="$instances_headroom" \
    PERSISTENT_STORAGE_PATH="$ps_path" \
    PERSISTENT_STORAGE_TTL="$ps_ttl" \
        /usr/local/bin/pool-manager.sh \
            "$title" "$repo_url" "$token" "$runner_dir" &
    PIDS+=($!)
done

remaining=${#PIDS[@]}
while (( remaining > 0 )); do
    if wait -n; then :; fi
    remaining=$((remaining - 1))
done

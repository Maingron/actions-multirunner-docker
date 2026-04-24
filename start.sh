#!/usr/bin/env bash
# User-facing entry point. Everything else (Dockerfile, compose template,
# helper scripts) lives under ./docker/ and is treated as build internals.
#
#   ./start.sh                       # up --build, follows logs
#   ./start.sh up -d                 # detached
#   ./start.sh down                  # stop + remove
#   ./start.sh logs -f               # tail logs
#   ./start.sh build                 # just build images
#   ./start.sh status                # live runner + container dashboard
#   ./start.sh status --json         # machine-readable (one JSON/runner)
#   ./start.sh -- <anything>         # raw passthrough after the '--'

set -euo pipefail

cd "$(dirname "$0")"

if [[ ! -f config.yml ]]; then
    echo "start: config.yml not found next to start.sh" >&2
    echo "       cp config.example.yml config.yml and edit it" >&2
    exit 1
fi

# `status` subcommand: render the live dashboard and exit. Skips the
# render/prune dance so its output stays clean.
if [[ "${1:-}" == "status" ]]; then
    shift
    exec ./docker/status.sh "$@"
fi

# startup-scripts/ is bind-mounted into every container; make sure it
# exists so docker compose doesn't error out on a missing path.
mkdir -p startup-scripts

# Propagate the host's hostname into containers so entrypoint.sh can
# auto-inject a `host:<hostname>` label onto every runner. Containers
# otherwise only know their own (compose-assigned) hostname, which is
# useless for identifying which physical machine a runner lives on.
# Users can override by setting HOST_HOSTNAME in the environment.
export HOST_HOSTNAME="${HOST_HOSTNAME:-$(hostname)}"

# (Re)generate docker/docker-compose.yml from config.yml.
./docker/render.sh

# Read general.autoprune from config.yml (defaults to false).
autoprune="$(./docker/scripts/parse-config.sh --get general.autoprune config.yml 2>/dev/null || echo false)"
[[ "$autoprune" == "true" ]] || autoprune="false"

# Prune stale containers left over from previous renders. Container names
# follow `github-multirunner-<image-slug>` (see render.sh). Any such
# container not present in the freshly rendered compose file is removed.
# Gated on `general.autoprune: true` in config.yml.
prune_stale_containers() {
    local wanted current stale name
    wanted="$(docker compose -f docker/docker-compose.yml config --format json \
              | jq -r '.services[] | select(.container_name != null) | .container_name' \
              2>/dev/null || true)"
    current="$(docker ps -a --filter 'name=^github-multirunner-' --format '{{.Names}}' 2>/dev/null || true)"
    [[ -z "$current" ]] && return 0
    stale=()
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        grep -qxF "$name" <<<"$wanted" || stale+=("$name")
    done <<<"$current"
    if (( ${#stale[@]} > 0 )); then
        echo "start: removing ${#stale[@]} stale container(s): ${stale[*]}"
        docker rm -f "${stale[@]}" >/dev/null
    fi
}
if [[ "$autoprune" == "true" ]]; then
    prune_stale_containers
fi

# Default action: up --build with attached logs.
if [[ $# -eq 0 ]]; then
    set -- up --build
elif [[ "${1:-}" == "--" ]]; then
    shift
fi

cd docker
exec docker compose "$@"

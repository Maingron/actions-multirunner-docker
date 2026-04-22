#!/usr/bin/env bash
# User-facing entry point. Everything else (Dockerfile, compose template,
# helper scripts) lives under ./docker/ and is treated as build internals.
#
#   ./start.sh                       # up --build, follows logs
#   ./start.sh up -d                 # detached
#   ./start.sh down                  # stop + remove
#   ./start.sh logs -f               # tail logs
#   ./start.sh build                 # just build images
#   ./start.sh -- <anything>         # raw passthrough after the '--'

set -euo pipefail

cd "$(dirname "$0")"

if [[ ! -f config.yml ]]; then
    echo "start: config.yml not found next to start.sh" >&2
    echo "       cp config.example.yml config.yml and edit it" >&2
    exit 1
fi

# startup-scripts/ is bind-mounted into every container; make sure it
# exists so docker compose doesn't error out on a missing path.
mkdir -p startup-scripts

# (Re)generate docker/docker-compose.yml from config.yml.
./docker/render.sh

# Read general.autoprune from config.yml (defaults to false).
autoprune="$(python3 -c 'import yaml,sys
try:
    d=yaml.safe_load(open("config.yml")) or {}
    v=((d.get("general") or {}).get("autoprune"))
    print("true" if v is True or str(v).lower() in ("true","yes","1","on") else "false")
except Exception:
    print("false")')"

# Prune stale containers left over from previous renders. Container names
# follow `github-multirunner-<image-slug>` (see render.sh). Any such
# container not present in the freshly rendered compose file is removed.
# Gated on `general.autoprune: true` in config.yml.
prune_stale_containers() {
    local wanted current stale name
    wanted="$(docker compose -f docker/docker-compose.yml config --format json \
              | python3 -c 'import json,sys
d=json.load(sys.stdin).get("services",{})
for s in d.values():
    n=s.get("container_name")
    if n: print(n)' 2>/dev/null || true)"
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

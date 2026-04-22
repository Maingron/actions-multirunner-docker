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

# (Re)generate docker/docker-compose.yml from config.yml.
./docker/render.sh

# Default action: up --build with attached logs.
if [[ $# -eq 0 ]]; then
    set -- up --build
elif [[ "${1:-}" == "--" ]]; then
    shift
fi

cd docker
exec docker compose "$@"

#!/usr/bin/env bash
# Streamlined entry point: render docker-compose.yml from config.yml and
# hand control to `docker compose`. Extra args pass through.
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

./render.sh

# Default action: up --build with attached logs.
if [[ $# -eq 0 ]]; then
    set -- up --build
elif [[ "${1:-}" == "--" ]]; then
    shift
fi

exec docker compose "$@"

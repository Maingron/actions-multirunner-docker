#!/usr/bin/env bash
# User-facing entry point.
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

if [[ "${1:-}" == "status" ]]; then
	shift
	exec python3 ./docker/status.py "$@"
fi

mkdir -p startup-scripts
export HOST_HOSTNAME="${HOST_HOSTNAME:-$(hostname)}"

python3 ./docker/render.py

autoprune="$(python3 ./docker/scripts/parse-config.py --get general.autoprune config.yml 2>/dev/null || echo false)"
[[ "$autoprune" == "true" ]] || autoprune="false"

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

if [[ $# -eq 0 ]]; then
	set -- up --build
elif [[ "${1:-}" == "--" ]]; then
	shift
fi

cd docker
exec docker compose "$@"

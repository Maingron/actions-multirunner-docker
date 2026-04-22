#!/usr/bin/env bash
# Render docker-compose.yml from config.yml. One service per unique `image:`
# value in the runner inventory. Idempotent; re-run after editing config.yml.
# Usually invoked indirectly via `./start.sh`.
#
# Usage:
#   ./render.sh                  # writes docker-compose.yml
#   ./render.sh --check          # exit 1 if docker-compose.yml is out of date
#   ./render.sh --stdout         # print to stdout, don't write

set -euo pipefail

cd "$(dirname "$0")"

CONFIG_FILE="${CONFIG_FILE:-config.yml}"
OUTPUT_FILE="${OUTPUT_FILE:-docker-compose.yml}"
RUNNER_VERSION="${RUNNER_VERSION:-2.334.0}"
DEFAULT_IMAGE="${DEFAULT_IMAGE:-debian:stable-slim}"

mode="write"
case "${1:-}" in
    --check)  mode="check" ;;
    --stdout) mode="stdout" ;;
    "")       ;;
    *) echo "render: unknown argument: $1" >&2; exit 2 ;;
esac

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "render: $CONFIG_FILE does not exist" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Extract unique `image:` values from config.yml.
#
# Minimal YAML parser tailored to our schema:
#   defaults:
#     image: <ref>
#   runners:
#     - title: ...
#       image: <ref>    # optional, falls back to defaults.image
#
# Emits one image reference per line, in first-seen order.
# ---------------------------------------------------------------------------
mapfile -t IMAGES < <(awk -v default_image="$DEFAULT_IMAGE" '
    function flush(    img) {
        if (in_item) {
            img = cur_image
            if (img == "") img = def_image
            if (img == "") img = default_image
            if (!(img in seen)) { seen[img] = 1; order[++n] = img }
        }
        in_item = 0; cur_image = ""
    }
    function clean(s) {
        sub(/[[:space:]]*#.*/, "", s)
        gsub(/["'\'']/, "", s)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
        return s
    }

    BEGIN { section = ""; def_image = ""; in_item = 0 }

    # Top-level key resets the section.
    /^[A-Za-z_][A-Za-z0-9_]*:/ {
        flush()
        section = $0; sub(/:.*/, "", section)
        next
    }

    section == "defaults" && /^[[:space:]]+image:[[:space:]]*/ {
        line = $0; sub(/^[[:space:]]+image:[[:space:]]*/, "", line)
        def_image = clean(line)
        next
    }

    # New runner list item.
    section == "runners" && /^[[:space:]]+-[[:space:]]/ {
        flush(); in_item = 1
        line = $0
        if (match(line, /image:[[:space:]]*[^#]+/)) {
            v = substr(line, RSTART, RLENGTH)
            sub(/^image:[[:space:]]*/, "", v)
            cur_image = clean(v)
        }
        next
    }

    section == "runners" && in_item && /^[[:space:]]+image:[[:space:]]*/ {
        line = $0; sub(/^[[:space:]]+image:[[:space:]]*/, "", line)
        cur_image = clean(line)
        next
    }

    END {
        flush()
        if (n == 0) {
            img = (def_image != "" ? def_image : default_image)
            print img
        } else {
            for (i = 1; i <= n; i++) print order[i]
        }
    }
' "$CONFIG_FILE")

if [[ ${#IMAGES[@]} -eq 0 ]]; then
    IMAGES=("$DEFAULT_IMAGE")
fi

# ---------------------------------------------------------------------------
# Render.
# ---------------------------------------------------------------------------
slug() {
    # Turn a docker ref (e.g. "debian:stable-slim") into a compose-safe slug.
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
                     | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g'
}

render() {
    cat <<'EOF'
# AUTO-GENERATED from config.yml by render.sh. DO NOT EDIT.
# Re-run `./render.sh` (or just `./start.sh`) after changing the runner inventory.

x-runner-base: &runner-base
  restart: unless-stopped
  ulimits:
    nofile: 1048576
    nproc: 1048576
  pids_limit: -1
  volumes:
    - ./config.yml:/etc/github-runners/config.yml:ro
    - runner-state:/var/lib/github-runners
  tmpfs:
    - /home/github-runner:exec,size=8g,mode=0755,uid=1000,gid=1000

services:
EOF

    for image in "${IMAGES[@]}"; do
        local tag; tag="$(slug "$image")"
        cat <<EOF
  # image: ${image}
  runners-${tag}:
    <<: *runner-base
    build:
      context: .
      args:
        RUNNER_VERSION: "${RUNNER_VERSION}"
        BASE_IMAGE: ${image}
        RUNNER_IMAGE_FLAVOR: ${image}
    image: github-multirunner:${tag}
    environment:
      GITHUB_PAT: \${GITHUB_PAT:-}
      RUNNER_IMAGE_FLAVOR: ${image}

EOF
    done

    cat <<'EOF'
volumes:
  runner-state:
EOF
}

rendered="$(render)"

case "$mode" in
    stdout)
        printf '%s\n' "$rendered"
        ;;
    check)
        current="$(cat "$OUTPUT_FILE" 2>/dev/null || true)"
        if [[ "$current" != "$rendered" ]]; then
            echo "render: $OUTPUT_FILE is out of date; re-run ./render.sh" >&2
            exit 1
        fi
        ;;
    write)
        printf '%s\n' "$rendered" > "$OUTPUT_FILE"
        s="s"; (( ${#IMAGES[@]} == 1 )) && s=""
        echo "render: wrote $OUTPUT_FILE (${#IMAGES[@]} service${s})"
        for image in "${IMAGES[@]}"; do
            echo "  - runners-$(slug "$image")  (${image})"
        done
        ;;
esac

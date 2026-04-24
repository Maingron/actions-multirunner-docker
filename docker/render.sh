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

# config.yml lives at the repo root (one level up); docker-compose.yml is
# written next to this script so `docker compose` sees it as the project.
CONFIG_FILE="${CONFIG_FILE:-../config.yml}"
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
IMAGES=()
while IFS= read -r __img_line; do
    [[ -z "$__img_line" ]] && continue
    IMAGES+=("$__img_line")
done < <(awk -v default_image="$DEFAULT_IMAGE" '
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
unset __img_line

if [[ ${#IMAGES[@]} -eq 0 ]]; then
    IMAGES=("$DEFAULT_IMAGE")
fi

# ---------------------------------------------------------------------------
# Which images host a runner with `docker.enabled: true`? Those services
# get the host docker socket bind-mounted + group_add for the host docker
# group, so jobs can run `docker ...` against the host dockerd.
#
# We shell out to parse-config.sh (authoritative parser) and aggregate.
# render.sh already cd'd into docker/, so parse-config.sh lives at ./scripts/.
# ---------------------------------------------------------------------------
declare -A DOCKER_IMAGES=()
declare -A PS_IMAGES=()
if [[ -x ./scripts/parse-config.sh ]]; then
    while IFS= read -r __line; do
        [[ -z "$__line" ]] && continue
        # Field 10 = image, field 15 = docker_enabled, field 19 = ps_enabled.
        __img="$(awk 'BEGIN{FS="\x1f"} {print $10}' <<<"$__line")"
        __dk="$(awk 'BEGIN{FS="\x1f"} {print $15}' <<<"$__line")"
        __ps="$(awk 'BEGIN{FS="\x1f"} {print $19}' <<<"$__line")"
        if [[ "$__dk" == "1" && -n "$__img" ]]; then
            DOCKER_IMAGES["$__img"]=1
        fi
        if [[ "$__ps" == "1" && -n "$__img" ]]; then
            PS_IMAGES["$__img"]=1
        fi
    done < <(./scripts/parse-config.sh "$CONFIG_FILE" 2>/dev/null || true)
fi
unset __line __img __dk __ps

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
    - ../config.yml:/etc/github-runners/config.yml:ro
    - ../startup-scripts:/etc/github-runners/startup:ro
    - runner-state:/var/lib/github-runners
  tmpfs:
    - /home/github-runner:exec,size=8g,mode=0755,uid=1000,gid=1000

services:
EOF

    for image in "${IMAGES[@]}"; do
        local tag; tag="$(slug "$image")"
        local docker_enabled=0
        local ps_enabled=0
        [[ -n "${DOCKER_IMAGES[$image]:-}" ]] && docker_enabled=1
        [[ -n "${PS_IMAGES[$image]:-}" ]] && ps_enabled=1
        cat <<EOF
  # image: ${image}
  runners-${tag}:
    <<: *runner-base
    build:
      context: ..
      dockerfile: docker/Dockerfile
      args:
        RUNNER_VERSION: "${RUNNER_VERSION}"
        BASE_IMAGE: ${image}
        RUNNER_IMAGE_FLAVOR: ${image}
    image: github-multirunner:${tag}
    container_name: github-multirunner-${tag}
    hostname: github-multirunner-${tag}
    environment:
      GITHUB_PAT: \${GITHUB_PAT:-}
      RUNNER_IMAGE_FLAVOR: ${image}
EOF
        if (( docker_enabled == 1 )); then
            cat <<EOF
      # Point jobs at the dedicated DinD sidecar for this image group.
      # The daemon requires TLS + client-cert authentication; creds are
      # auto-generated by the DinD image into a shared volume and mounted
      # read-only here. Even an attacker who somehow lands on the
      # dind-${tag} network without the client key cannot talk to the
      # daemon.
      DOCKER_HOST: tcp://dind-${tag}:2376
      DOCKER_TLS_VERIFY: "1"
      DOCKER_CERT_PATH: /certs/client
    depends_on:
      dind-${tag}:
        condition: service_healthy
    # Two networks:
    #   - default:     egress (GitHub API, package mirrors, image pulls
    #                  the runner itself needs). Shared with sibling
    #                  runner services; no DinD sidecar is on it.
    #   - dind-${tag}: private channel to this group's DinD sidecar.
    #                  No other service is on it.
    # The runner cannot reach any other group's DinD, nor the host
    # dockerd (not mounted anywhere).
    networks:
      - default
      - dind-${tag}
    # Minimise the kernel attack surface from inside jobs. The runner
    # itself is unprivileged; dropping NET_RAW blocks raw-socket / ARP
    # spoofing / reach-into-host-LAN tricks without breaking normal
    # workflows (ping uses SOCK_DGRAM on modern kernels).
    cap_drop:
      - NET_RAW
    security_opt:
      # sudo inside the runner needs setuid escalation for apt-get etc.,
      # so \`no-new-privileges\` must stay false -- documented explicitly
      # rather than silently inherited.
      - no-new-privileges=false
    # Extra volumes beyond the base set: the DinD client certs. Listing
    # everything again because YAML anchor merge doesn't concatenate
    # sequences.
    volumes:
      - ../config.yml:/etc/github-runners/config.yml:ro
      - ../startup-scripts:/etc/github-runners/startup:ro
      - runner-state:/var/lib/github-runners
      - dind-${tag}-certs:/certs:ro
EOF
            if (( ps_enabled == 1 )); then
                cat <<EOF
      - runner-storage-${tag}:/runner-storage
EOF
            fi
            cat <<EOF

  # Dedicated Docker-in-Docker daemon for runners-${tag}. Isolated from
  # the host and from every other service:
  #   - Own /var/lib/docker named volume (no host bind mounts).
  #   - Own private network (dind-${tag}); not on the default network,
  #     not reachable from sibling runner services or from the host.
  #   - TLS + client-cert auth on the TCP socket (port 2376). The
  #     docker:dind image auto-generates a CA + server + client cert
  #     trio under /certs on first boot; the runner mounts the client
  #     subdir read-only. An attacker with network access but no cert
  #     cannot issue API calls.
  #   - No sensitive env (GITHUB_PAT is NOT forwarded).
  #
  # \`privileged: true\` is required because dockerd needs cgroups,
  # iptables and loop devices for its child containers. The privilege
  # stays inside this sidecar; the runner container remains unprivileged.
  dind-${tag}:
    image: docker:dind
    container_name: github-multirunner-dind-${tag}
    hostname: dind-${tag}
    restart: unless-stopped
    privileged: true
    environment:
      # /certs is the conventional location the docker:dind image uses
      # for TLS material. Setting this triggers automatic CA/server/
      # client key+cert generation on first boot.
      DOCKER_TLS_CERTDIR: /certs
    volumes:
      # TLS material: shared read-only with the runner service for mTLS.
      # Generated once on first boot; wipe the volume to regenerate.
      - dind-${tag}-certs:/certs
      # Persistent image/layer store per DinD instance, so container
      # restarts don't force a full re-pull. Wipe with
      # \`docker volume rm docker_dind-${tag}-data\`.
      - dind-${tag}-data:/var/lib/docker
    networks:
      - dind-${tag}
    healthcheck:
      # Probe via the local unix socket (always plaintext), so the
      # health check is independent of whether the TLS cert material
      # has finished being written. The runner service uses TCP+TLS.
      test: ["CMD", "docker", "-H", "unix:///var/run/docker.sock", "version"]
      interval: 5s
      timeout: 3s
      retries: 30
      start_period: 10s
EOF
        fi
        if (( docker_enabled == 0 && ps_enabled == 1 )); then
            # Anchor `<<: *runner-base` provides a `volumes:` sequence, but
            # YAML merge keys replace -- they don't concatenate -- so to
            # add the persistent-storage mount we override `volumes:`
            # entirely with the base set plus the storage volume.
            cat <<EOF
    volumes:
      - ../config.yml:/etc/github-runners/config.yml:ro
      - ../startup-scripts:/etc/github-runners/startup:ro
      - runner-state:/var/lib/github-runners
      - runner-storage-${tag}:/runner-storage
EOF
        fi
        echo
    done

    cat <<'EOF'
volumes:
  runner-state:
EOF
    # Per-DinD data + cert volumes (one of each per docker-enabled image group).
    for image in "${IMAGES[@]}"; do
        [[ -z "${DOCKER_IMAGES[$image]:-}" ]] && continue
        local tag; tag="$(slug "$image")"
        cat <<EOF
  dind-${tag}-data:
  dind-${tag}-certs:
EOF
    done
    # Per-image persistent-storage volumes (one per image group that has at
    # least one runner with persistent_storage.enabled: true).
    for image in "${IMAGES[@]}"; do
        [[ -z "${PS_IMAGES[$image]:-}" ]] && continue
        local tag; tag="$(slug "$image")"
        cat <<EOF
  runner-storage-${tag}:
EOF
    done

    # Per-DinD private networks. `internal: true` would stop the runner
    # from reaching GitHub via this network, but the runner also sits on
    # `default`, so we *can* set internal:true here to stop DinD from
    # reaching the host LAN. That breaks `docker pull` inside DinD though,
    # so we leave it as a standard bridge. Uncomment internal:true if you
    # pre-load all required images into the dind-<tag>-data volume and
    # don't want DinD to egress at all.
    if (( ${#DOCKER_IMAGES[@]} > 0 )); then
        cat <<'EOF'

networks:
EOF
        for image in "${IMAGES[@]}"; do
            [[ -z "${DOCKER_IMAGES[$image]:-}" ]] && continue
            local tag; tag="$(slug "$image")"
            cat <<EOF
  dind-${tag}:
    driver: bridge
    # internal: true   # uncomment if DinD must not egress to host LAN
EOF
        done
    fi
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

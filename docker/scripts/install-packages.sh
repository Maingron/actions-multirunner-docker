#!/usr/bin/env bash
# Autodetect the container's package manager and install the given
# packages. Used both at build time (Dockerfile) and at runtime
# (entrypoint.sh -> `additional_packages:` from config.yml).
#
# Usage: install-packages.sh <pkg> [<pkg> ...]
#
# Must run as root (the Dockerfile runs as root; entrypoint.sh uses sudo).
set -euo pipefail

if [[ $# -eq 0 ]]; then
    exit 0
fi

# Pick the first available package manager. Order matters only if a
# container somehow ships multiple (it shouldn't).
for pm in apt-get dnf yum apk zypper pacman; do
    if command -v "$pm" >/dev/null 2>&1; then
        break
    fi
    pm=""
done

if [[ -z "${pm:-}" ]]; then
    echo "install-packages: no supported package manager found " \
         "(tried apt-get, dnf, yum, apk, zypper, pacman)" >&2
    exit 1
fi

echo "install-packages: using ${pm} to install: $*"

case "$pm" in
    apt-get)
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y --no-install-recommends "$@"
        rm -rf /var/lib/apt/lists/*
        ;;
    dnf)
        dnf install -y "$@"
        dnf clean all
        ;;
    yum)
        yum install -y "$@"
        yum clean all
        ;;
    apk)
        apk add --no-cache "$@"
        ;;
    zypper)
        zypper --non-interactive install --no-recommends "$@"
        zypper clean --all
        ;;
    pacman)
        pacman -Sy --noconfirm --needed "$@"
        pacman -Scc --noconfirm || true
        ;;
esac

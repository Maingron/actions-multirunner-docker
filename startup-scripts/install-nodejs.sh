#!/usr/bin/env bash
# Example startup script: install Node.js on debian/ubuntu runners.
# Reference from config.yml with `startup_script: install-nodejs.sh`.
set -eux
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends nodejs npm
rm -rf /var/lib/apt/lists/*

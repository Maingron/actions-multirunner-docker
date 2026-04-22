# Per-runner startup scripts

For plain package installs prefer `additional_packages:` in `config.yml`
(it autodetects apt / dnf / apk / zypper / pacman). Use startup scripts
when you need custom shell logic: downloading binaries, writing config
files, enabling repos, compiling from source, etc.

Any file in this directory can be referenced from `config.yml` via:

```yaml
runners:
  - title: build-01
    startup_script: install-nodejs.sh
```

Or as a default that applies to every runner:

```yaml
defaults:
  startup_script: common-deps.sh
```

Rules:

- Paths are relative to this directory (no leading `/`, no `..`).
- Scripts run **once per container**, as **root** via `sudo`. Duplicate
  references across runners are deduped.
- Completion is recorded in `/var/lib/github-runners/startup.done` on
  the `runner-state` volume, so restarts do not re-run them. Remove that
  file (e.g. `docker compose down -v`) to force a re-run.
- The container's package manager determines what syntax you use inside
  the script (`apt-get install -y ...` on debian/ubuntu, `dnf install -y
  ...` on fedora, `apk add ...` on alpine, etc.). `install-packages.sh`
  is available on `$PATH` inside the container if you want a
  package-manager-agnostic install call.
- A failed startup script aborts container startup — no runners launch.

Example `install-nodejs.sh` (debian/ubuntu):

```bash
#!/usr/bin/env bash
set -eux
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends nodejs npm
rm -rf /var/lib/apt/lists/*
```

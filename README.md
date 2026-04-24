# github-multirunner-docker

Plain Debian (stable-slim) container that hosts N GitHub Actions self-hosted
runners in parallel, driven entirely by a single YAML config file. No web UI,
no database, no persistence.

## Layout

What you interact with:

```
config.example.yml    # inventory template; copy to config.yml
config.yml            # your inventory (gitignored)
start.sh              # build + run + log tail, all through one script
startup-scripts/      # per-runner `startup_script:` payloads (apt install, ...)
README.md
```

Build internals (you normally don't touch these):

```
docker/
├── Dockerfile
├── docker-compose.base.yml  # static compose baseline patched by render.py
├── docker-compose.yml   # generated from config.yml by render.py (gitignored)
├── render.py            # patches docker-compose.base.yml with config-driven services
└── scripts/             # copied into the image as /usr/local/bin/*
  ├── entrypoint.py
  ├── start-runner.py
  ├── pool-manager.py
  ├── fetch-token.py
  ├── fetch-jitconfig.py
  ├── delete-runner.py
  ├── runner-store.py
  ├── install-packages.py   # autodetects apt / dnf / apk / zypper / pacman
    ├── parse-config.py       # yaml parser implementation
  ├── status.py
  └── diag.py
```

Inside the container:

```
/etc/github-runners/config.yml   # runner inventory (mount your own)
/opt/actions-runner              # extracted runner tarball, used as a template
/home/github-runner/<workdir>    # per-runner instance dir (hardlink farm)
```

Each runner instance dir is a hardlinked copy of `/opt/actions-runner`, so 1000
runners do not cost 1000× the tarball size on disk.

## Config file

`/etc/github-runners/config.yml`:

```yaml
defaults:
  ephemeral: true            # per-runner override allowed
  # pat: ghp_xxxx             # or set GITHUB_PAT in the environment

runners:
  - title: build-01
    repo_url: https://github.com/your-org/your-repo
    token: AAAA...            # static registration token (≈1h lifetime)
    workdir: your-repo/build-01

  - title: build-02
    repo_url: https://github.com/your-org/your-repo
    pat: ghp_yyyy             # auto-fetch registration tokens on demand

  - title: longlived-01
    repo_url: https://github.com/your-org/your-repo
    ephemeral: false          # register once, keep session open across jobs
    pat: ghp_yyyy
```

`workdir` is relative to `/home/github-runner` (`$RUNNERS_BASE`) and becomes
the runner's install + work directory. Each runner may set `ephemeral: true`
or `false`; the default is `true`.

## Ephemeral vs. persistent

| Mode                | API used                          | Registers             | Survives jobs | Auth needed |
|---------------------|-----------------------------------|-----------------------|---------------|-------------|
| `ephemeral: true`   | `generate-jitconfig` (JIT runner) | before every job      | no            | `pat` required |
| `ephemeral: false`  | `registration-token` + `config.sh`| once at container start | yes         | `pat` or static `token` |

- **Ephemeral (JIT)** — for each job the container calls
  `POST /repos/{owner}/{repo}/actions/runners/generate-jitconfig` (or the
  org equivalent) to mint a one-shot runner configuration and passes it
  straight to `run.sh --jitconfig …`. `config.sh` is **not** invoked, and the
  problematic `/actions/runner-registration` endpoint is **not** involved at
  all. The runner runs exactly one job, then exits and auto-deregisters.
  After each job the instance dir is wiped and re-materialised. Nothing
  persists.
- **Persistent** — classic registration flow: `config.sh --token …` once at
  startup, `run.sh` stays up and handles job after job. The runner stores
  its own credentials inside the instance dir, so no further token fetches
  are needed after startup.

## PAT permissions for ephemeral / JIT runners

The JIT endpoint works with **classic PATs, fine-grained PATs, and GitHub App
installation tokens**. For fine-grained PATs specifically:

- **Repository-scoped runner** — select the repo, grant
  **"Administration" = Read and write**.
- **Organization-scoped runner** — grant
  **"Self-hosted runners" (organization) = Read and write**.

A classic PAT just needs `repo` (repo runners) or `admin:org` (org runners).

Once that permission is in place no further manual steps are required —
the container mints a fresh per-job JIT config indefinitely.

## Keeping tokens alive automatically

Registration tokens expire after roughly one hour. Two mechanisms handle
renewal without you re-editing the config:

### 1. `pat` / `$GITHUB_PAT` — auto-mint everything

Supply a long-lived credential (PAT or GitHub App installation token) via
`defaults.pat`, per-runner `pat`, or the `GITHUB_PAT` env var.

- **Ephemeral runners** call `generate-jitconfig` before every job. There is
  no separate registration-token step; the JIT config *is* the credential.
- **Persistent runners** call `registration-token` once at startup, then use
  their stored `.credentials` thereafter.

Compose usage:

```yaml
services:
  runners:
    environment:
      GITHUB_PAT: ${GITHUB_PAT}   # read from host env / .env file
```

### 2. `ephemeral: false` — never re-register at all

Persistent runners only need a registration token **once**, at `config.sh`
time. After that the runner authenticates with GitHub using its stored
credentials and reconnects automatically if the session drops. Use this if
you want a fixed pool of always-on runners.

You can freely mix the two modes in the same `config.yml`.

## Installing extra packages

Two knobs, use whichever fits:

### `additional_packages:` — plain list of package names

```yaml
defaults:
  additional_packages: [curl, build-essential]

runners:
  - title: php-builder
    additional_packages: [php-cli, composer]
```

The entrypoint autodetects the container's package manager
(`apt` / `dnf` / `apk` / `zypper` / `pacman`) and installs the union of
all listed packages once, before any runner starts. Names are
package-manager-specific — `build-essential` exists on debian/ubuntu but
not on fedora, so pin runners that need distro-specific names to a
matching `image:`. Already-installed packages are tracked on the
`runner-state` volume and skipped on restart.

### `startup_script:` — arbitrary shell logic

```yaml
runners:
  - title: node-builder
    startup_script: install-nodejs.sh
```

Files live under [`startup-scripts/`](startup-scripts/) at the repo root
and are bind-mounted read-only at `/etc/github-runners/startup/`. They
run once per container, as root via `sudo`, before any runner starts.
Use them when `additional_packages:` isn't enough — downloading binaries,
writing config files, building from source, enabling repos, etc.
Duplicate references across runners are deduped; failure aborts startup.

```bash
#!/usr/bin/env bash
# startup-scripts/install-nodejs.sh
set -eux
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends nodejs npm
rm -rf /var/lib/apt/lists/*
```

Both mechanisms are idempotent across container restarts via the
`runner-state` volume; `docker compose down -v` wipes that volume and
forces a fresh install.

## Docker access inside jobs

Some jobs need to run `docker build`, `docker run`, or tooling like
Testcontainers. Opt in per-runner:

```yaml
runners:
  - title: docker-runner-01
    repo_url: https://github.com/your-org/your-repo
    image: debian:stable-slim
    pat: ghp_yyyy
    docker:
      enabled: true
```

What this does:

- `render.py` starts from `docker/docker-compose.base.yml`, then groups runners by `image:`.
  For every image group that has
  **at least one** runner with `docker.enabled: true`, it emits a
  dedicated `docker:dind` sidecar service (e.g. `dind-debian-stable-slim`)
  on a private compose network shared **only** with that runner service.
- The runner container gets
  `DOCKER_HOST=tcp://dind-<slug>:2376`, TLS client certs, and `depends_on` the sidecar's
  health check, so the runner won't start handing out jobs until the
  daemon answers.
- `entrypoint.py` installs the `docker` CLI from the distro-independent
  static tarball (`download.docker.com`) if it isn't already present.

Isolation properties:

- **The host dockerd is never exposed to the container.** No
  `/var/run/docker.sock` bind mount, no `--privileged` on the runner, no
  `group_add`. Breaking out of a job does not grant host root.
- **Containers spawned by one image group are invisible to every other
  group.** Each DinD sidecar has its own `/var/lib/docker` volume and its
  own network namespace; `docker ps` inside a job lists only the
  containers that job's DinD created.
- **mTLS between runner and DinD.** The `docker:dind` image
  auto-generates a CA + server key + client key on first boot into a
  shared volume; the daemon listens on 2376 and refuses any connection
  without a valid client cert. Even an attacker who somehow lands on the
  private compose network without the cert cannot issue API calls.
- **The DinD sidecar inherits no secrets.** `GITHUB_PAT` is only set on
  the runner service -- the sidecar's environment is empty except for
  `DOCKER_TLS_CERTDIR`.
- **Per-group private network.** Each sidecar sits on its own
  `dind-<slug>` bridge; the default compose network isn't attached to
  any DinD. A runner cannot reach another group's DinD even by IP.
- **Reduced kernel attack surface on the runner.** `cap_drop: [NET_RAW]`
  blocks raw-socket / ARP-spoofing tricks; `no-new-privileges` is
  explicitly declared (kept false only because the runner uses `sudo`
  for package installs -- disable `sudo` and flip it to true if your
  workflows don't install packages at runtime).
- **The DinD sidecar runs with `privileged: true`** — unavoidable for
  any in-container dockerd that needs cgroups, iptables and loop
  devices. The privilege stays *inside* the sidecar; the runner
  container remains unprivileged. If you want to eliminate this, swap
  the sidecar image for `docker:dind-rootless` and tune host sysctls
  (`kernel.unprivileged_userns_clone=1`,
  `kernel.apparmor_restrict_unprivileged_userns=0` on Ubuntu ≥ 23.10).
- **No host bind mounts into DinD.** Only named volumes
  (`docker_dind-<slug>-data`, `docker_dind-<slug>-certs`), which compose
  scopes to the project.

Trade-offs vs. host-socket pass-through:

- DinD pulls/builds don't share the host's image cache -- each group
  re-pulls its base images on first use. That's the price of isolation;
  a persistent named volume (`docker_dind-<slug>-data`) keeps the cache
  warm across restarts.
- `privileged: true` is required on the sidecar. If your host forbids
  privileged containers, DinD won't work and you need a different
  approach (e.g. Kaniko for builds, remote BuildKit, or sysbox).

If an image group has *no* runner with `docker.enabled: true`, no
sidecar is rendered and that service has no docker at all.

## Semi-persistent storage between jobs

Opt a runner into a scratch directory that survives across jobs, so a
pipeline split across multiple runners (e.g. one runner builds, another
deploys) can hand files over directly — no `actions/upload-artifact`
round-trip, no external storage.

```yaml
defaults:
  persistent_storage:
    enabled: true       # default false
    ttl: 3600           # seconds; files untouched for this long are swept
    scope: shared       # shared (default) | title
```

What it does:

- Mounts a docker named volume at `/runner-storage` inside every runner
  in the image group that has at least one opted-in runner.
- Exports `$RUNNER_PERSISTENT_STORAGE` into every job on an opted-in
  runner. Use it directly from workflow steps:

  ```yaml
  jobs:
    build:
      runs-on: [self-hosted, build]
      steps:
        - uses: actions/checkout@v4
        - run: make dist
        - run: cp -r dist "$RUNNER_PERSISTENT_STORAGE/"

    deploy:
      needs: build
      runs-on: [self-hosted, deploy]
      steps:
        - run: rsync -a "$RUNNER_PERSISTENT_STORAGE/dist/" prod:/srv/
  ```

- `scope: shared` (default) — all opted-in runners in the image group
  share one directory (`/runner-storage/shared`). Pick this when
  different runner titles need to see each other's files.
- `scope: title` — each runner title gets its own subdir
  (`/runner-storage/title/<title>`). Pool instances of the same title
  still share.
- `ttl` is enforced both at container start and before every ephemeral
  job iteration via `find -mmin`. Files whose mtime is older than the
  TTL are deleted. Set `ttl: 0` to keep indefinitely (not recommended
  unless you clean up in your workflow).

What it is NOT:

- Not a replacement for `actions/cache` or `actions/upload-artifact` —
  no cross-host distribution, no integrity checks, no compression.
- Not synced between image groups — two runners with different `image:`
  values do not share storage.
- Not crash-safe — wiping the `runner-storage-<slug>` volume
  (`docker compose down -v`) destroys everything.
- Not suitable for secrets — anything you write is readable by every
  future job landing on an opted-in runner in the same image group.

## Build and run

```sh
cp config.example.yml config.yml    # then edit it
./start.sh                          # build + up, follows logs
./start.sh up -d                    # detached
./start.sh logs -f                  # tail logs
./start.sh down                     # stop + remove
```

`start.sh` (re-)generates `docker/docker-compose.yml` by patching
`docker/docker-compose.base.yml` with `config.yml`
every invocation and then forwards all remaining arguments to
`docker compose`.

Or plain docker, from the repo root:

```sh
docker build -t github-multirunner -f docker/Dockerfile .
docker run -d --name runners \
    --tmpfs /home/github-runner:size=8g,uid=1000,gid=1000 \
    -v "$PWD/config.yml":/etc/github-runners/config.yml:ro \
    github-multirunner
```

## Notes on tokens

`token` in the config is a GitHub **registration token** and only lives for
≈1 hour. For unattended long-running deployments, prefer one of:

- `pat:` / `$GITHUB_PAT` — see "Keeping tokens alive automatically" above.
  Fresh registration tokens are fetched from the GitHub API on demand; you
  only ever hand the container a long-lived credential once.
- `ephemeral: false` — persistent runners only need a valid token at startup
  and then authenticate themselves across jobs.

This image does not embed any credentials by default; it only consumes what
you pass it via the config or the environment.

## Scaling to ~1000 runners

- Raise `ulimits` (`nofile`, `nproc`) and the kernel's `pid_max` on the host.
- Give the container enough CPU and RAM; a runner idling costs little, but
  1000 concurrent jobs will not.
- `tmpfs` size must fit the sum of all live `_work` trees.
- Consider splitting across multiple containers/hosts if you actually run
  thousands concurrently — one bash supervisor process is fine for process
  management, but host limits bite first.

## Env vars

| Variable               | Default                              |
|------------------------|--------------------------------------|
| `CONFIG_FILE`          | `/etc/github-runners/config.yml`     |
| `RUNNERS_BASE`         | `/home/github-runner`                |
| `TEMPLATE_DIR`         | `/opt/actions-runner`                |
| `RUNNER_RESTART_DELAY` | `5` (seconds between job iterations) |
| `RUNNER_VERSION`       | build arg, default `2.334.0`         |

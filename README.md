# github-multirunner-docker

Plain Debian (stable-slim) container that hosts N GitHub Actions self-hosted
runners in parallel, driven entirely by a single YAML config file. No web UI,
no database, no persistence.

## Layout

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

## Build and run

```sh
docker compose build
cp config.example.yml config.yml   # then edit it
docker compose up -d
docker compose logs -f
```

Or plain docker:

```sh
docker build -t github-multirunner .
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

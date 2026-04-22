FROM debian:stable-slim

ARG RUNNER_VERSION=2.334.0
ENV RUNNER_VERSION=${RUNNER_VERSION} \
    DEBIAN_FRONTEND=noninteractive \
    CONFIG_FILE=/etc/github-runners/config.yml \
    RUNNERS_BASE=/home/github-runner \
    TEMPLATE_DIR=/opt/actions-runner \
    RUNNER_ALLOW_RUNASROOT=1

# Base tooling + runner deps. `installdependencies.sh` (run below) pulls the
# rest of the native libs the runner needs (libicu, etc.).
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates curl git jq sudo tini python3 python3-yaml \
 && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --home-dir /home/github-runner --shell /bin/bash github-runner \
 && mkdir -p /etc/github-runners "${TEMPLATE_DIR}" \
 && chown github-runner:github-runner /home/github-runner

# Fetch + extract the official runner tarball once; every runner instance
# will be materialised from this template via hardlinks at start time.
RUN set -eux; \
    cd "${TEMPLATE_DIR}"; \
    curl -fsSL -o runner.tar.gz \
        "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"; \
    tar xzf runner.tar.gz; \
    rm runner.tar.gz; \
    ./bin/installdependencies.sh; \
    chown -R github-runner:github-runner "${TEMPLATE_DIR}"

COPY entrypoint.sh       /usr/local/bin/entrypoint.sh
COPY start-runner.sh     /usr/local/bin/start-runner.sh
COPY fetch-token.sh      /usr/local/bin/fetch-token.sh
COPY fetch-jitconfig.sh  /usr/local/bin/fetch-jitconfig.sh
COPY delete-runner.sh    /usr/local/bin/delete-runner.sh
COPY diag.sh             /usr/local/bin/diag.sh
COPY config.example.yml  /etc/github-runners/config.yml
RUN chmod +x /usr/local/bin/entrypoint.sh \
             /usr/local/bin/start-runner.sh \
             /usr/local/bin/fetch-token.sh \
             /usr/local/bin/fetch-jitconfig.sh \
             /usr/local/bin/delete-runner.sh \
             /usr/local/bin/diag.sh \
 && chown -R github-runner:github-runner /etc/github-runners

USER github-runner
WORKDIR /home/github-runner

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]

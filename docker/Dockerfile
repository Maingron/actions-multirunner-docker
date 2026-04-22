ARG BASE_IMAGE=debian:stable-slim
FROM ${BASE_IMAGE}

ARG RUNNER_VERSION=2.334.0
ARG RUNNER_IMAGE_FLAVOR=debian
ENV RUNNER_VERSION=${RUNNER_VERSION} \
    RUNNER_IMAGE_FLAVOR=${RUNNER_IMAGE_FLAVOR} \
    DEBIAN_FRONTEND=noninteractive \
    CONFIG_FILE=/etc/github-runners/config.yml \
    RUNNERS_BASE=/home/github-runner \
    TEMPLATE_DIR=/opt/actions-runner \
    RUNNER_ALLOW_RUNASROOT=1

# Base tooling + runner deps. install-packages.sh autodetects the
# container's package manager (apt, dnf, apk, zypper, pacman, ...) so the
# same image build recipe works across debian/ubuntu/alpine/fedora/etc.
# `installdependencies.sh` (run below) pulls the runner's own native libs
# (libicu, etc.) afterwards.
COPY docker/scripts/install-packages.sh /usr/local/bin/install-packages.sh
RUN chmod +x /usr/local/bin/install-packages.sh \
 && /usr/local/bin/install-packages.sh \
        ca-certificates curl git jq sudo tini gawk

RUN set -eux; \
    # Recent ubuntu images ship a default `ubuntu` user at UID 1000 which\
    # collides with github-runner. Drop it if present.\
    if id -u ubuntu >/dev/null 2>&1; then userdel -r ubuntu 2>/dev/null || userdel ubuntu; fi; \
    useradd --create-home --home-dir /home/github-runner --shell /bin/bash --uid 1000 github-runner; \
    mkdir -p /etc/github-runners "${TEMPLATE_DIR}" /var/lib/github-runners; \
    chown github-runner:github-runner /home/github-runner /var/lib/github-runners; \
    # Passwordless sudo so per-runner startup scripts + `additional_packages`\
    # can install things at container start time without prompting.\
    echo "github-runner ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/github-runner; \
    chmod 0440 /etc/sudoers.d/github-runner

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

COPY docker/scripts/    /usr/local/bin/
COPY config.example.yml /etc/github-runners/config.yml
RUN chmod +x /usr/local/bin/entrypoint.sh \
             /usr/local/bin/start-runner.sh \
             /usr/local/bin/fetch-token.sh \
             /usr/local/bin/fetch-jitconfig.sh \
             /usr/local/bin/delete-runner.sh \
             /usr/local/bin/runner-store.sh \
             /usr/local/bin/install-packages.sh \
             /usr/local/bin/parse-config.sh \
             /usr/local/bin/status.sh \
             /usr/local/bin/diag.sh \
 && chown -R github-runner:github-runner /etc/github-runners

USER github-runner
WORKDIR /home/github-runner

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]

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

# Base tooling + runner deps. install-packages.py autodetects the
# container's package manager (apt, dnf, apk, zypper, pacman, ...) so the
# same image build recipe works across debian/ubuntu/alpine/fedora/etc.
# `installdependencies.sh` (run below) pulls the runner's own native libs
# (libicu, etc.) afterwards.
#
# Bootstrap: install python3 via the native package manager so that
# install-packages.py can run. The same script then installs the rest.
RUN set -eux; \
    if   command -v apt-get >/dev/null 2>&1; then \
        apt-get update && apt-get install -y --no-install-recommends python3 && rm -rf /var/lib/apt/lists/*; \
    elif command -v dnf     >/dev/null 2>&1; then dnf  install -y python3 && dnf  clean all; \
    elif command -v yum     >/dev/null 2>&1; then yum  install -y python3 && yum  clean all; \
    elif command -v apk     >/dev/null 2>&1; then apk  add --no-cache python3; \
    elif command -v zypper >/dev/null 2>&1; then \
        zypper --non-interactive install --no-recommends python3 \
        && zypper clean --all; \
    elif command -v pacman >/dev/null 2>&1; then \
        pacman -Sy --noconfirm --needed python \
        && (pacman -Scc --noconfirm || true); \
    else \
        echo "dockerfile: no supported package manager found for python3 bootstrap" >&2; exit 1; \
    fi

COPY docker/scripts/install-packages.py /usr/local/bin/install-packages.py
# install-packages.py installs the base tooling; the second block installs
# the Python YAML binding whose package name differs per distro.
RUN chmod +x /usr/local/bin/install-packages.py \
 && python3 /usr/local/bin/install-packages.py \
    ca-certificates curl git jq sudo tini gawk \
    \
    # Python YAML binding (package name differs per distro)
 && if command -v apt-get >/dev/null 2>&1; then \
        apt-get update \
        && apt-get install -y --no-install-recommends python3-yaml \
        && rm -rf /var/lib/apt/lists/*; \
    elif command -v dnf >/dev/null 2>&1; then \
        dnf install -y python3-pyyaml && dnf clean all; \
    elif command -v yum >/dev/null 2>&1; then \
        yum install -y python3-pyyaml && yum clean all; \
    elif command -v apk >/dev/null 2>&1; then \
        apk add --no-cache py3-yaml; \
    elif command -v zypper >/dev/null 2>&1; then \
        zypper --non-interactive install --no-recommends python3-PyYAML \
        && zypper clean --all; \
    elif command -v pacman >/dev/null 2>&1; then \
        pacman -Sy --noconfirm --needed python-yaml \
        && (pacman -Scc --noconfirm || true); \
    else \
        echo "dockerfile: no supported package manager found for yaml install" >&2 && exit 1; \
     fi \
 && if id -u ubuntu >/dev/null 2>&1; then userdel -r ubuntu 2>/dev/null || userdel ubuntu; fi \
 && useradd --create-home --home-dir /home/github-runner --shell /bin/bash --uid 1000 github-runner \
 && mkdir -p /etc/github-runners "${TEMPLATE_DIR}" /var/lib/github-runners \
 && chown github-runner:github-runner /home/github-runner /var/lib/github-runners \
 && echo "github-runner ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/github-runner \
 && chmod 0440 /etc/sudoers.d/github-runner \
 && cd "${TEMPLATE_DIR}" \
 && curl -fsSL -o runner.tar.gz \
        "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" \
 && tar xzf runner.tar.gz \
 && rm runner.tar.gz \
 && ./bin/installdependencies.sh \
 && chown -R github-runner:github-runner "${TEMPLATE_DIR}"

COPY docker/scripts/    /usr/local/bin/
COPY config.example.yml /etc/github-runners/config.yml
COPY docker/scripts/default-config.json /etc/github-runners/default-config.json
RUN chmod +x /usr/local/bin/entrypoint.py \
             /usr/local/bin/start-runner.py \
             /usr/local/bin/pool-manager.py \
             /usr/local/bin/fetch-token.py \
             /usr/local/bin/fetch-jitconfig.py \
             /usr/local/bin/delete-runner.py \
             /usr/local/bin/runner-store.py \
             /usr/local/bin/install-packages.py \
             /usr/local/bin/parse-config.py \
             /usr/local/bin/status.py \
             /usr/local/bin/diag.py \
 && chown -R github-runner:github-runner /etc/github-runners

USER github-runner
WORKDIR /home/github-runner

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.py"]

# syntax=docker/dockerfile:1.7
# rtest: an SSH-accessible test runner with Go, Node, Python, Rust and
# Docker-in-Docker. See README.md.
ARG UV_VERSION=0.13.6
FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv

FROM debian:trixie-slim

ARG TARGETARCH
ARG GO_VERSION=1.27.4
ARG NODE_VERSION=26.12.1
ARG RUST_VERSION=stable
ARG SCCACHE_VERSION=0.19.0

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ENV PATH=/opt/cargo/bin:/usr/local/go/bin:/usr/local/node/bin:/work/caches/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Base system, build tools, SSH server and Python.
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential ca-certificates curl git gnupg iproute2 jq less \
      libssl-dev make openssh-server pkg-config procps python3 python3-dev \
      python3-pip python3-venv rsync sudo tini unzip util-linux xz-utils \
      zip \
 && rm -rf /var/lib/apt/lists/*

# Docker engine for Docker-in-Docker.
# hadolint ignore=DL3008
RUN install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
 && echo "deb [arch=${TARGETARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian trixie stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      containerd.io docker-buildx-plugin docker-ce docker-ce-cli \
      docker-compose-plugin iptables \
 && rm -rf /var/lib/apt/lists/*

# Go.
RUN curl -fsSLo /tmp/go.tgz "https://dl.google.com/go/go${GO_VERSION}.linux-${TARGETARCH}.tar.gz" \
 && echo "$(curl -fsSL "https://dl.google.com/go/go${GO_VERSION}.linux-${TARGETARCH}.tar.gz.sha256")  /tmp/go.tgz" | sha256sum -c - \
 && tar -C /usr/local -xzf /tmp/go.tgz \
 && rm /tmp/go.tgz

# Node.js, npm, pnpm and yarn.
RUN case "${TARGETARCH}" in amd64) arch=x64 ;; arm64) arch=arm64 ;; *) exit 1 ;; esac \
 && file="node-v${NODE_VERSION}-linux-${arch}.tar.xz" \
 && curl -fsSLo "/tmp/${file}" "https://nodejs.org/dist/v${NODE_VERSION}/${file}" \
 && curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" | grep " ${file}\$" | sed "s|  |  /tmp/|" | sha256sum -c - \
 && mkdir /usr/local/node \
 && tar -C /usr/local/node --strip-components=1 -xJf "/tmp/${file}" \
 && rm "/tmp/${file}" \
 && /usr/local/node/bin/npm install -g --no-fund --no-audit pnpm yarn \
 && /usr/local/node/bin/npm cache clean --force

# uv, for Python projects and other Python versions.
COPY --from=uv /uv /uvx /usr/local/bin/

# Rust (rustup) and sccache. The cargo registry lives in the /work volume.
ENV RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo
RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile minimal \
      --default-toolchain "${RUST_VERSION}" --component clippy,rustfmt \
 && case "${TARGETARCH}" in amd64) arch=x86_64 ;; arm64) arch=aarch64 ;; *) exit 1 ;; esac \
 && file="sccache-v${SCCACHE_VERSION}-${arch}-unknown-linux-musl" \
 && base="https://github.com/mozilla/sccache/releases/download/v${SCCACHE_VERSION}" \
 && curl -fsSLo "/tmp/${file}.tar.gz" "${base}/${file}.tar.gz" \
 && echo "$(curl -fsSL "${base}/${file}.tar.gz.sha256")  /tmp/${file}.tar.gz" | sha256sum -c - \
 && tar -C /tmp -xzf "/tmp/${file}.tar.gz" \
 && install -m 0755 "/tmp/${file}/sccache" /usr/local/bin/sccache \
 && rm -rf /tmp/sccache* \
 && rm -rf /opt/cargo/registry /opt/cargo/git \
 && ln -s /work/caches/cargo/registry /opt/cargo/registry \
 && ln -s /work/caches/cargo/git /opt/cargo/git

# The user that runs the tests. It can use Docker and install rustup toolchains.
RUN useradd --create-home --shell /bin/bash --groups docker runner \
 && passwd -d runner >/dev/null \
 && chown -R runner:runner /opt/rustup /opt/cargo

# SSH sessions do not inherit the image ENV. pam_env reads /etc/environment
# for every session, and the rtest scripts also read it.
COPY rootfs/ /
RUN chmod 0755 /usr/local/bin/rtest-* \
 && mkdir -p /run/sshd /etc/rtest


EXPOSE 22
VOLUME ["/work", "/var/lib/docker"]
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --start-interval=2s \
  CMD ["/usr/local/bin/rtest-healthcheck"]
ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/rtest-entrypoint"]

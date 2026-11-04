FROM debian:bookworm-slim

ARG USERNAME=vscode
ARG USER_UID=1000
ARG USER_GID=1000

ARG ZIG_VERSION=0.17.0
ARG ZIG_SHA256_X86_64=1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026
ARG ZIG_SHA256_AARCH64=9e8d11661d4ae3bd57702a3832781e23ad151dde5798e16a5ccd503f65234ff8

# can-utils and iproute2 provide vcan setup, cangen and candump for SocketCAN testing.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    can-utils \
    curl \
    git \
    iproute2 \
    make \
    passwd \
    sudo \
    xz-utils \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    if ! getent group "${USERNAME}" >/dev/null; then \
    groupadd --gid "${USER_GID}" "${USERNAME}"; \
    fi; \
    if ! id -u "${USERNAME}" >/dev/null 2>&1; then \
    useradd --uid "${USER_UID}" --gid "${USER_GID}" -m "${USERNAME}" -s /bin/bash; \
    fi; \
    echo "${USERNAME} ALL=(root) NOPASSWD:ALL" > "/etc/sudoers.d/${USERNAME}"; \
    chmod 0440 "/etc/sudoers.d/${USERNAME}"; \
    mkdir -p "/home/${USERNAME}/.cache/zig"; \
    chown -R "${USERNAME}:${USERNAME}" "/home/${USERNAME}"

RUN set -eux; \
    arch="$(uname -m)"; \
    case "$arch" in \
    x86_64) sha="$ZIG_SHA256_X86_64" ;; \
    aarch64) sha="$ZIG_SHA256_AARCH64" ;; \
    *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/zig.tar.xz "https://ziglang.org/download/${ZIG_VERSION}/zig-${arch}-linux-${ZIG_VERSION}.tar.xz"; \
    echo "${sha}  /tmp/zig.tar.xz" | sha256sum -c -; \
    mkdir -p /opt/zig; \
    tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1; \
    rm /tmp/zig.tar.xz; \
    ln -s /opt/zig/zig /usr/local/bin/zig

ENV ZIG_GLOBAL_CACHE_DIR=/var/cache/zig

WORKDIR /workspace

CMD ["bash"]

FROM ubuntu:22.04

# Prevent apt from prompting during build
ENV DEBIAN_FRONTEND=noninteractive

# Install base utilities
RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
    ca-certificates wget curl git \
    python3 python3-pip \
    tini neofetch \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Download ttyd binary — picks the correct one based on CPU architecture (x86 or ARM)
RUN set -eux; \
    arch="$(uname -m)"; \
    case "$arch" in \
      x86_64|amd64) ttyd_asset="ttyd.x86_64" ;; \
      aarch64|arm64) ttyd_asset="ttyd.aarch64" ;; \
      *) echo "Unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    mkdir -p /usr/local/bin && \
    wget -qO /usr/local/bin/ttyd "https://github.com/tsl0922/ttyd/releases/latest/download/${ttyd_asset}" \
    && chmod +x /usr/local/bin/ttyd

# Run neofetch on every new terminal session to display system info
# 'cd /root' ensures every session starts in the home directory
RUN echo "neofetch || true" >> /root/.bashrc && \
    echo "cd /root" >> /root/.bashrc

# tini is used as the init process (PID 1) so that:
# - zombie processes are properly reaped
# - signals like SIGTERM are correctly forwarded to ttyd on container shutdown
ENTRYPOINT ["/usr/bin/tini", "--"]

# Start ttyd web terminal:
# -lc = login shell (sources .bashrc and .profile)
# --writable = allow keyboard input in terminal
# -i 0.0.0.0 = bind to all interfaces so Railway can route traffic in
# -c = basic auth using USERNAME and PASSWORD env variables
# PS1 sets a red+yellow colored terminal prompt: username@host:path$
CMD ["/bin/bash", "-lc", "\
    echo \"export PS1='\\[\\033[01;31m\\]$USERNAME@\\h\\[\\033[00m\\]:\\[\\033[01;33m\\]\\w\\[\\033[00m\\]\\$ '\" >> /root/.bashrc && \
    /usr/local/bin/ttyd --writable -i 0.0.0.0 -p ${PORT} -c ${USERNAME}:${PASSWORD} /bin/bash"]
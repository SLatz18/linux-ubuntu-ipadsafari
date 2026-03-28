FROM ubuntu:22.04

# Prevent apt from prompting during build
ENV DEBIAN_FRONTEND=noninteractive

# Install base utilities + nginx (WebSocket proxy) + apache2-utils (htpasswd for basic auth)
RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
    ca-certificates wget curl git \
    python3 python3-pip \
    tini neofetch \
    nginx apache2-utils \
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

# Write nginx config template — __PORT__ is replaced with $PORT at container start.
# Single-quoted heredoc ('NGINXCONF') prevents the shell from expanding nginx
# variables like $http_upgrade and $host at build time; nginx expands them at
# request time instead.
#
# Why nginx in front of ttyd?
# Railway terminates TLS externally, and Safari on iPad sends its WebSocket upgrade
# request over HTTP/2. The WebSocket protocol (RFC 6455) is an HTTP/1.1 mechanism —
# the Upgrade + Connection headers are only valid in HTTP/1.1. Without an explicit
# HTTP/1.1 proxy layer, the upgrade handshake can fail when Safari uses HTTP/2,
# which causes the "Press Enter to Reconnect" screen on iPad.
# nginx here forces proxy_http_version 1.1 and sets the correct upgrade headers,
# ensuring the WebSocket handshake succeeds on all browsers including Safari on iPad.
RUN cat > /etc/nginx/ttyd-proxy.conf.template << 'NGINXCONF'
worker_processes 1;
events { worker_connections 1024; }
http {
    server {
        listen __PORT__;

        # Basic auth — credentials populated at runtime from USERNAME/PASSWORD env vars
        auth_basic "Terminal";
        auth_basic_user_file /etc/nginx/.htpasswd;

        location / {
            proxy_pass http://127.0.0.1:7681;

            # Force HTTP/1.1 for the upstream connection so the WebSocket
            # Upgrade handshake works regardless of what protocol the client
            # used to reach Railway (HTTP/2 from Safari on iPad, HTTP/1.1 elsewhere)
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;

            # Long timeout so idle terminal sessions stay open
            proxy_read_timeout 7d;
            proxy_send_timeout 7d;
        }
    }
}
NGINXCONF

# tini is used as the init process (PID 1) so that:
# - zombie processes are properly reaped
# - signals like SIGTERM are correctly forwarded on container shutdown
ENTRYPOINT ["/usr/bin/tini", "--"]

# At container start:
# 1. Append colored PS1 prompt to .bashrc
# 2. Create the nginx basic-auth file from USERNAME / PASSWORD env vars
# 3. Substitute __PORT__ in the nginx template and write to /etc/nginx/nginx.conf
# 4. Start ttyd bound to loopback only on port 7681 (nginx is the public-facing server)
# 5. Start nginx in the foreground — tini keeps PID 1 tidy
#
# ttyd client options (-t flags sent to the xterm.js frontend):
#   disableLeaveAlert=true — stops Safari showing "Leave site?" on keyboard shortcuts
#   fontSize=16            — readable without pinch-zooming on iPad
#   cursorBlink=true       — shows clearly when the terminal has focus
CMD ["/bin/bash", "-lc", "\
    echo \"export PS1='\\[\\033[01;31m\\]$USERNAME@\\h\\[\\033[00m\\]:\\[\\033[01;33m\\]\\w\\[\\033[00m\\]\\$ '\" >> /root/.bashrc && \
    htpasswd -cb /etc/nginx/.htpasswd \"${USERNAME}\" \"${PASSWORD}\" && \
    sed \"s/__PORT__/${PORT}/g\" /etc/nginx/ttyd-proxy.conf.template > /etc/nginx/nginx.conf && \
    /usr/local/bin/ttyd \
      --writable \
      -i 127.0.0.1 \
      -p 7681 \
      -t disableLeaveAlert=true \
      -t fontSize=16 \
      -t cursorBlink=true \
      /bin/bash -l & \
    nginx -g 'daemon off;'"]

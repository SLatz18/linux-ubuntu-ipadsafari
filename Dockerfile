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

# Custom login page — replaces the browser's native HTTP Basic Auth dialog, which is
# ugly and has usability issues on iPad Safari. The page validates credentials via
# fetch() to /auth-verify (which doesn't trigger the native dialog), then navigates
# with embedded credentials so the browser caches them for the session.
RUN mkdir -p /usr/share/nginx/html && cat > /usr/share/nginx/html/login.html << 'LOGINPAGE'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<title>Sign In — Terminal</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    background: #1a1a2e;
    color: #e0e0e0;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    display: flex;
    align-items: center;
    justify-content: center;
    min-height: 100vh;
    min-height: -webkit-fill-available;
  }
  html { height: -webkit-fill-available; }
  .card {
    background: #16213e;
    border-radius: 16px;
    padding: 40px 32px;
    width: 90%;
    max-width: 380px;
    box-shadow: 0 8px 32px rgba(0,0,0,0.4);
  }
  h1 {
    font-size: 24px;
    font-weight: 600;
    margin-bottom: 8px;
    color: #fff;
    text-align: center;
  }
  .subtitle {
    font-size: 14px;
    color: #8892b0;
    text-align: center;
    margin-bottom: 32px;
  }
  label {
    display: block;
    font-size: 13px;
    color: #8892b0;
    margin-bottom: 6px;
    margin-top: 16px;
  }
  input[type="text"], input[type="password"] {
    width: 100%;
    padding: 12px 14px;
    border: 1px solid #2a3a5c;
    border-radius: 8px;
    background: #0f3460;
    color: #fff;
    font-size: 16px; /* 16px prevents iOS Safari auto-zoom on focus */
    outline: none;
    transition: border-color 0.2s;
    -webkit-appearance: none;
  }
  input:focus { border-color: #e94560; }
  button {
    width: 100%;
    padding: 14px;
    margin-top: 28px;
    border: none;
    border-radius: 8px;
    background: #e94560;
    color: #fff;
    font-size: 16px;
    font-weight: 600;
    cursor: pointer;
    transition: background 0.2s;
    -webkit-appearance: none;
  }
  button:active { background: #c73650; }
  .error {
    color: #e94560;
    font-size: 13px;
    text-align: center;
    margin-top: 16px;
    display: none;
  }
  .spinner {
    display: none;
    width: 20px; height: 20px;
    border: 2px solid transparent;
    border-top-color: #fff;
    border-radius: 50%;
    animation: spin 0.6s linear infinite;
    margin: 0 auto;
  }
  @keyframes spin { to { transform: rotate(360deg); } }
</style>
</head>
<body>
<div class="card">
  <h1>Terminal</h1>
  <p class="subtitle">Sign in to access the terminal</p>
  <form id="loginForm" autocomplete="on">
    <label for="username">Username</label>
    <input type="text" id="username" name="username" autocomplete="username" autocapitalize="none" required autofocus>
    <label for="password">Password</label>
    <input type="password" id="password" name="password" autocomplete="current-password" required>
    <button type="submit" id="btn"><span id="btnText">Sign In</span><div class="spinner" id="spinner"></div></button>
  </form>
  <p class="error" id="error">Invalid username or password</p>
</div>
<script>
document.getElementById('loginForm').addEventListener('submit', function(e) {
  e.preventDefault();
  var user = document.getElementById('username').value;
  var pass = document.getElementById('password').value;
  var btn = document.getElementById('btn');
  var btnText = document.getElementById('btnText');
  var spinner = document.getElementById('spinner');
  var errEl = document.getElementById('error');

  errEl.style.display = 'none';
  btnText.style.display = 'none';
  spinner.style.display = 'block';
  btn.disabled = true;

  // Validate credentials via fetch — fetch() never triggers the native auth dialog,
  // unlike XMLHttpRequest which can. /auth-verify uses nginx auth_basic and returns
  // a real 401 on failure (no error_page override on that endpoint).
  fetch('/auth-verify', {
    method: 'GET',
    headers: { 'Authorization': 'Basic ' + btoa(user + ':' + pass) },
    credentials: 'omit'
  }).then(function(res) {
    if (res.ok) {
      // Credentials valid. Navigate with embedded credentials so the browser
      // sends them as a Basic Auth header and caches them for the session.
      var loc = window.location;
      window.location.href = loc.protocol + '//' +
        encodeURIComponent(user) + ':' + encodeURIComponent(pass) +
        '@' + loc.host + '/';
    } else {
      errEl.style.display = 'block';
      btnText.style.display = 'inline';
      spinner.style.display = 'none';
      btn.disabled = false;
    }
  }).catch(function() {
    errEl.textContent = 'Network error \u2014 try again';
    errEl.style.display = 'block';
    btnText.style.display = 'inline';
    spinner.style.display = 'none';
    btn.disabled = false;
  });
});
</script>
</body>
</html>
LOGINPAGE

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
pid /tmp/nginx.pid;
error_log stderr;
worker_processes 1;
events { worker_connections 1024; }
http {
    access_log /dev/stdout;
    server {
        listen __PORT__;

        # Basic auth — credentials populated at runtime from USERNAME/PASSWORD env vars
        auth_basic "Terminal";
        auth_basic_user_file /etc/nginx/.htpasswd;

        # Login page — served without auth
        location = /login.html {
            auth_basic off;
            root /usr/share/nginx/html;
        }

        # Auth verification endpoint for the login form JavaScript.
        # Has auth_basic (inherited from server) but NO error_page override,
        # so it returns a real 401 on failure. fetch() does not trigger the
        # native browser auth dialog, so this is safe.
        location = /auth-verify {
            default_type text/plain;
            return 200 'ok';
        }

        # Main terminal proxy — intercepts 401 and shows our custom login page
        # instead of the browser's native Basic Auth dialog.
        # "=200" changes the response status so the browser never sees a 401 or
        # the WWW-Authenticate header that would trigger the native dialog.
        location / {
            error_page 401 =200 /login.html;

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
    htpasswd -cb /etc/nginx/.htpasswd \"${USERNAME}\" \"${PASSWORD}\" 2>&1 && \
    sed \"s/__PORT__/${PORT:-8080}/g\" /etc/nginx/ttyd-proxy.conf.template > /etc/nginx/nginx.conf && \
    cat /etc/nginx/nginx.conf && \
    /usr/local/bin/ttyd \
      --writable \
      -i 127.0.0.1 \
      -p 7681 \
      -t disableLeaveAlert=true \
      -t fontSize=16 \
      -t cursorBlink=true \
      /bin/bash -l & \
    sleep 1 && \
    nginx -t && \
    nginx -g 'daemon off;'"]

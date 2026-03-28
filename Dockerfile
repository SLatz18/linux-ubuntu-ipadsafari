FROM ubuntu:22.04

# Prevent apt from prompting during build
ENV DEBIAN_FRONTEND=noninteractive

# Persist workspace local bin on PATH so installed tools (e.g. pipx, uv) are
# available in every shell session without manually exporting PATH each time.
ENV PATH="/workspace/.local/bin:$PATH"

# Install base utilities + nginx (WebSocket proxy) + apache2-utils (htpasswd for basic auth)
RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
    ca-certificates wget curl git \
    python3 python3-pip \
    tini neofetch tmux \
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
# 'cc' alias drops into /workspace and launches claude in one keystroke
RUN echo "neofetch || true" >> /root/.bashrc && \
    echo "cd /root" >> /root/.bashrc && \
    echo "alias cc='cd /workspace && claude'" >> /root/.bashrc

# Custom login page — replaces the browser's native HTTP Basic Auth dialog, which is
# ugly and has usability issues on iPad Safari. The page validates credentials via
# fetch() to /auth-verify (which doesn't trigger the native dialog), then the server
# sets a session cookie and the JS redirects to / without credentials in the URL.
# Safari blocks user:pass@host URLs, so cookie-based sessions are required.
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
  // credentials: 'same-origin' so the browser accepts the Set-Cookie from the response.
  fetch('/auth-verify', {
    method: 'GET',
    headers: { 'Authorization': 'Basic ' + btoa(user + ':' + pass) },
    credentials: 'same-origin'
  }).then(function(res) {
    if (res.ok) {
      // Credentials valid. Server set a session cookie in the response.
      // Redirect to / without credentials in the URL — Safari blocks
      // user:pass@host URLs, so we rely on the cookie instead.
      window.location.href = '/';
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

# Voice-enabled terminal page — wraps ttyd with a Web Speech API microphone overlay.
# Navigate to /voice instead of / to get the voice-input terminal.
# Uses xterm.js from CDN to replicate the ttyd frontend, then adds a floating mic
# button that feeds recognised speech directly into the terminal via the ttyd WebSocket.
RUN cat > /usr/share/nginx/html/voice.html << 'VOICEPAGE'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<title>Voice Terminal</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/xterm@5.3.0/css/xterm.css">
<script src="https://cdn.jsdelivr.net/npm/xterm@5.3.0/lib/xterm.js"></script>
<script src="https://cdn.jsdelivr.net/npm/xterm-addon-fit@0.8.0/lib/xterm-addon-fit.js"></script>
<style>
* { margin: 0; padding: 0; box-sizing: border-box; }
/* Flex column so #terminal can flex-grow to fill remaining height reliably on iOS */
html { height: 100%; }
body {
  height: 100%;
  display: flex;
  flex-direction: column;
  background: #111;
  overflow: hidden;
}
/* min-height: 0 is required so a flex child can shrink below its content size —
   without it xterm.js canvas collapses to 0 height on iOS Safari */
#terminal { flex: 1; min-height: 0; }
#mic-btn {
  position: fixed; bottom: 24px; right: 24px;
  width: 64px; height: 64px; border-radius: 50%; border: none;
  background: #e94560; color: #fff; font-size: 28px; cursor: pointer;
  box-shadow: 0 4px 16px rgba(0,0,0,0.5); z-index: 100;
  display: flex; align-items: center; justify-content: center;
  -webkit-tap-highlight-color: transparent;
  transition: background 0.2s, transform 0.1s;
}
#mic-btn.listening { background: #cc0000; animation: pulse 1s ease-in-out infinite; }
#mic-btn:active { transform: scale(0.93); }
@keyframes pulse {
  0%, 100% { box-shadow: 0 4px 16px rgba(204,0,0,0.5); }
  50%       { box-shadow: 0 4px 32px rgba(204,0,0,0.9); }
}
#status {
  position: fixed; bottom: 96px; right: 16px;
  background: rgba(0,0,0,0.8); color: #fff;
  font-family: -apple-system, BlinkMacSystemFont, sans-serif; font-size: 13px;
  padding: 5px 12px; border-radius: 14px; z-index: 100;
  max-width: 240px; text-align: right; display: none;
  white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
}
</style>
</head>
<body>
<div id="terminal"></div>
<div id="status"></div>
<button id="mic-btn" title="Tap to speak">&#127908;</button>
<script>
(function () {
  /* ── Terminal ── */
  var term = new Terminal({
    fontSize: 16,
    cursorBlink: true,
    /* Slightly off-black so users can see the terminal area against the page */
    theme: { background: '#111111', foreground: '#cccccc' },
    convertEol: false
  });
  var fitAddon = new FitAddon.FitAddon();
  term.loadAddon(fitAddon);
  term.open(document.getElementById('terminal'));

  /* Defer first fit until after layout is painted so xterm measures the real size */
  requestAnimationFrame(function () { fitAddon.fit(); });

  var ro = new ResizeObserver(function () {
    fitAddon.fit();
    sendResize();
  });
  ro.observe(document.getElementById('terminal'));

  /* ── WebSocket → ttyd (tmux session) ── */
  var ws;
  var proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
  var wsUrl = proto + '//' + location.host + '/ws';

  function sendResize() {
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send('1' + JSON.stringify({ columns: term.cols, rows: term.rows }));
    }
  }

  function connect() {
    term.write('\x1b[33mConnecting to terminal\u2026\x1b[0m\r\n');
    ws = new WebSocket(wsUrl);
    ws.binaryType = 'arraybuffer';
    ws.onopen = function () {
      term.write('\x1b[32mConnected.\x1b[0m\r\n');
      setTimeout(sendResize, 150);
    };
    ws.onmessage = function (ev) {
      if (typeof ev.data === 'string') {
        if (ev.data[0] === '0') term.write(ev.data.slice(1));
      } else {
        var arr = new Uint8Array(ev.data);
        if (arr[0] === 48 /* '0' */) term.write(arr.slice(1));
      }
    };
    ws.onclose = function () {
      term.write('\r\n\x1b[31m[Disconnected \u2014 reconnecting in 2 s\u2026]\x1b[0m\r\n');
      setTimeout(connect, 2000);
    };
    ws.onerror = function () { ws.close(); };
  }
  connect();

  term.onData(function (data) {
    if (ws && ws.readyState === WebSocket.OPEN) ws.send('0' + data);
  });

  /* ── Voice input ── */
  var micBtn   = document.getElementById('mic-btn');
  var statusEl = document.getElementById('status');
  var SR = window.SpeechRecognition || window.webkitSpeechRecognition;

  if (!SR) {
    micBtn.style.background = '#555';
    micBtn.title = 'Speech recognition not supported in this browser';
    micBtn.disabled = true;
  } else {
    var rec    = null;
    var active = false;

    function showStatus(txt) {
      statusEl.textContent = txt;
      statusEl.style.display = 'block';
    }
    function hideStatus() {
      setTimeout(function () { statusEl.style.display = 'none'; }, 2000);
    }

    function startRec() {
      rec = new SR();
      rec.lang            = 'en-US';
      rec.interimResults  = true;
      rec.maxAlternatives = 1;
      rec.continuous      = false; /* iOS Safari is most reliable with false */

      rec.onstart = function () {
        active = true;
        micBtn.classList.add('listening');
        micBtn.innerHTML = '&#9632;';
        showStatus('Listening\u2026');
      };

      rec.onresult = function (e) {
        var interim = '', final = '';
        for (var i = e.resultIndex; i < e.results.length; i++) {
          if (e.results[i].isFinal) final  += e.results[i][0].transcript;
          else                       interim += e.results[i][0].transcript;
        }
        if (interim) showStatus(interim);
        if (final && ws && ws.readyState === WebSocket.OPEN) {
          showStatus('\u2713 ' + final);
          ws.send('0' + final + '\n');
        }
      };

      rec.onerror = function (e) {
        /* 'network' is a transient iOS error — prompt user to retry rather than
           showing a scary message */
        var msg = e.error === 'network'
          ? 'Tap again to retry'
          : 'Error: ' + e.error;
        showStatus(msg);
        stopRec();
      };

      rec.onend = stopRec;
      rec.start();
    }

    function stopRec() {
      active = false;
      micBtn.classList.remove('listening');
      micBtn.innerHTML = '&#127908;';
      hideStatus();
      if (rec) { try { rec.abort(); } catch (_) {} rec = null; }
    }

    micBtn.addEventListener('click', function () {
      if (active) stopRec(); else startRec();
    });
  }
})();
</script>
</body>
</html>
VOICEPAGE

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
    map_hash_bucket_size 128;

    # Check session cookie — __SESSION_SECRET__ is replaced at container start
    # with a SHA-256 hash derived from USERNAME:PASSWORD.
    map $cookie_terminal_session $session_valid {
        "__SESSION_SECRET__" 1;
        default 0;
    }

    server {
        listen __PORT__;

        # Basic auth — used ONLY for /auth-verify; other locations turn it off.
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
        # On success, sets a session cookie so subsequent requests use cookie auth
        # instead of Basic Auth (Safari blocks user:pass@host URLs).
        location = /auth-verify {
            add_header Set-Cookie "terminal_session=__SESSION_SECRET__; Path=/; HttpOnly; Secure; SameSite=Strict" always;
            default_type text/plain;
            return 200 'ok';
        }

        # Voice-enabled terminal page — same cookie auth as /, serves static HTML.
        location = /voice {
            auth_basic off;

            if ($session_valid != 1) {
                rewrite ^ /login.html last;
            }

            alias /usr/share/nginx/html/voice.html;
            default_type text/html;
        }

        # Main terminal proxy — uses cookie auth instead of Basic Auth.
        # If no valid session cookie, serve the login page (as a 200 so the
        # browser never sees a 401 / WWW-Authenticate that would trigger
        # the native Basic Auth dialog).
        location / {
            auth_basic off;

            if ($session_valid != 1) {
                rewrite ^ /login.html last;
            }

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
# 3. Generate a session secret (SHA-256 of USERNAME:PASSWORD) for cookie auth
# 4. Substitute __PORT__ and __SESSION_SECRET__ in the nginx template
# 5. Start ttyd bound to loopback only on port 7681 (nginx is the public-facing server)
# 6. Start nginx in the foreground — tini keeps PID 1 tidy
#
# ttyd is started with tmux so every browser connection (/ and /voice) attaches
# to the same shared session. Voice input typed via /voice appears in the same
# terminal the user sees at /, and vice versa.
# 'tmux new-session -A -s main' creates the session on first connect; subsequent
# connections attach to the existing one (-A flag).
# Status bar is hidden so tmux is invisible inside xterm.js / ttyd.
#
# ttyd client options (-t flags sent to the xterm.js frontend):
#   disableLeaveAlert=true — stops Safari showing "Leave site?" on keyboard shortcuts
#   fontSize=16            — readable without pinch-zooming on iPad
#   cursorBlink=true       — shows clearly when the terminal has focus
CMD ["/bin/bash", "-lc", "\
    echo \"export PS1='\\[\\033[01;31m\\]$USERNAME@\\h\\[\\033[00m\\]:\\[\\033[01;33m\\]\\w\\[\\033[00m\\]\\$ '\" >> /root/.bashrc && \
    mkdir -p /workspace/.claude && \
    rm -rf /root/.claude && \
    ln -s /workspace/.claude /root/.claude && \
    [ -s /workspace/.claude.json ] || echo '{}' > /workspace/.claude.json && \
    rm -f /root/.claude.json && \
    ln -s /workspace/.claude.json /root/.claude.json && \
    htpasswd -cb /etc/nginx/.htpasswd \"${USERNAME}\" \"${PASSWORD}\" 2>&1 && \
    SESSION_SECRET=$(echo -n \"${USERNAME}:${PASSWORD}\" | sha256sum | cut -d' ' -f1) && \
    sed -e \"s/__PORT__/${PORT:-8080}/g\" -e \"s/__SESSION_SECRET__/${SESSION_SECRET}/g\" /etc/nginx/ttyd-proxy.conf.template > /etc/nginx/nginx.conf && \
    cat /etc/nginx/nginx.conf && \
    /usr/local/bin/ttyd \
      --writable \
      -i 127.0.0.1 \
      -p 7681 \
      -t disableLeaveAlert=true \
      -t fontSize=16 \
      -t cursorBlink=true \
      tmux new-session -A -s main -x 220 -y 50 \; set-option -g status off & \
    sleep 1 && \
    nginx -t && \
    nginx -g 'daemon off;'"]

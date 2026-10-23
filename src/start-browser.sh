#!/bin/bash
set -euo pipefail
export DISPLAY=:1
export HOME=/root
export USER=root
export LOGNAME=root
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
install -d -m 700 /root/.vnc /root/.ssh
install -d -m 755 /run/sshd /workspace
install -d -m 700 /root/browser-profile
: "${BROWSER_PASSWORD:?Missing browser password}"
test ! -f /opt/pandastack/app.env || chmod 600 /opt/pandastack/app.env
x11vnc -storepasswd "$BROWSER_PASSWORD" /root/.vnc/passwd >/dev/null 2>&1

if [ -n "${ROOT_PASSWORD:-}" ]; then
    printf 'root:%s\n' "$ROOT_PASSWORD" | chpasswd
fi

if [ -n "${SSH_AUTHORIZED_KEY_B64:-}" ]; then
    printf '%s' "$SSH_AUTHORIZED_KEY_B64" | base64 -d > /root/.ssh/authorized_keys
    chmod 700 /root/.ssh
    chmod 600 /root/.ssh/authorized_keys
    chown -R root:root /root/.ssh
    env -i HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin /usr/sbin/sshd -f /app/sshd_config -E /tmp/sshd.log
fi

if [ -n "${DATABASE_URL_B64:-}" ] && [ -n "${WORKSPACE_KEY:-}" ]; then
    DATABASE_URL="$(printf '%s' "$DATABASE_URL_B64" | base64 -d)"
    # Restore successfully before allowing any shell to edit this workspace.
    env -i HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        DATABASE_URL="$DATABASE_URL" WORKSPACE_KEY="$WORKSPACE_KEY" \
        WORKSPACE_ID="${WORKSPACE_ID:-pandastack-workspace}" \
        /usr/bin/python3 /app/workspace_sync.py >/tmp/workspace-sync.log 2>&1 &
    SYNC_PID=$!
    for attempt in $(seq 1 90); do
        test ! -f /run/workspace-sync.ready || break
        kill -0 "$SYNC_PID" 2>/dev/null || { echo 'Workspace restore failed; refusing to open terminals'; exit 1; }
        sleep 1
    done
    test -f /run/workspace-sync.ready
fi
chown -R root:root /workspace
BROWSER_PASSWORD_VALUE="$BROWSER_PASSWORD"
unset BROWSER_PASSWORD ROOT_PASSWORD SSH_AUTHORIZED_KEY_B64 DATABASE_URL_B64 DATABASE_URL WORKSPACE_KEY WORKSPACE_ID

Xvfb :1 -screen 0 1440x900x24 -nolisten tcp &
sleep 1
openbox >/tmp/openbox.log 2>&1 &
/opt/pds-chromium/chrome --no-sandbox --disable-dev-shm-usage --disable-background-networking --disable-sync --disable-breakpad --no-first-run --no-default-browser-check --user-data-dir=/root/browser-profile --window-size=1440,900 --start-maximized about:blank >/tmp/chromium.log 2>&1 &
sleep 2
BROWSER=/usr/local/bin/pds-open-browser xterm -fa 'DejaVu Sans Mono' -fs 12 -title 'Terminal - /workspace' -geometry 110x28+100+190 -e /bin/bash -lc 'cd /workspace; printf "Terminal ready. Code sync: cat /run/workspace-sync.json\n"; exec bash' >/tmp/xterm.log 2>&1 &
x11vnc -display :1 -localhost -rfbport 5900 -rfbauth /root/.vnc/passwd -forever -shared -noxdamage >/tmp/x11vnc.log 2>&1 &
exec env BROWSER_PASSWORD="$BROWSER_PASSWORD_VALUE" /usr/bin/python3 /app/browser-gateway.py
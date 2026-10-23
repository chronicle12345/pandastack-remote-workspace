#!/bin/bash
set -euo pipefail
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  x11vnc novnc websockify openbox libxcomposite1 fonts-noto-cjk \
  xterm fonts-dejavu-core openssh-server curl ca-certificates python3-psycopg2 python3-cryptography passwd
install -d -m 755 /workspace /app/ssh
install -d -m 700 /root/.ssh /root/browser-profile
if [ -d /home/dev/browser-profile ]; then
  cp -a /home/dev/browser-profile/. /root/browser-profile/ 2>/dev/null || true
fi
if id dev >/dev/null 2>&1; then
  userdel -r dev 2>/dev/null || true
fi
rm -f /etc/sudoers.d/90-pandastack-dev
chown -R root:root /workspace /root/browser-profile
rm -f /app/ssh/host_key /app/ssh/host_key.pub
ssh-keygen -q -t ed25519 -N '' -f /app/ssh/host_key
CHROME_SOURCE=$(find /root/.cache/ms-playwright -path '*/chrome-linux64/chrome' -type f | head -1)
test -n "$CHROME_SOURCE"
rm -rf /opt/pds-chromium
cp -a "$(dirname "$CHROME_SOURCE")" /opt/pds-chromium
printf '%s\n' '#!/bin/bash' 'exec /opt/pds-chromium/chrome --no-sandbox --disable-dev-shm-usage --user-data-dir=/root/browser-profile "$@"' > /usr/local/bin/pds-open-browser
chmod 755 /usr/local/bin/pds-open-browser
install -m 755 /app/desktop-actions.py /usr/local/bin/pds-desktop-actions
install -m 644 /app/desktop.html /usr/share/novnc/desktop.html
install -m 644 /app/desktop.js /usr/share/novnc/desktop.js
/usr/bin/python3 /app/fix_desktop_menu.py --system
printf '%s\n' '<!doctype html><meta charset="utf-8"><meta http-equiv="refresh" content="0;url=desktop.html">' > /usr/share/novnc/index.html
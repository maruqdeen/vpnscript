#!/bin/bash
# VPN-Starter-Kit :: core/dropbear.sh
# Configure Dropbear as the SSH backend for the WebSocket proxy.
# Runs ALONGSIDE OpenSSH: OpenSSH stays on :22 (admin), Dropbear on 127.0.0.1:143 (tunnels).
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."
  exit 1
fi

DROPBEAR_PORT=143
DROPBEAR_HOST="127.0.0.1"

echo ">>> Configuring Dropbear on ${DROPBEAR_HOST}:${DROPBEAR_PORT}..."

# Dropbear's default config file on Ubuntu.
cat >/etc/default/dropbear <<EOF
# Managed by VPN-Starter-Kit
NO_START=0
DROPBEAR_PORT=${DROPBEAR_PORT}
DROPBEAR_EXTRA_ARGS="-p ${DROPBEAR_HOST}:${DROPBEAR_PORT}"
DROPBEAR_BANNER=""
DROPBEAR_RECEIVE_WINDOW=65536
EOF

# Ensure the login shell for tunnel users exists in the allowed shells list,
# otherwise password logins can be refused.
if ! grep -q '/bin/false' /etc/shells; then
  echo "/bin/false" >>/etc/shells
fi
if ! grep -q '/usr/sbin/nologin' /etc/shells; then
  echo "/usr/sbin/nologin" >>/etc/shells
fi

echo ">>> Enabling and restarting Dropbear..."
systemctl enable dropbear >/dev/null 2>&1 || true
systemctl restart dropbear

echo "============================================"
echo " Dropbear configured."
echo "   Bind    : ${DROPBEAR_HOST}:${DROPBEAR_PORT}  (localhost only)"
echo "   OpenSSH : untouched on :22"
echo "   Reached via: ws.py (public 8880) -> Dropbear"
echo "============================================"
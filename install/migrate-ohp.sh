#!/bin/bash
# VPN-Starter-Kit :: install/migrate-ohp.sh
# One-time, idempotent fix for servers installed before SSH-over-HTTP-
# Proxy (OHP) support existed. update.sh only refreshes files — it
# never creates new systemd units — so a server that already ran setup.sh
# needs this to actually install and start ohp-proxy.service. Run
# update.sh FIRST (or this pulls core/ohp.py itself below) so
# /etc/vpn-script/core/ohp.py is in place before the unit references it.
# Usage: wget -qO- https://raw.githubusercontent.com/maruqdeen/vpnscript/main/install/migrate-ohp.sh | sudo bash
set -uo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."; exit 1
fi

INSTALL_DIR="/etc/vpn-script"

echo ">>> Ensuring core/ohp.py is present..."
mkdir -p "$INSTALL_DIR/core"
wget -qO "$INSTALL_DIR/core/ohp.py" \
  https://raw.githubusercontent.com/maruqdeen/vpnscript/main/core/ohp.py \
  || { echo "Download failed."; exit 1; }
chmod +x "$INSTALL_DIR/core/ohp.py"

if [[ ! -s "$INSTALL_DIR/core/ohp.py" ]]; then
  echo "ERROR: core/ohp.py is missing or empty after download. Aborting."
  exit 1
fi

echo ">>> Installing ohp-proxy.service..."
cat > /etc/systemd/system/ohp-proxy.service <<'EOF'
[Unit]
Description=SSH-over-HTTP-Proxy (OHP) Tunnel (VPN-Starter-Kit)
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /etc/vpn-script/core/ohp.py
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl unmask ohp-proxy 2>/dev/null || true
systemctl enable --now ohp-proxy

sleep 1
if systemctl is-active --quiet ohp-proxy; then
  echo "ohp-proxy is active — SSH-OHP now listening on port 8181."
else
  echo "WARNING: ohp-proxy did not start. Check:  journalctl -u ohp-proxy -n 20 --no-pager"
  exit 1
fi

echo ""
echo "Done. Pull the latest menu scripts too if you haven't:"
echo "  wget -qO- https://raw.githubusercontent.com/maruqdeen/vpnscript/main/install/update.sh | sudo bash"

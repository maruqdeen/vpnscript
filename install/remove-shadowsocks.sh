#!/bin/bash
# VPN-Starter-Kit :: install/remove-shadowsocks.sh
# One-time cleanup for servers that ran the old migrate-shadowsocks.sh:
# removes the ss-ws/ss-grpc inbounds from the LIVE Xray config and the
# /ss, /ss-grpc routes from nginx. Shadowsocks has been dropped from this
# project in favor of WireGuard.
# Usage: wget -qO- https://raw.githubusercontent.com/maruqdeen/vpnscript/main/install/remove-shadowsocks.sh | sudo bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."; exit 1
fi

CONFIG="/usr/local/etc/xray/config.json"
[[ -f "$CONFIG" ]] || { echo "Xray config not found at $CONFIG"; exit 1; }

echo ">>> Updating nginx (removes /ss + /ss-grpc routes)..."
TMP_NGINX="$(mktemp)"
wget -qO "$TMP_NGINX" \
  https://raw.githubusercontent.com/maruqdeen/vpnscript/main/core/nginx.conf \
  || { echo "Download failed."; exit 1; }
install -m 644 "$TMP_NGINX" /etc/nginx/conf.d/vpn.conf
rm -f "$TMP_NGINX"
nginx -t && systemctl reload nginx

echo ">>> Removing ss-ws + ss-grpc inbounds from Xray config..."
if jq -e '.inbounds[] | select(.tag=="ss-ws")' "$CONFIG" >/dev/null 2>&1; then
  cp "$CONFIG" "${CONFIG}.bak-$(date +%s)"
  tmp=$(mktemp)
  jq '.inbounds |= map(select(.tag != "ss-ws" and .tag != "ss-grpc"))' \
    "$CONFIG" > "$tmp" && chmod 644 "$tmp" && mv "$tmp" "$CONFIG"
  echo "    removed (backup saved alongside config.json)."
else
  echo "    not present, nothing to remove."
fi

# Same nobody-user permission fix as the other migrations, re-asserted
# unconditionally.
chmod 644 "$CONFIG"
NOBODY_GROUP="$(id -gn nobody 2>/dev/null || echo nogroup)"
chown -R nobody:"$NOBODY_GROUP" /var/log/vpn-script 2>/dev/null || true
systemctl restart xray
sleep 1
if systemctl is-active --quiet xray; then
  echo "    xray is active."
else
  echo "    WARNING: xray still isn't active — check: journalctl -u xray -n 30 --no-pager"
fi

echo ""
echo "Shadowsocks removed. Pull the latest menu scripts (drops the SS menu, adds WireGuard):"
echo "  wget -qO- https://raw.githubusercontent.com/maruqdeen/vpnscript/main/install/update.sh | sudo bash"

#!/bin/bash
# VPN-Starter-Kit :: install/migrate-vless-grpc.sh
# One-time, idempotent fix for servers installed before VLESS gRPC support
# existed. NON-DESTRUCTIVE: adds the vless-grpc inbound to your LIVE Xray
# config without touching any existing inbound, then copies every current
# vless-ws client into it so already-created accounts get gRPC access too,
# with the same UUID (same approach as migrate-vmess-grpc.sh, verified the
# same way with a mock live config). Also refreshes nginx's vpn.conf (no
# per-user state lives there, so a straight overwrite is safe) for the new
# /vless-grpc route.
# Usage: wget -qO- https://raw.githubusercontent.com/maruqdeen/vpnscript/main/install/migrate-vless-grpc.sh | sudo bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."; exit 1
fi

CONFIG="/usr/local/etc/xray/config.json"
[[ -f "$CONFIG" ]] || { echo "Xray config not found at $CONFIG"; exit 1; }

echo ">>> Updating nginx (adds /vless-grpc route)..."
TMP_NGINX="$(mktemp)"
wget -qO "$TMP_NGINX" \
  https://raw.githubusercontent.com/maruqdeen/vpnscript/main/core/nginx.conf \
  || { echo "Download failed."; exit 1; }
install -m 644 "$TMP_NGINX" /etc/nginx/conf.d/vpn.conf
rm -f "$TMP_NGINX"
nginx -t && systemctl reload nginx

echo ">>> Adding vless-grpc inbound to Xray config (existing users untouched)..."
if jq -e '.inbounds[] | select(.tag=="vless-grpc")' "$CONFIG" >/dev/null 2>&1; then
  echo "    already present, skipping."
else
  cp "$CONFIG" "${CONFIG}.bak-$(date +%s)"
  tmp=$(mktemp)
  jq '
    (.inbounds) += [{
      "tag": "vless-grpc",
      "port": 10004,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": { "clients": (.inbounds[] | select(.tag=="vless-ws") | .settings.clients), "decryption": "none" },
      "streamSettings": { "network": "grpc", "grpcSettings": { "serviceName": "vless-grpc" } }
    }]
  ' "$CONFIG" > "$tmp" && chmod 644 "$tmp" && mv "$tmp" "$CONFIG"
  echo "    done — existing VLESS users now also work over gRPC (backup saved alongside config.json)."
fi

# Same nobody-user permission fix as migrate-vmess-grpc.sh — re-asserted
# unconditionally, even on the "already present" path, so re-running this
# repairs an already-broken permission state instead of skipping past it.
echo ">>> Ensuring Xray (runs as user 'nobody') can read its config and write its logs..."
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
echo "Migration complete. Pull the latest menu scripts too if you haven't:"
echo "  wget -qO- https://raw.githubusercontent.com/maruqdeen/vpnscript/main/install/update.sh | sudo bash"

#!/bin/bash
# VPN-Starter-Kit :: install/migrate-shadowsocks.sh
# One-time, idempotent fix for servers installed before Shadowsocks
# support existed. Adds ss-ws (10007) and ss-grpc (10008) inbounds to your
# LIVE Xray config without touching any existing inbound — Shadowsocks is
# brand new here, so unlike the vmess/vless gRPC migrations there are no
# existing clients to carry over. Also refreshes nginx's vpn.conf (no
# per-user state lives there, so a straight overwrite is safe) for the new
# /ss and /ss-grpc routes (both plain 80/8080 and TLS 443, same as
# vmess/vless — unlike Trojan, Shadowsocks has no TLS-only constraint).
# Usage: wget -qO- https://raw.githubusercontent.com/maruqdeen/vpnscript/main/install/migrate-shadowsocks.sh | sudo bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."; exit 1
fi

CONFIG="/usr/local/etc/xray/config.json"
[[ -f "$CONFIG" ]] || { echo "Xray config not found at $CONFIG"; exit 1; }

echo ">>> Updating nginx (adds /ss + /ss-grpc routes)..."
TMP_NGINX="$(mktemp)"
wget -qO "$TMP_NGINX" \
  https://raw.githubusercontent.com/maruqdeen/vpnscript/main/core/nginx.conf \
  || { echo "Download failed."; exit 1; }
install -m 644 "$TMP_NGINX" /etc/nginx/conf.d/vpn.conf
rm -f "$TMP_NGINX"
nginx -t && systemctl reload nginx

echo ">>> Adding ss-ws + ss-grpc inbounds to Xray config (existing users untouched)..."
if jq -e '.inbounds[] | select(.tag=="ss-ws")' "$CONFIG" >/dev/null 2>&1; then
  echo "    already present, skipping."
else
  cp "$CONFIG" "${CONFIG}.bak-$(date +%s)"
  tmp=$(mktemp)
  jq '
    (.inbounds) += [
      {
        "tag": "ss-ws",
        "port": 10007,
        "listen": "127.0.0.1",
        "protocol": "shadowsocks",
        "settings": { "clients": [] },
        "streamSettings": { "network": "ws", "wsSettings": { "path": "/ss" } }
      },
      {
        "tag": "ss-grpc",
        "port": 10008,
        "listen": "127.0.0.1",
        "protocol": "shadowsocks",
        "settings": { "clients": [] },
        "streamSettings": { "network": "grpc", "grpcSettings": { "serviceName": "ss-grpc" } }
      }
    ]
  ' "$CONFIG" > "$tmp" && chmod 644 "$tmp" && mv "$tmp" "$CONFIG"
  echo "    done — Shadowsocks is ready, create accounts via menu > SS Menu."
fi

# Same nobody-user permission fix as the vmess/vless/trojan migrations —
# re-asserted unconditionally, even on the "already present" path.
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

#!/bin/bash
# VPN-Starter-Kit :: install/migrate-trojan.sh
# One-time, idempotent fix for servers installed before Trojan support
# existed. Adds trojan-ws (10005) and trojan-grpc (10006) inbounds to your
# LIVE Xray config without touching any existing inbound — Trojan is brand
# new here, so unlike the vmess/vless gRPC migrations there are no
# existing clients to carry over. Also refreshes nginx's vpn.conf (no
# per-user state lives there, so a straight overwrite is safe) for the new
# /trojan and /trojan-grpc routes (443/TLS only — Trojan's whole design is
# looking like ordinary HTTPS, so there's no plaintext port for it).
# Usage: wget -qO- https://raw.githubusercontent.com/maruqdeen/vpnscript/main/install/migrate-trojan.sh | sudo bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."; exit 1
fi

CONFIG="/usr/local/etc/xray/config.json"
[[ -f "$CONFIG" ]] || { echo "Xray config not found at $CONFIG"; exit 1; }

echo ">>> Updating nginx (adds /trojan + /trojan-grpc routes)..."
TMP_NGINX="$(mktemp)"
wget -qO "$TMP_NGINX" \
  https://raw.githubusercontent.com/maruqdeen/vpnscript/main/core/nginx.conf \
  || { echo "Download failed."; exit 1; }
install -m 644 "$TMP_NGINX" /etc/nginx/conf.d/vpn.conf
rm -f "$TMP_NGINX"
nginx -t && systemctl reload nginx

echo ">>> Adding trojan-ws + trojan-grpc inbounds to Xray config (existing users untouched)..."
if jq -e '.inbounds[] | select(.tag=="trojan-ws")' "$CONFIG" >/dev/null 2>&1; then
  echo "    already present, skipping."
else
  cp "$CONFIG" "${CONFIG}.bak-$(date +%s)"
  tmp=$(mktemp)
  jq '
    (.inbounds) += [
      {
        "tag": "trojan-ws",
        "port": 10005,
        "listen": "127.0.0.1",
        "protocol": "trojan",
        "settings": { "clients": [] },
        "streamSettings": { "network": "ws", "wsSettings": { "path": "/trojan" } }
      },
      {
        "tag": "trojan-grpc",
        "port": 10006,
        "listen": "127.0.0.1",
        "protocol": "trojan",
        "settings": { "clients": [] },
        "streamSettings": { "network": "grpc", "grpcSettings": { "serviceName": "trojan-grpc" } }
      }
    ]
  ' "$CONFIG" > "$tmp" && chmod 644 "$tmp" && mv "$tmp" "$CONFIG"
  echo "    done — Trojan is ready, create accounts via menu > Trojan Menu."
fi

# Same nobody-user permission fix as the vmess/vless gRPC migrations —
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

#!/bin/bash
# VPN-Starter-Kit :: install/migrate-shadowsocks.sh
# Fixes servers running the earlier (broken) Shadowsocks-over-WS/gRPC
# setup: real ss:// clients (incl. v2rayNG) ignore transport query params
# per the SIP002 spec and connect with plain Shadowsocks straight to the
# port, which nginx then rejects — "Fail to detect internet connection:
# EOF". This migration removes the old ss-ws/ss-grpc inbounds (10007/
# 10008) and their nginx /ss + /ss-grpc routes, and replaces them with a
# single Shadowsocks inbound listening directly and publicly on 8388 —
# no nginx involved, a plain ss://method:password@host:8388#tag link that
# every Shadowsocks client can import. Any accounts already created under
# the old setup are carried over onto the new inbound, not lost.
# Idempotent: safe to run again on a server already migrated.
# Usage: wget -qO- https://raw.githubusercontent.com/maruqdeen/vpnscript/main/install/migrate-shadowsocks.sh | sudo bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."; exit 1
fi

CONFIG="/usr/local/etc/xray/config.json"
[[ -f "$CONFIG" ]] || { echo "Xray config not found at $CONFIG"; exit 1; }

echo ">>> Updating nginx (drops the old /ss + /ss-grpc routes)..."
TMP_NGINX="$(mktemp)"
wget -qO "$TMP_NGINX" \
  https://raw.githubusercontent.com/maruqdeen/vpnscript/main/core/nginx.conf \
  || { echo "Download failed."; exit 1; }
install -m 644 "$TMP_NGINX" /etc/nginx/conf.d/vpn.conf
rm -f "$TMP_NGINX"
nginx -t && systemctl reload nginx

echo ">>> Rebuilding the Shadowsocks inbound (direct port 8388, clients preserved)..."
cp "$CONFIG" "${CONFIG}.bak-$(date +%s)"
tmp=$(mktemp)
jq '
  ([.inbounds[] | select(.protocol=="shadowsocks") | .settings.clients[]?] | unique_by(.email)) as $clients |
  .inbounds |= [.[] | select(.tag != "ss-ws" and .tag != "ss-grpc" and .tag != "shadowsocks")] + [{
    "tag": "shadowsocks",
    "port": 8388,
    "listen": "0.0.0.0",
    "protocol": "shadowsocks",
    "settings": { "clients": $clients, "network": "tcp,udp" }
  }]
' "$CONFIG" > "$tmp" && chmod 644 "$tmp" && mv "$tmp" "$CONFIG"

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
echo ">>> Make sure TCP+UDP port 8388 is open in your firewall (ufw/iptables),"
echo "    since Shadowsocks is now a direct public port, not routed via nginx."
echo ""
echo "Migration complete. Pull the latest menu scripts too if you haven't:"
echo "  wget -qO- https://raw.githubusercontent.com/maruqdeen/vpnscript/main/install/update.sh | sudo bash"

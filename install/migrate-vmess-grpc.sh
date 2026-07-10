#!/bin/bash
# VPN-Starter-Kit :: install/migrate-vmess-grpc.sh
# One-time, idempotent fix for servers installed before VMess gRPC support
# existed. NON-DESTRUCTIVE: adds the vmess-grpc inbound to your LIVE Xray
# config without touching any existing inbound, then copies every current
# vmess-ws client into it so already-created accounts get gRPC access too,
# with the same UUID (verified with a mock live config before shipping —
# see the commit this shipped in). Also refreshes nginx's vpn.conf (no
# per-user state lives there, so a straight overwrite is safe) for the new
# http2 + /vmess-grpc route.
# Usage: wget -qO- https://raw.githubusercontent.com/maruqdeen/vpnscript/main/install/migrate-vmess-grpc.sh | sudo bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."; exit 1
fi

CONFIG="/usr/local/etc/xray/config.json"
[[ -f "$CONFIG" ]] || { echo "Xray config not found at $CONFIG"; exit 1; }

echo ">>> Updating nginx (adds http2 + /vmess-grpc route)..."
TMP_NGINX="$(mktemp)"
wget -qO "$TMP_NGINX" \
  https://raw.githubusercontent.com/maruqdeen/vpnscript/main/core/nginx.conf \
  || { echo "Download failed."; exit 1; }
install -m 644 "$TMP_NGINX" /etc/nginx/conf.d/vpn.conf
rm -f "$TMP_NGINX"
nginx -t && systemctl reload nginx

echo ">>> Adding vmess-grpc inbound to Xray config (existing users untouched)..."
if jq -e '.inbounds[] | select(.tag=="vmess-grpc")' "$CONFIG" >/dev/null 2>&1; then
  echo "    already present, skipping."
else
  cp "$CONFIG" "${CONFIG}.bak-$(date +%s)"
  tmp=$(mktemp)
  jq '
    (.inbounds) += [{
      "tag": "vmess-grpc",
      "port": 10003,
      "listen": "127.0.0.1",
      "protocol": "vmess",
      "settings": { "clients": (.inbounds[] | select(.tag=="vmess-ws") | .settings.clients) },
      "streamSettings": { "network": "grpc", "grpcSettings": { "serviceName": "vmess-grpc" } }
    }]
  ' "$CONFIG" > "$tmp" && chmod 644 "$tmp" && mv "$tmp" "$CONFIG"
  echo "    done — existing VMess users now also work over gRPC (backup saved alongside config.json)."
fi

# Always re-assert this, even on the "already present" path — this is the
# actual fix for the "permission denied" crash affecting installs that ran
# an earlier version of this script: mktemp+mv silently drops config.json
# to 600 (root-only), but Xray's official installer runs it as user
# "nobody", which can then no longer read its own config. Same reasoning
# for the log directory it needs to WRITE to on startup.
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

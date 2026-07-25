#!/bin/bash
# VPN-Starter-Kit :: menu/generate-wireguard-config.sh
# Reprint an existing WireGuard peer's client config + QR (e.g. the
# original card was lost). Keys are already stored in clients.json (set
# at creation time in add-wireguard-user.sh), so no extra persistence is
# needed here, unlike SSH's password.
set -euo pipefail

CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../core" && pwd)"
source "$CORE_DIR/wireguard.sh"

DOMAIN_FILE="/etc/vpn-script/domain"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."; exit 1
fi

wg_ensure_server

COUNT=$(jq 'length' "$WG_CLIENTS_JSON" 2>/dev/null || echo 0)
echo ""
echo "Current Wireguard users:"
if [[ "$COUNT" -eq 0 ]]; then
  echo "  (none)"; exit 1
fi
jq -r '.[] | "  - \(.username)   (expires \(.expiry))"' "$WG_CLIENTS_JSON"

echo ""
read -rp "Enter username to generate config for: " NAME

CLIENT_JSON="$(jq -c --arg u "$NAME" '[.[] | select(.username==$u)][0]' "$WG_CLIENTS_JSON")"
if [[ -z "$CLIENT_JSON" || "$CLIENT_JSON" == "null" ]]; then
  echo "No Wireguard user named '$NAME'."; exit 1
fi

IP="$(echo "$CLIENT_JSON" | jq -r '.address')"
EXPIRY="$(echo "$CLIENT_JSON" | jq -r '.expiry')"
PRIV="$(echo "$CLIENT_JSON" | jq -r '.private_key')"
PSK="$(echo "$CLIENT_JSON" | jq -r '.preshared_key')"
SERVER_PUB="$(cat "$WG_SERVER_PUB_FILE")"

HOSTNAME_VAL="$(cat "$DOMAIN_FILE" 2>/dev/null)"
[[ -z "$HOSTNAME_VAL" ]] && HOSTNAME_VAL="$(curl -s https://api.ipify.org || hostname -I | awk '{print $1}')"

CLIENT_CONF=$(cat <<EOF
[Interface]
PrivateKey = ${PRIV}
Address = ${IP}/24
DNS = 1.1.1.1, 1.0.0.1

[Peer]
PublicKey = ${SERVER_PUB}
PresharedKey = ${PSK}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = ${HOSTNAME_VAL}:${WG_PORT}
PersistentKeepalive = 25
EOF
)

cat <<CARD
====================================
   Wireguard Account
====================================
Remarks       : ${NAME}
Address       : ${IP}/24
Endpoint      : ${HOSTNAME_VAL}:${WG_PORT}
Expired On    : ${EXPIRY}
====================================
${CLIENT_CONF}
====================================
CARD

echo ""
echo "Scan to import:"
echo "$CLIENT_CONF" | qrencode -t ansiutf8

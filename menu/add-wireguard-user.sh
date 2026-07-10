#!/bin/bash
# VPN-Starter-Kit :: menu/add-wireguard-user.sh
# Create a WireGuard peer: generates a fresh keypair + preshared key,
# allocates the next free address in the 10.7.20.0/24 tunnel subnet, adds
# it as a live peer (hot-reload, no dropped connections for other peers),
# and prints the client config + a scannable QR code.
set -euo pipefail

CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../core" && pwd)"
source "$CORE_DIR/wireguard.sh"

DOMAIN_FILE="/etc/vpn-script/domain"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."; exit 1
fi

wg_ensure_server

read -rp "Enter Username : " USERNAME
read -rp "Expiry (days)  : " DAYS

if [[ -z "$USERNAME" ]]; then
  echo "Username cannot be empty."; exit 1
fi
if ! [[ "$DAYS" =~ ^[0-9]+$ ]]; then
  echo "Expiry must be a number of days."; exit 1
fi
if jq -e --arg n "$USERNAME" '.[] | select(.username==$n)' "$WG_CLIENTS_JSON" >/dev/null 2>&1; then
  echo "Error: user '$USERNAME' already exists."; exit 1
fi

IP="$(wg_next_ip)"
if [[ -z "$IP" ]]; then
  echo "Subnet full (253 peers max) — delete an old peer first."; exit 1
fi

PRIV="$(wg genkey)"
PUB="$(echo "$PRIV" | wg pubkey)"
PSK="$(wg genpsk)"
EXPIRY=$(date -d "+${DAYS} days" +%Y-%m-%d)
SERVER_PUB="$(cat "$WG_SERVER_PUB_FILE")"

HOSTNAME_VAL="$(cat "$DOMAIN_FILE" 2>/dev/null)"
[[ -z "$HOSTNAME_VAL" ]] && HOSTNAME_VAL="$(curl -s https://api.ipify.org || hostname -I | awk '{print $1}')"

tmp=$(mktemp)
jq --arg u "$USERNAME" --arg e "$EXPIRY" --arg addr "$IP" \
   --arg priv "$PRIV" --arg pub "$PUB" --arg psk "$PSK" \
  '. += [{username:$u, expiry:$e, address:$addr, private_key:$priv, public_key:$pub, preshared_key:$psk}]' \
  "$WG_CLIENTS_JSON" > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$WG_CLIENTS_JSON"

wg_sync_peers

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
Remarks       : ${USERNAME}
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

#!/bin/bash
# VPN-Starter-Kit :: menu/add-user.sh
# Add an Xray user (VLESS, VMess, Trojan, or Shadowsocks) into the live
# config via jq.
# Usage: add-user.sh <vless|vmess|trojan|shadowsocks>
set -euo pipefail

CONFIG="/usr/local/etc/xray/config.json"
PROTOCOL="${1:-}"
DOMAIN_FILE="/etc/vpn-script/domain"

case "$PROTOCOL" in
  vless|vmess|trojan|shadowsocks) ;;
  *) echo "Usage: add-user.sh <vless|vmess|trojan|shadowsocks>"; exit 1 ;;
esac

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../core" && pwd)/xray-links.sh"

if [[ ! -f "$CONFIG" ]]; then
  echo "Error: Xray config not found at $CONFIG"
  exit 1
fi

read -rp "Enter Username : " USERNAME
read -rp "Expiry (days)  : " DAYS

# --- validate input ---
if [[ -z "$USERNAME" ]]; then
  echo "Username cannot be empty."; exit 1
fi
if ! [[ "$DAYS" =~ ^[0-9]+$ ]]; then
  echo "Expiry must be a number of days."; exit 1
fi

UUID=$(cat /proc/sys/kernel/random/uuid)
EXPIRY=$(date -d "+${DAYS} days" +%Y-%m-%d)

# The Xray "email" field must be unique; we encode expiry into it: user_YYYY-MM-DD
EMAIL_TAG="${USERNAME}_${EXPIRY}"

# --- refuse duplicate username on this protocol ---
if jq -e --arg proto "$PROTOCOL" --arg name "$USERNAME" '
    .inbounds[] | select(.protocol==$proto) | .settings.clients[]
    | select((.email | split("_")[0]) == $name)
  ' "$CONFIG" >/dev/null 2>&1; then
  echo "Error: user '$USERNAME' already exists on $PROTOCOL."
  exit 1
fi

# --- build the client object ---
case "$PROTOCOL" in
  vless)
    CLIENT=$(jq -n --arg id "$UUID" --arg email "$EMAIL_TAG" \
      '{id:$id, email:$email}')
    ;;
  vmess)
    CLIENT=$(jq -n --arg id "$UUID" --arg email "$EMAIL_TAG" \
      '{id:$id, alterId:0, email:$email}')
    ;;
  trojan)
    # Trojan clients authenticate with a password, not a UUID — reusing
    # the same random UUID string as the password value is standard
    # practice (it's just a convenient, already-generated random secret).
    CLIENT=$(jq -n --arg password "$UUID" --arg email "$EMAIL_TAG" \
      '{password:$password, email:$email}')
    ;;
  shadowsocks)
    # aes-256-gcm: widely supported by every SS-capable client, unlike the
    # newer 2022-blake3 ciphers which need server-PSK/sub-key handling.
    CLIENT=$(jq -n --arg method "aes-256-gcm" --arg password "$UUID" --arg email "$EMAIL_TAG" \
      '{method:$method, password:$password, email:$email}')
    ;;
esac

# --- append atomically ---
tmp=$(mktemp)
jq --arg proto "$PROTOCOL" --argjson client "$CLIENT" '
  (.inbounds[] | select(.protocol==$proto) | .settings.clients) += [$client]
' "$CONFIG" > "$tmp" && chmod 644 "$tmp" && mv "$tmp" "$CONFIG"

systemctl restart xray

HOSTNAME_VAL="$(cat "$DOMAIN_FILE" 2>/dev/null)"
[[ -z "$HOSTNAME_VAL" ]] && HOSTNAME_VAL="$(curl -s https://api.ipify.org || hostname -I | awk '{print $1}')"

case "$PROTOCOL" in
vmess)
  LINK_TLS="$(vmess_link "$USERNAME" "$HOSTNAME_VAL" "443" "$UUID" "ws" "/vmess" "tls")"
  LINK_PLAIN="$(vmess_link "$USERNAME" "$HOSTNAME_VAL" "80" "$UUID" "ws" "/vmess" "")"
  LINK_GRPC="$(vmess_link "$USERNAME" "$HOSTNAME_VAL" "443" "$UUID" "grpc" "vmess-grpc" "tls")"

  cat <<CARD
====================================
   Xray/Vmess Account
====================================
Remarks       : ${USERNAME}
Domain        : ${HOSTNAME_VAL}
Port TLS      : 443
Port none TLS : 80
Port GRPC     : 443
id            : ${UUID}
alterId       : 0
Security      : auto
Network       : ws
Path          : /vmess
ServiceName   : vmess-grpc
====================================
Link TLS      : ${LINK_TLS}
====================================
Link none TLS : ${LINK_PLAIN}
====================================
Link GRPC     : ${LINK_GRPC}
====================================
Expired On    : ${EXPIRY}
====================================
CARD
  ;;
vless)
  LINK_TLS="$(vless_link "$USERNAME" "$HOSTNAME_VAL" "443" "$UUID" "ws" "/vless" "tls")"
  LINK_PLAIN="$(vless_link "$USERNAME" "$HOSTNAME_VAL" "80" "$UUID" "ws" "/vless" "none")"
  LINK_GRPC="$(vless_link "$USERNAME" "$HOSTNAME_VAL" "443" "$UUID" "grpc" "vless-grpc" "tls")"

  cat <<CARD
====================================
   Xray/Vless Account
====================================
Remarks       : ${USERNAME}
Domain        : ${HOSTNAME_VAL}
Port TLS      : 443
Port none TLS : 80
Port GRPC     : 443
id            : ${UUID}
Encryption    : none
Network       : ws
Path          : /vless
ServiceName   : vless-grpc
====================================
Link TLS      : ${LINK_TLS}
====================================
Link none TLS : ${LINK_PLAIN}
====================================
Link GRPC     : ${LINK_GRPC}
====================================
Expired On    : ${EXPIRY}
====================================
CARD
  ;;
trojan)
  LINK_TLS="$(trojan_link "$USERNAME" "$HOSTNAME_VAL" "443" "$UUID" "ws" "/trojan")"
  LINK_GRPC="$(trojan_link "$USERNAME" "$HOSTNAME_VAL" "443" "$UUID" "grpc" "trojan-grpc")"

  cat <<CARD
====================================
   Xray/Trojan Account
====================================
Remarks       : ${USERNAME}
Domain        : ${HOSTNAME_VAL}
Port TLS      : 443
Port GRPC     : 443
password      : ${UUID}
Network       : ws
Path          : /trojan
ServiceName   : trojan-grpc
====================================
Link TLS      : ${LINK_TLS}
====================================
Link GRPC     : ${LINK_GRPC}
====================================
Expired On    : ${EXPIRY}
====================================
CARD
  ;;
shadowsocks)
  LINK="$(ss_link "$USERNAME" "$HOSTNAME_VAL" "8388" "aes-256-gcm" "$UUID")"

  cat <<CARD
====================================
   Xray/Shadowsocks Account
====================================
Remarks       : ${USERNAME}
Domain        : ${HOSTNAME_VAL}
Port          : 8388
Method        : aes-256-gcm
password      : ${UUID}
====================================
Link          : ${LINK}
====================================
Expired On    : ${EXPIRY}
====================================
CARD
  ;;
esac

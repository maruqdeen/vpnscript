#!/bin/bash
# VPN-Starter-Kit :: menu/add-user.sh
# Add an Xray user (VLESS or VMess) into the live config via jq.
# Usage: add-user.sh <vless|vmess>
set -euo pipefail

CONFIG="/usr/local/etc/xray/config.json"
PROTOCOL="${1:-}"
DOMAIN_FILE="/etc/vpn-script/domain"

if [[ "$PROTOCOL" != "vless" && "$PROTOCOL" != "vmess" ]]; then
  echo "Usage: add-user.sh <vless|vmess>"
  exit 1
fi

# vmess:// share-link JSON (v2rayN standard schema — "path", not "bpath").
# host = WS Host header, sni = TLS SNI: both set to $add (the domain) so
# the WS upgrade and the TLS handshake both present the real hostname
# instead of going out blank/as the bare IP.
# base64'd with no line wrapping: `base64 | tr -d '\n'` is portable across
# GNU/BSD base64 (unlike relying on a `-w0` flag that not all builds have).
vmess_link() {
  local ps="$1" add="$2" port="$3" id="$4" net="$5" path="$6" tls="$7" json
  json=$(printf '{"v":"2","ps":"%s","add":"%s","port":"%s","id":"%s","aid":"0","scy":"auto","net":"%s","type":"none","host":"%s","path":"%s","tls":"%s","sni":"%s"}' \
    "$ps" "$add" "$port" "$id" "$net" "$add" "$path" "$tls" "$add")
  printf 'vmess://%s' "$(printf '%s' "$json" | base64 | tr -d '\n')"
}

# vless:// share link — a query-string URI, not base64 JSON like vmess.
# net=ws: host+path set (host = domain, same host/sni fix as vmess).
# net=grpc: serviceName set instead of host/path. sni added whenever TLS
# is used. "flow"/"fp" (XTLS/REALITY fingerprinting) deliberately omitted
# — those only apply over raw TCP, not the WS/gRPC transports we run.
vless_link() {
  local ps="$1" add="$2" port="$3" id="$4" net="$5" path="$6" security="$7" q
  q="encryption=none&security=${security}&type=${net}"
  if [[ "$net" == "grpc" ]]; then
    q="${q}&serviceName=${path}"
  else
    q="${q}&host=${add}&path=$(printf '%s' "$path" | sed 's|/|%2F|g')"
  fi
  [[ "$security" == "tls" ]] && q="${q}&sni=${add}"
  printf 'vless://%s@%s:%s?%s#%s' "$id" "$add" "$port" "$q" "$ps"
}

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
if [[ "$PROTOCOL" == "vless" ]]; then
  CLIENT=$(jq -n --arg id "$UUID" --arg email "$EMAIL_TAG" \
    '{id:$id, email:$email}')
else
  CLIENT=$(jq -n --arg id "$UUID" --arg email "$EMAIL_TAG" \
    '{id:$id, alterId:0, email:$email}')
fi

# --- append atomically ---
tmp=$(mktemp)
jq --arg proto "$PROTOCOL" --argjson client "$CLIENT" '
  (.inbounds[] | select(.protocol==$proto) | .settings.clients) += [$client]
' "$CONFIG" > "$tmp" && chmod 644 "$tmp" && mv "$tmp" "$CONFIG"

systemctl restart xray

HOSTNAME_VAL="$(cat "$DOMAIN_FILE" 2>/dev/null)"
[[ -z "$HOSTNAME_VAL" ]] && HOSTNAME_VAL="$(curl -s https://api.ipify.org || hostname -I | awk '{print $1}')"

if [[ "$PROTOCOL" == "vmess" ]]; then
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
else
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
fi
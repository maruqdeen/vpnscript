#!/bin/bash
# VPN-Starter-Kit :: menu/trial-vless-user.sh
# One-command 1-day trial Xray/VLESS account: random "trialNNNN" remarks so
# multiple trials can coexist without colliding (unlike the fixed-name SSH
# trial, which is deliberately single-slot).
set -euo pipefail

CONFIG="/usr/local/etc/xray/config.json"
DOMAIN_FILE="/etc/vpn-script/domain"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."; exit 1
fi
if [[ ! -f "$CONFIG" ]]; then
  echo "Error: Xray config not found at $CONFIG"
  exit 1
fi

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

# pick a remarks tag that isn't already in use, e.g. "trial5980"
USERNAME=""
for _ in 1 2 3 4 5; do
  candidate="trial$(( RANDOM % 9000 + 1000 ))"
  if ! jq -e --arg name "$candidate" '
      .inbounds[] | select(.protocol=="vless") | .settings.clients[]
      | select((.email | split("_")[0]) == $name)
    ' "$CONFIG" >/dev/null 2>&1; then
    USERNAME="$candidate"
    break
  fi
done
if [[ -z "$USERNAME" ]]; then
  echo "Could not find a free trial name, try again."; exit 1
fi

UUID=$(cat /proc/sys/kernel/random/uuid)
EXPIRY=$(date -d "+1 day" +%Y-%m-%d)
EMAIL_TAG="${USERNAME}_${EXPIRY}"

CLIENT=$(jq -n --arg id "$UUID" --arg email "$EMAIL_TAG" '{id:$id, email:$email}')

tmp=$(mktemp)
jq --argjson client "$CLIENT" '
  (.inbounds[] | select(.protocol=="vless") | .settings.clients) += [$client]
' "$CONFIG" > "$tmp" && chmod 644 "$tmp" && mv "$tmp" "$CONFIG"

systemctl restart xray

HOSTNAME_VAL="$(cat "$DOMAIN_FILE" 2>/dev/null)"
[[ -z "$HOSTNAME_VAL" ]] && HOSTNAME_VAL="$(curl -s https://api.ipify.org || hostname -I | awk '{print $1}')"

LINK_TLS="$(vless_link "$USERNAME" "$HOSTNAME_VAL" "443" "$UUID" "ws" "/vless" "tls")"
LINK_PLAIN="$(vless_link "$USERNAME" "$HOSTNAME_VAL" "80" "$UUID" "ws" "/vless" "none")"
LINK_GRPC="$(vless_link "$USERNAME" "$HOSTNAME_VAL" "443" "$UUID" "grpc" "vless-grpc" "tls")"

cat <<CARD
====================================
   Trial Xray/Vless
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

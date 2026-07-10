#!/bin/bash
# VPN-Starter-Kit :: menu/trial-vmess-user.sh
# One-command 1-day trial Xray/VMess account: random "trialNNNN" remarks so
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

vmess_link() {
  local ps="$1" add="$2" port="$3" id="$4" net="$5" path="$6" tls="$7" json
  json=$(printf '{"v":"2","ps":"%s","add":"%s","port":"%s","id":"%s","aid":"0","scy":"auto","net":"%s","type":"none","host":"%s","path":"%s","tls":"%s","sni":"%s"}' \
    "$ps" "$add" "$port" "$id" "$net" "$add" "$path" "$tls" "$add")
  printf 'vmess://%s' "$(printf '%s' "$json" | base64 | tr -d '\n')"
}

# pick a remarks tag that isn't already in use, e.g. "trial5980"
USERNAME=""
for _ in 1 2 3 4 5; do
  candidate="trial$(( RANDOM % 9000 + 1000 ))"
  if ! jq -e --arg name "$candidate" '
      .inbounds[] | select(.protocol=="vmess") | .settings.clients[]
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

CLIENT=$(jq -n --arg id "$UUID" --arg email "$EMAIL_TAG" '{id:$id, alterId:0, email:$email}')

tmp=$(mktemp)
jq --argjson client "$CLIENT" '
  (.inbounds[] | select(.protocol=="vmess") | .settings.clients) += [$client]
' "$CONFIG" > "$tmp" && chmod 644 "$tmp" && mv "$tmp" "$CONFIG"

systemctl restart xray

HOSTNAME_VAL="$(cat "$DOMAIN_FILE" 2>/dev/null)"
[[ -z "$HOSTNAME_VAL" ]] && HOSTNAME_VAL="$(curl -s https://api.ipify.org || hostname -I | awk '{print $1}')"

LINK_TLS="$(vmess_link "$USERNAME" "$HOSTNAME_VAL" "443" "$UUID" "ws" "/vmess" "tls")"
LINK_PLAIN="$(vmess_link "$USERNAME" "$HOSTNAME_VAL" "80" "$UUID" "ws" "/vmess" "")"
LINK_GRPC="$(vmess_link "$USERNAME" "$HOSTNAME_VAL" "443" "$UUID" "grpc" "vmess-grpc" "tls")"

cat <<CARD
====================================
   Trial Xray/Vmess
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

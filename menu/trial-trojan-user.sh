#!/bin/bash
# VPN-Starter-Kit :: menu/trial-trojan-user.sh
# One-command 1-day trial Xray/Trojan account: random "trialNNNN" remarks so
# multiple trials can coexist without colliding (unlike the fixed-name SSH
# trial, which is deliberately single-slot). TLS-only, same reasoning as
# add-user.sh's trojan branch: a plaintext Trojan defeats its own purpose.
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

trojan_link() {
  local ps="$1" add="$2" port="$3" password="$4" net="$5" path="$6" q
  q="security=tls&type=${net}"
  if [[ "$net" == "grpc" ]]; then
    q="${q}&serviceName=${path}"
  else
    q="${q}&host=${add}&path=$(printf '%s' "$path" | sed 's|/|%2F|g')"
  fi
  q="${q}&sni=${add}"
  printf 'trojan://%s@%s:%s?%s#%s' "$password" "$add" "$port" "$q" "$ps"
}

# pick a remarks tag that isn't already in use, e.g. "trial5980"
USERNAME=""
for _ in 1 2 3 4 5; do
  candidate="trial$(( RANDOM % 9000 + 1000 ))"
  if ! jq -e --arg name "$candidate" '
      .inbounds[] | select(.protocol=="trojan") | .settings.clients[]
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

CLIENT=$(jq -n --arg password "$UUID" --arg email "$EMAIL_TAG" '{password:$password, email:$email}')

tmp=$(mktemp)
jq --argjson client "$CLIENT" '
  (.inbounds[] | select(.protocol=="trojan") | .settings.clients) += [$client]
' "$CONFIG" > "$tmp" && chmod 644 "$tmp" && mv "$tmp" "$CONFIG"

systemctl restart xray

HOSTNAME_VAL="$(cat "$DOMAIN_FILE" 2>/dev/null)"
[[ -z "$HOSTNAME_VAL" ]] && HOSTNAME_VAL="$(curl -s https://api.ipify.org || hostname -I | awk '{print $1}')"

LINK_TLS="$(trojan_link "$USERNAME" "$HOSTNAME_VAL" "443" "$UUID" "ws" "/trojan")"
LINK_GRPC="$(trojan_link "$USERNAME" "$HOSTNAME_VAL" "443" "$UUID" "grpc" "trojan-grpc")"

cat <<CARD
====================================
   Trial Xray/Trojan
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

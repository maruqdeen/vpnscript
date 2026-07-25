#!/bin/bash
# VPN-Starter-Kit :: menu/trial-ss-user.sh
# One-command 1-day trial Xray/Shadowsocks account: random "trialNNNN"
# remarks so multiple trials can coexist without colliding (unlike the
# fixed-name SSH trial, which is deliberately single-slot).
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

# Plain SIP002 link only — see add-user.sh's ss_link for why the earlier
# WS/gRPC+TLS query-param form doesn't actually work with real SS clients.
ss_link() {
  local ps="$1" add="$2" port="$3" method="$4" password="$5" userinfo
  userinfo="$(printf '%s' "${method}:${password}" | base64 | tr -d '\n')"
  printf 'ss://%s@%s:%s#%s' "$userinfo" "$add" "$port" "$ps"
}

# pick a remarks tag that isn't already in use, e.g. "trial5980"
USERNAME=""
for _ in 1 2 3 4 5; do
  candidate="trial$(( RANDOM % 9000 + 1000 ))"
  if ! jq -e --arg name "$candidate" '
      .inbounds[] | select(.protocol=="shadowsocks") | .settings.clients[]
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

CLIENT=$(jq -n --arg method "aes-256-gcm" --arg password "$UUID" --arg email "$EMAIL_TAG" \
  '{method:$method, password:$password, email:$email}')

tmp=$(mktemp)
jq --argjson client "$CLIENT" '
  (.inbounds[] | select(.protocol=="shadowsocks") | .settings.clients) += [$client]
' "$CONFIG" > "$tmp" && chmod 644 "$tmp" && mv "$tmp" "$CONFIG"

systemctl restart xray

HOSTNAME_VAL="$(cat "$DOMAIN_FILE" 2>/dev/null)"
[[ -z "$HOSTNAME_VAL" ]] && HOSTNAME_VAL="$(curl -s https://api.ipify.org || hostname -I | awk '{print $1}')"

LINK="$(ss_link "$USERNAME" "$HOSTNAME_VAL" "8388" "aes-256-gcm" "$UUID")"

cat <<CARD
====================================
   Trial Xray/Shadowsocks
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

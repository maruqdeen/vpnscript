#!/bin/bash
# VPN-Starter-Kit :: menu/add-user.sh
# Add an Xray user (VLESS or VMess) into the live config via jq.
# Usage: add-user.sh <vless|vmess>
set -euo pipefail

CONFIG="/usr/local/etc/xray/config.json"
PROTOCOL="${1:-}"

if [[ "$PROTOCOL" != "vless" && "$PROTOCOL" != "vmess" ]]; then
  echo "Usage: add-user.sh <vless|vmess>"
  exit 1
fi

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
' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"

systemctl restart xray

echo "==========================================="
echo " ${PROTOCOL^^} user created"
echo "   Username : $USERNAME"
echo "   UUID     : $UUID"
echo "   Path     : /$PROTOCOL"
echo "   Expires  : $EXPIRY"
echo "==========================================="
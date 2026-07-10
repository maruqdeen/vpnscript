#!/bin/bash
# VPN-Starter-Kit :: menu/renew-wireguard-user.sh
# Extend a WireGuard peer's expiry date. WireGuard has no native expiry
# enforcement (same limitation as the Xray protocols in this repo) — this
# is a tracked date only, the peer stays live either way until deleted.
set -euo pipefail

CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../core" && pwd)"
source "$CORE_DIR/wireguard.sh"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."; exit 1
fi

wg_ensure_server

echo "Current WireGuard peers:"
mapfile -t USERS < <(jq -r '.[].username' "$WG_CLIENTS_JSON" 2>/dev/null)
if [[ ${#USERS[@]} -eq 0 ]]; then
  echo "  (none)"; exit 1
fi
jq -r '.[] | "  - " + .username + "   (expires " + .expiry + ")"' "$WG_CLIENTS_JSON"

echo ""
read -rp "Enter username to renew : " NAME
read -rp "Add how many days        : " DAYS

if ! [[ "$DAYS" =~ ^[0-9]+$ ]]; then
  echo "Days must be a number."; exit 1
fi
if ! jq -e --arg n "$NAME" '.[] | select(.username==$n)' "$WG_CLIENTS_JSON" >/dev/null 2>&1; then
  echo "No WireGuard peer named '$NAME'."; exit 1
fi

NEW_EXP=$(date -d "+${DAYS} days" +%Y-%m-%d)
tmp=$(mktemp)
jq --arg n "$NAME" --arg e "$NEW_EXP" \
  '(.[] | select(.username==$n) | .expiry) = $e' \
  "$WG_CLIENTS_JSON" > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$WG_CLIENTS_JSON"
echo "Renewed WireGuard peer '$NAME' -> expires $NEW_EXP."

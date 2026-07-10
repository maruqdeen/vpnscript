#!/bin/bash
# VPN-Starter-Kit :: menu/del-wireguard-user.sh
# Remove a WireGuard peer — hot-reloaded, no restart needed.
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
jq -r '.[] | "  - " + .username + "   (expires " + .expiry + ", " + .address + "/32)"' "$WG_CLIENTS_JSON"

echo ""
read -rp "Enter username to delete: " NAME

if ! jq -e --arg n "$NAME" '.[] | select(.username==$n)' "$WG_CLIENTS_JSON" >/dev/null 2>&1; then
  echo "No WireGuard peer named '$NAME'."; exit 1
fi

tmp=$(mktemp)
jq --arg n "$NAME" 'map(select(.username != $n))' "$WG_CLIENTS_JSON" > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$WG_CLIENTS_JSON"
wg_sync_peers
echo "Deleted WireGuard peer '$NAME'."

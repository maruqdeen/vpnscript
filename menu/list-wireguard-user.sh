#!/bin/bash
# VPN-Starter-Kit :: menu/list-wireguard-user.sh
# List every WireGuard peer with its assigned address and expiry date.
set -euo pipefail

CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../core" && pwd)"
source "$CORE_DIR/wireguard.sh"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."; exit 1
fi

wg_ensure_server

printf '%s\n' "===================================================="
printf "%20s\n" "MEMBER WIREGUARD"
printf '%s\n' "===================================================="
echo ""
printf "%-18s %-14s %s\n" "USERNAME" "ADDRESS" "EXP DATE"
echo ""

COUNT=$(jq 'length' "$WG_CLIENTS_JSON" 2>/dev/null || echo 0)
if [[ "$COUNT" -eq 0 ]]; then
  echo "  (no accounts yet)"
else
  jq -r '.[] | [.username, (.address + "/32"), .expiry] | @tsv' "$WG_CLIENTS_JSON" \
    | while IFS=$'\t' read -r u a e; do
        printf "%-18s %-14s %s\n" "$u" "$a" "$e"
      done
fi

echo ""
printf '%s\n' "===================================================="
echo "Account number: ${COUNT} user"
printf '%s\n' "===================================================="

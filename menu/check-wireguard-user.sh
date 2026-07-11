#!/bin/bash
# VPN-Starter-Kit :: menu/check-wireguard-user.sh
# Count how many WireGuard peers are currently active, via `wg show
# <iface> dump` — the purpose-built tool for this (unlike SSH/Dropbear,
# which has no equivalent). A peer re-handshakes roughly every 2 minutes
# while actively passing traffic, so a recent handshake timestamp is a
# reliable "currently connected" signal.
set -euo pipefail

CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../core" && pwd)"
source "$CORE_DIR/wireguard.sh"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."; exit 1
fi

wg_ensure_server

ACTIVE_WINDOW=180  # seconds — a bit more than WireGuard's ~2min rekey interval

TOTAL=$(jq 'length' "$WG_CLIENTS_JSON" 2>/dev/null || echo 0)
ACTIVE=0

if [[ "$TOTAL" -gt 0 ]]; then
  NOW=$(date +%s)
  # dump: line 1 is the interface itself; one line per peer after that.
  # Peer fields (tab-separated): pubkey  psk  endpoint  allowed-ips  latest-handshake  rx  tx  keepalive
  DUMP="$(wg show "$WG_IFACE" dump 2>/dev/null | tail -n +2)"

  # Process substitution, not a pipe into `while` — a piped while loop
  # runs in a subshell, so incrementing ACTIVE inside it wouldn't survive
  # past the loop.
  while IFS=$'\t' read -r uname pubkey; do
    hs="$(printf '%s\n' "$DUMP" | awk -F'\t' -v pk="$pubkey" '$1==pk{print $5}')"
    [[ "$hs" =~ ^[0-9]+$ ]] || hs=0
    if (( hs > 0 && NOW - hs <= ACTIVE_WINDOW )); then
      ACTIVE=$((ACTIVE + 1))
    fi
  done < <(jq -r '.[] | [.username, .public_key] | @tsv' "$WG_CLIENTS_JSON")
fi

printf '%s\n' "===================================================="
printf "%20s\n" "CHECK ACTIVE WIREGUARD"
printf '%s\n' "===================================================="
echo ""
echo "Active Wireguard Users : ${ACTIVE}"
echo "Total Registered       : ${TOTAL}"
printf '%s\n' "===================================================="

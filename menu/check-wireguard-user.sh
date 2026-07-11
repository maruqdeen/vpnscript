#!/bin/bash
# VPN-Starter-Kit :: menu/check-wireguard-user.sh
# Show each WireGuard peer's connection status via `wg show <iface> dump`
# — the purpose-built tool for this, unlike the SSH/Dropbear case (no such
# tool exists there, which is why that one needed log-scraping). A peer
# re-handshakes roughly every 2 minutes while actively passing traffic, so
# a recent handshake timestamp is a reliable "currently connected" signal.
set -euo pipefail

CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../core" && pwd)"
source "$CORE_DIR/wireguard.sh"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."; exit 1
fi

wg_ensure_server

G=$'\e[0;32m'; R=$'\e[0;31m'; X=$'\e[0m'
ACTIVE_WINDOW=180  # seconds — a bit more than WireGuard's ~2min rekey interval

printf '%s\n' "===================================================="
printf "%20s\n" "CHECK ACTIVE WIREGUARD"
printf '%s\n' "===================================================="
echo ""
printf "%-18s %-20s %s\n" "USERNAME" "STATUS" "LAST HANDSHAKE"
echo ""

COUNT=$(jq 'length' "$WG_CLIENTS_JSON" 2>/dev/null || echo 0)
if [[ "$COUNT" -eq 0 ]]; then
  echo "  (no accounts yet)"
else
  NOW=$(date +%s)
  # dump: line 1 is the interface itself; one line per peer after that.
  # Peer fields (tab-separated): pubkey  psk  endpoint  allowed-ips  latest-handshake  rx  tx  keepalive
  DUMP="$(wg show "$WG_IFACE" dump 2>/dev/null | tail -n +2)"

  jq -r '.[] | [.username, .public_key] | @tsv' "$WG_CLIENTS_JSON" | while IFS=$'\t' read -r uname pubkey; do
    hs="$(printf '%s\n' "$DUMP" | awk -F'\t' -v pk="$pubkey" '$1==pk{print $5}')"
    [[ "$hs" =~ ^[0-9]+$ ]] || hs=0

    # Pad the plain status text to a fixed width BEFORE wrapping it in
    # color escapes — padding the already-colored string would count the
    # invisible escape bytes toward the width and misalign the column.
    if (( hs > 0 && NOW - hs <= ACTIVE_WINDOW )); then
      status_txt="Active"; color="$G"
      last="$((NOW - hs))s ago"
    elif (( hs > 0 )); then
      status_txt="Inactive"; color="$R"
      last="$(( (NOW - hs) / 60 ))m ago"
    else
      status_txt="Inactive"; color="$R"
      last="never"
    fi
    printf "%-18s %b%-10s%b %s\n" "$uname" "$color" "$status_txt" "$X" "$last"
  done
fi

echo ""
printf '%s\n' "===================================================="
echo "Account number: ${COUNT} user"
printf '%s\n' "===================================================="

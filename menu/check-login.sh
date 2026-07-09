#!/bin/bash
# VPN-Starter-Kit :: menu/check-login.sh
# Show every SSH-WS + SlowDNS account with its current number of logged-in
# devices (distinct remote IPs seen in `who`).
set -uo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."; exit 1
fi

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$BASE/lib-ssh-users.sh"

clear
echo ""
printf '%s\n' "=================================================="
printf "%22s\n" "CHECK LOGIN SSH"
printf '%s\n' "=================================================="
echo ""
printf "%-18s %s\n" "USERNAME" "LOGIN COUNT"
echo ""

users="$(ssh_user_list)"
if [[ -z "$users" ]]; then
  echo "  (no accounts yet)"
else
  while read -r u; do
    [[ -z "$u" ]] && continue
    printf "%-18s %s\n" "$u" "$(ssh_user_login_count "$u")"
  done <<< "$users"
fi

echo ""
printf '%s\n' "=================================================="

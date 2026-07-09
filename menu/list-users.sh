#!/bin/bash
# VPN-Starter-Kit :: menu/list-users.sh
# Lists every SSH-WS + SlowDNS account with expiry date + lock status.
set -uo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."; exit 1
fi

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$BASE/lib-ssh-users.sh"

clear
echo ""
print_ssh_table

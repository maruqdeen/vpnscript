#!/bin/bash
# VPN-Starter-Kit :: menu/multilogin-check.sh
# List accounts currently over the multilogin limit and let the admin decide:
# delete the account outright, or release it (kill sessions + unlock the
# password, in case autokill locked it — keeps the account for the user).
set -uo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."; exit 1
fi

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$BASE/lib-ssh-users.sh"

LIMIT_FILE="/etc/vpn-script/autokill.limit"
LIMIT="$(cat "$LIMIT_FILE" 2>/dev/null)"
[[ "$LIMIT" =~ ^[0-9]+$ ]] || LIMIT=1

clear
echo ""
printf '%s\n' "=================================================="
printf "%26s\n" "MULTI LOGIN CHECK"
printf '%s\n' "=================================================="
echo "(limit: $LIMIT device(s) per account)"
echo ""

FLAGGED=()
while read -r u; do
  [[ -z "$u" ]] && continue
  count="$(ssh_user_login_count "$u")"
  if (( count > LIMIT )); then
    FLAGGED+=("$u")
    printf "  - %-16s (%s logins)\n" "$u" "$count"
  fi
done < <(ssh_user_list)

if [[ ${#FLAGGED[@]} -eq 0 ]]; then
  echo "  (no accounts currently over the limit)"
  echo ""
  printf '%s\n' "=================================================="
  exit 0
fi

echo ""
read -rp "Enter username to act on (blank to exit): " NAME
[[ -z "$NAME" ]] && exit 0

match=""
for u in "${FLAGGED[@]}"; do
  [[ "$u" == "$NAME" ]] && match="$u"
done
if [[ -z "$match" ]]; then
  echo "'$NAME' is not currently flagged for multilogin."; exit 1
fi

echo ""
echo "  [1] Delete account"
echo "  [2] Release (kill sessions + unlock, keep account)"
read -rp "Choose: " act

case "$act" in
  1)
    pkill -u "$match" 2>/dev/null || true
    userdel "$match" 2>/dev/null || true
    echo "Deleted '$match'."
    ;;
  2)
    pkill -u "$match" 2>/dev/null || true
    passwd -u "$match" >/dev/null 2>&1 || true
    echo "Released '$match' — sessions killed, account unlocked."
    ;;
  *) echo "Invalid option." ;;
esac

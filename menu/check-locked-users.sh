#!/bin/bash
# VPN-Starter-Kit :: menu/check-locked-users.sh
# Lists every locked SSH/SlowDNS account with WHY it was locked, and lets
# the admin resolve it. The right fix depends on the reason: a multilogin
# lock just needs a plain unlock, but a connection/bandwidth lock needs
# the underlying limit actually raised, or the next enforcement pass
# (core/ssh-limits-check.sh, every 2 min) just locks it right back.
set -uo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$BASE/lib-ssh-users.sh"
source "$BASE/../core/ssh-limits.sh"
source "$BASE/../core/lock-reasons.sh"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."; exit 1
fi

reason_label() {
  case "$1" in
    multilogin) echo "Multi login" ;;
    bandwidth)  echo "Bandwith Exceeded" ;;
    connection) echo "Conn Limit Exceeded" ;;
    *)          echo "Locked" ;;
  esac
}

delete_locked() {
  local uname="$1"
  pkill -u "$uname" 2>/dev/null || true
  userdel "$uname" 2>/dev/null || true
  ssh_limits_remove "$uname"
  lock_reason_clear "$uname"
  echo "Deleted '$uname'."
}

printf '%s\n' "===================================================="
printf "%18s\n" "LOCKED USERS"
printf '%s\n' "===================================================="
echo ""
printf "%-18s %-22s %s\n" "USERNAME" "REASON" "STATUS"
echo ""

LOCKED=()
while read -r u; do
  [[ -z "$u" ]] && continue
  pstate="$(passwd -S "$u" 2>/dev/null | awk '{print $2}')"
  if [[ "$pstate" == "L" ]]; then
    reason="$(lock_reason_get "$u")"
    LOCKED+=("$u")
    printf "%-18s %-22s %s\n" "$u" "$(reason_label "$reason")" "Locked"
  fi
done < <(ssh_user_list)

if [[ ${#LOCKED[@]} -eq 0 ]]; then
  echo "  (no locked accounts)"
  echo ""
  printf '%s\n' "===================================================="
  exit 0
fi

echo ""
read -rp "Enter locked Username to perform action (blank to exit): " NAME
[[ -z "$NAME" ]] && exit 0

match=""
for u in "${LOCKED[@]}"; do
  [[ "$u" == "$NAME" ]] && match="$u"
done
if [[ -z "$match" ]]; then
  echo "'$NAME' is not currently locked."; exit 1
fi

REASON="$(lock_reason_get "$match")"

case "$REASON" in
  bandwidth)
    echo ""
    echo "  [1] Unlock by extending bandwidth (GB)"
    echo "  [2] Delete"
    echo "  [0] Go back"
    read -rp "Choose: " act
    case "$act" in
      1)
        read -rp "Extend bandwidth by how many GB: " GB
        if ! [[ "$GB" =~ ^[0-9]+$ ]]; then echo "Must be a number."; exit 1; fi
        tmp=$(mktemp)
        jq --arg u "$match" --argjson add "$(( GB * 1024 ))" '
          map(if .username == $u then .bw_limit_mb += $add else . end)
        ' "$SSH_LIMITS_JSON" > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$SSH_LIMITS_JSON"
        passwd -u "$match" >/dev/null 2>&1 || true
        lock_reason_clear "$match"
        echo "Unlocked '$match' — bandwidth limit increased by ${GB}GB."
        ;;
      2) delete_locked "$match" ;;
      *) echo "Invalid option." ;;
    esac
    ;;
  connection)
    echo ""
    echo "  [1] Unlock by increasing connection limit"
    echo "  [2] Delete"
    echo "  [0] Go back"
    read -rp "Choose: " act
    case "$act" in
      1)
        read -rp "New connection limit: " NEWLIM
        if ! [[ "$NEWLIM" =~ ^[0-9]+$ ]]; then echo "Must be a number."; exit 1; fi
        tmp=$(mktemp)
        jq --arg u "$match" --argjson lim "$NEWLIM" '
          map(if .username == $u then .conn_limit = $lim else . end)
        ' "$SSH_LIMITS_JSON" > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$SSH_LIMITS_JSON"
        passwd -u "$match" >/dev/null 2>&1 || true
        lock_reason_clear "$match"
        echo "Unlocked '$match' — connection limit set to ${NEWLIM}."
        ;;
      2) delete_locked "$match" ;;
      *) echo "Invalid option." ;;
    esac
    ;;
  *)
    # multilogin, or a legacy/unknown lock with no tracked reason
    echo ""
    echo "  [1] Unlock"
    echo "  [2] Delete"
    echo "  [0] Go back"
    read -rp "Choose: " act
    case "$act" in
      1)
        passwd -u "$match" >/dev/null 2>&1 || true
        lock_reason_clear "$match"
        echo "Unlocked '$match'."
        ;;
      2) delete_locked "$match" ;;
      *) echo "Invalid option." ;;
    esac
    ;;
esac

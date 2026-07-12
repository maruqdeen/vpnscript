#!/bin/bash
# VPN-Starter-Kit :: menu/autokill-check.sh
# Cron worker installed/removed by autokill-setup.sh. Runs every 2 minutes;
# locks (passwd -l) + kills sessions (pkill) for any SSH/SlowDNS account
# logged in from more devices than the configured limit.
set -uo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$BASE/lib-ssh-users.sh"
source "$BASE/../core/lock-reasons.sh"

STATE_DIR="/etc/vpn-script"
FLAG="$STATE_DIR/autokill.enabled"
LIMIT_FILE="$STATE_DIR/autokill.limit"

[[ -f "$FLAG" ]] || exit 0

LIMIT="$(cat "$LIMIT_FILE" 2>/dev/null)"
[[ "$LIMIT" =~ ^[0-9]+$ ]] || LIMIT=1

while read -r u; do
  [[ -z "$u" ]] && continue
  count="$(ssh_user_login_count "$u")"
  if (( count > LIMIT )); then
    pstate="$(passwd -S "$u" 2>/dev/null | awk '{print $2}')"
    if [[ "$pstate" != "L" ]]; then
      echo "$(date '+%F %T') multilogin: $u has $count logins (limit $LIMIT) -> locking + killing sessions"
      passwd -l "$u" >/dev/null 2>&1 || true
      lock_reason_set "$u" "multilogin"
    fi
    pkill -u "$u" 2>/dev/null || true
  fi
done < <(ssh_user_list)

#!/bin/bash
# VPN-Starter-Kit :: menu/autokill-check.sh
# Cron worker installed/removed by autokill-setup.sh. Runs every 2 minutes;
# locks (passwd -l) + kills sessions (pkill) for any SSH/SlowDNS account
# logged in from more devices than the configured limit.
#
# Perf: computes the engine + Dropbear PID/user map ONCE per run and
# reuses it for every account via ssh_user_login_count_cached() --
# previously called ssh_user_login_count() per account, which re-ran a
# full journalctl scan per account, every 2 minutes (real cost at 100+
# accounts). See menu/lib-ssh-users.sh for the cached helper.
#
# Debounce: a single momentary over-count doesn't lock+kill anymore --
# ssh_user_login_count() itself is documented as counting raw sockets,
# not distinct devices (one client app can legitimately open several
# parallel sockets, e.g. during its own reconnect/retry), so a lone
# over-limit reading is tracked as a "strike" and only acted on once an
# account is over limit on two CONSECUTIVE runs. Strikes reset the
# moment an account reads back under the limit.
set -uo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$BASE/lib-ssh-users.sh"
source "$BASE/../core/lock-reasons.sh"

STATE_DIR="/etc/vpn-script"
FLAG="$STATE_DIR/autokill.enabled"
LIMIT_FILE="$STATE_DIR/autokill.limit"
STRIKES_FILE="$STATE_DIR/autokill-strikes.json"

[[ -f "$FLAG" ]] || exit 0

LIMIT="$(cat "$LIMIT_FILE" 2>/dev/null)"
[[ "$LIMIT" =~ ^[0-9]+$ ]] || LIMIT=1

STRIKES="$(cat "$STRIKES_FILE" 2>/dev/null || echo '{}')"
jq empty <<< "$STRIKES" >/dev/null 2>&1 || STRIKES='{}'

ENGINE="$(cat "$STATE_DIR/ssh-engine" 2>/dev/null || echo both)"
DROPBEAR_MAP=""
[[ "$ENGINE" == "openssh" ]] || DROPBEAR_MAP="$(_dropbear_pid_user_map)"

while read -r u; do
  [[ -z "$u" ]] && continue
  count="$(ssh_user_login_count_cached "$u" "$ENGINE" "$DROPBEAR_MAP")"
  if (( count > LIMIT )); then
    prev_strikes="$(jq -r --arg u "$u" '.[$u] // 0' <<< "$STRIKES")"
    strikes=$(( prev_strikes + 1 ))
    if (( strikes >= 2 )); then
      pstate="$(passwd -S "$u" 2>/dev/null | awk '{print $2}')"
      if [[ "$pstate" != "L" ]]; then
        echo "$(date '+%F %T') multilogin: $u has $count logins (limit $LIMIT, ${strikes} consecutive checks) -> locking + killing sessions"
        passwd -l "$u" >/dev/null 2>&1 || true
        lock_reason_set "$u" "multilogin"
      fi
      pkill -u "$u" 2>/dev/null || true
      STRIKES="$(jq --arg u "$u" 'del(.[$u])' <<< "$STRIKES")"
    else
      echo "$(date '+%F %T') multilogin: $u has $count logins (limit $LIMIT) -> strike ${strikes}/2, not acting yet"
      STRIKES="$(jq --arg u "$u" --argjson s "$strikes" '.[$u] = $s' <<< "$STRIKES")"
    fi
  else
    STRIKES="$(jq --arg u "$u" 'del(.[$u])' <<< "$STRIKES")"
  fi
done < <(ssh_user_list)

echo "$STRIKES" > "$STRIKES_FILE"
chmod 600 "$STRIKES_FILE"

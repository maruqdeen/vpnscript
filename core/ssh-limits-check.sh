#!/bin/bash
# VPN-Starter-Kit :: core/ssh-limits-check.sh
# Cron worker (every 2 min, installed automatically the first time an
# account is given a connection or bandwidth limit — see
# ssh_limits_ensure_cron in core/ssh-limits.sh). Locks any account that
# has exceeded its own per-account connection or bandwidth limit.
#
# Bandwidth tracking is best-effort, not exact: Dropbear never setuid()s
# for our forwarding-only tunnel accounts (confirmed while fixing Check
# Active Users — see menu/lib-ssh-users.sh), so there's no clean per-UID
# accounting hook; iptables' owner-match doesn't see FORWARDed traffic
# this way either. Instead this samples /proc/<pid>/io (rchar+wchar) for
# each live Dropbear PID mapped to a username — reusing the exact PID/
# username mapping already built for the login counter — and accumulates
# the delta between samples into a running total per user. A connection
# that starts AND finishes entirely between two 2-minute samples would be
# missed. For the sustained, continuous tunnel sessions this system is
# built for, that's an accepted trade-off, not swept under the rug.
set -uo pipefail

INSTALL_DIR="/etc/vpn-script"
source "$INSTALL_DIR/menu/lib-ssh-users.sh"
source "$INSTALL_DIR/core/ssh-limits.sh"
source "$INSTALL_DIR/core/lock-reasons.sh"

ssh_limits_ensure_files

[[ -s "$SSH_LIMITS_JSON" ]] || exit 0
COUNT=$(jq 'length' "$SSH_LIMITS_JSON" 2>/dev/null || echo 0)
[[ "$COUNT" -gt 0 ]] || exit 0

# reason_code feeds menu/check-locked-users.sh so it can show a
# reason-appropriate recovery action instead of a generic unlock.
lock_if_unlocked() {
  local uname="$1" log_msg="$2" reason_code="$3"
  local pstate
  pstate="$(passwd -S "$uname" 2>/dev/null | awk '{print $2}')"
  if [[ "$pstate" != "L" ]]; then
    echo "$(date '+%F %T') $uname $log_msg -> locking"
    passwd -l "$uname" >/dev/null 2>&1 || true
    lock_reason_set "$uname" "$reason_code"
  fi
  pkill -u "$uname" 2>/dev/null || true
}

# ---- connection limit ----
while IFS=$'\t' read -r uname limit; do
  [[ -z "$uname" ]] && continue
  count="$(ssh_user_login_count "$uname")"
  if [[ "$count" -gt "$limit" ]]; then
    lock_if_unlocked "$uname" "exceeded connection limit ($count/$limit)" "connection"
  fi
done < <(jq -r '.[] | select(.conn_limit > 0) | [.username, .conn_limit] | @tsv' "$SSH_LIMITS_JSON")

# ---- bandwidth limit: sample + accumulate ----
LIVE_PIDS="$(pgrep dropbear 2>/dev/null)"
if [[ -n "$LIVE_PIDS" ]]; then
  PID_USER_MAP="$(_dropbear_pid_user_map)"

  if [[ -n "$PID_USER_MAP" ]]; then
    SAMPLES="$(cat "$SSH_BW_SAMPLES_JSON" 2>/dev/null || echo '{}')"
    NEW_SAMPLES="$SAMPLES"

    while IFS=' ' read -r pid uname; do
      [[ -z "$pid" ]] && continue
      io_file="/proc/$pid/io"
      [[ -r "$io_file" ]] || continue

      now_bytes=$(awk '/^rchar:|^wchar:/{sum+=$2} END{print sum+0}' "$io_file")
      prev_bytes=$(echo "$SAMPLES" | jq -r --arg p "$pid" '.[$p] // 0')
      delta=$(( now_bytes - prev_bytes ))
      # negative delta means this PID number got reused since our last
      # sample (a brand-new process, not the one we were tracking) —
      # skip crediting/debiting anything this cycle rather than guess.
      (( delta < 0 )) && delta=0

      NEW_SAMPLES="$(echo "$NEW_SAMPLES" | jq --arg p "$pid" --argjson v "$now_bytes" '.[$p] = $v')"

      if [[ "$delta" -gt 0 ]]; then
        tmp=$(mktemp)
        jq --arg u "$uname" --argjson d "$delta" '
          map(if .username == $u then .bw_used_bytes += $d else . end)
        ' "$SSH_LIMITS_JSON" > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$SSH_LIMITS_JSON"
      fi
    done <<< "$PID_USER_MAP"

    # Drop samples for PIDs no longer live, so this file doesn't grow forever.
    NEW_SAMPLES="$(echo "$NEW_SAMPLES" | jq --arg live "$LIVE_PIDS" '
      ($live | split("\n") | map(select(length > 0))) as $l
      | with_entries(select(.key as $k | $l | index($k)))
    ' 2>/dev/null)"
    [[ -n "$NEW_SAMPLES" ]] && echo "$NEW_SAMPLES" > "$SSH_BW_SAMPLES_JSON"
    chmod 600 "$SSH_BW_SAMPLES_JSON"
  fi
fi

# ---- bandwidth limit: check accumulated usage ----
while IFS=$'\t' read -r uname limit_mb used_bytes; do
  [[ -z "$uname" ]] && continue
  used_mb=$(( used_bytes / 1048576 ))
  if [[ "$used_mb" -gt "$limit_mb" ]]; then
    lock_if_unlocked "$uname" "exceeded bandwidth limit (${used_mb}MB/${limit_mb}MB)" "bandwidth"
  fi
done < <(jq -r '.[] | select(.bw_limit_mb > 0) | [.username, .bw_limit_mb, .bw_used_bytes] | @tsv' "$SSH_LIMITS_JSON")

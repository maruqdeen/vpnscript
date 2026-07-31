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
#
# Perf: the engine + Dropbear PID/user map is computed ONCE per run and
# shared by both the connection-limit loop and the bandwidth pass, via
# ssh_user_login_count_cached() (menu/lib-ssh-users.sh) -- previously
# every account in the connection-limit loop triggered its own fresh
# journalctl scan, and the bandwidth pass ran a second one on top of
# that. The bandwidth pass also now applies all accumulated deltas to
# ssh-limits.json in ONE jq pass at the end instead of one full-file
# read-modify-write per live connection.
#
# Debounce: a single momentary over-limit reading doesn't lock+kill
# anymore -- ssh_user_login_count() counts raw sockets, not distinct
# devices, so a lone spike (a client app's own reconnect/retry opening
# a few parallel sockets) is tracked as a "strike" and only acted on
# once the SAME account+reason is over limit on two CONSECUTIVE runs.
set -uo pipefail

INSTALL_DIR="/etc/vpn-script"
source "$INSTALL_DIR/menu/lib-ssh-users.sh"
source "$INSTALL_DIR/core/ssh-limits.sh"
source "$INSTALL_DIR/core/lock-reasons.sh"

ssh_limits_ensure_files

[[ -s "$SSH_LIMITS_JSON" ]] || exit 0
COUNT=$(jq 'length' "$SSH_LIMITS_JSON" 2>/dev/null || echo 0)
[[ "$COUNT" -gt 0 ]] || exit 0

STRIKES_FILE="$INSTALL_DIR/ssh-limits-strikes.json"
STRIKES="$(cat "$STRIKES_FILE" 2>/dev/null || echo '{}')"
jq empty <<< "$STRIKES" >/dev/null 2>&1 || STRIKES='{}'

ENGINE="$(cat "$INSTALL_DIR/ssh-engine" 2>/dev/null || echo both)"
DROPBEAR_MAP=""
[[ "$ENGINE" == "openssh" ]] || DROPBEAR_MAP="$(_dropbear_pid_user_map)"

# reason_code feeds menu/check-locked-users.sh so it can show a
# reason-appropriate recovery action instead of a generic unlock.
# strike_key is "<username>:<reason_code>" -- connection and bandwidth
# violations are debounced independently so one strike of each doesn't
# combine into a false two-strike trigger for either.
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

check_with_debounce() {
  local uname="$1" over_limit="$2" log_msg="$3" reason_code="$4"
  local key="${uname}:${reason_code}" prev_strikes strikes
  if [[ "$over_limit" == "true" ]]; then
    prev_strikes="$(jq -r --arg k "$key" '.[$k] // 0' <<< "$STRIKES")"
    strikes=$(( prev_strikes + 1 ))
    if (( strikes >= 2 )); then
      lock_if_unlocked "$uname" "$log_msg (${strikes} consecutive checks)" "$reason_code"
      STRIKES="$(jq --arg k "$key" 'del(.[$k])' <<< "$STRIKES")"
    else
      STRIKES="$(jq --arg k "$key" --argjson s "$strikes" '.[$k] = $s' <<< "$STRIKES")"
    fi
  else
    STRIKES="$(jq --arg k "$key" 'del(.[$k])' <<< "$STRIKES")"
  fi
}

# ---- connection limit ----
while IFS=$'\t' read -r uname limit; do
  [[ -z "$uname" ]] && continue
  count="$(ssh_user_login_count_cached "$uname" "$ENGINE" "$DROPBEAR_MAP")"
  if [[ "$count" -gt "$limit" ]]; then
    check_with_debounce "$uname" "true" "exceeded connection limit ($count/$limit)" "connection"
  else
    check_with_debounce "$uname" "false" "" "connection"
  fi
done < <(jq -r '.[] | select(.conn_limit > 0) | [.username, .conn_limit] | @tsv' "$SSH_LIMITS_JSON")

# ---- bandwidth limit: sample + accumulate ----
LIVE_PIDS="$(pgrep dropbear 2>/dev/null)"
if [[ -n "$LIVE_PIDS" ]]; then
  # Reuse the map already computed above -- no second journalctl scan.
  PID_USER_MAP="$DROPBEAR_MAP"

  if [[ -n "$PID_USER_MAP" ]]; then
    SAMPLES="$(cat "$SSH_BW_SAMPLES_JSON" 2>/dev/null || echo '{}')"
    NEW_SAMPLES="$SAMPLES"
    declare -A DELTAS=()

    while IFS=' ' read -r pid uname; do
      [[ -z "$pid" ]] && continue
      io_file="/proc/$pid/io"
      [[ -r "$io_file" ]] || continue

      now_bytes=$(awk '/^rchar:|^wchar:/{sum+=$2} END{print sum+0}' "$io_file")
      prev_bytes=$(jq -r --arg p "$pid" '.[$p] // 0' <<< "$SAMPLES")
      delta=$(( now_bytes - prev_bytes ))
      # negative delta means this PID number got reused since our last
      # sample (a brand-new process, not the one we were tracking) —
      # skip crediting/debiting anything this cycle rather than guess.
      (( delta < 0 )) && delta=0

      NEW_SAMPLES="$(jq --arg p "$pid" --argjson v "$now_bytes" '.[$p] = $v' <<< "$NEW_SAMPLES")"

      if [[ "$delta" -gt 0 ]]; then
        DELTAS["$uname"]=$(( ${DELTAS["$uname"]:-0} + delta ))
      fi
    done <<< "$PID_USER_MAP"

    # One jq pass applying every accumulated delta -- previously this was
    # one full read-modify-write of the whole ssh-limits.json array PER
    # live bandwidth-tracked connection, every 2 minutes.
    if [[ "${#DELTAS[@]}" -gt 0 ]]; then
      DELTAS_JSON="{}"
      for uname in "${!DELTAS[@]}"; do
        DELTAS_JSON="$(jq --arg u "$uname" --argjson d "${DELTAS[$uname]}" '.[$u] = $d' <<< "$DELTAS_JSON")"
      done
      tmp=$(mktemp)
      jq --argjson deltas "$DELTAS_JSON" '
        map(if (.username as $u | $deltas | has($u)) then .bw_used_bytes += $deltas[.username] else . end)
      ' "$SSH_LIMITS_JSON" > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$SSH_LIMITS_JSON"
    fi

    # Drop samples for PIDs no longer live, so this file doesn't grow forever.
    NEW_SAMPLES="$(jq --arg live "$LIVE_PIDS" '
      ($live | split("\n") | map(select(length > 0))) as $l
      | with_entries(select(.key as $k | $l | index($k)))
    ' <<< "$NEW_SAMPLES" 2>/dev/null)"
    [[ -n "$NEW_SAMPLES" ]] && echo "$NEW_SAMPLES" > "$SSH_BW_SAMPLES_JSON"
    chmod 600 "$SSH_BW_SAMPLES_JSON"
  fi
fi

# ---- bandwidth limit: check accumulated usage ----
while IFS=$'\t' read -r uname limit_mb used_bytes; do
  [[ -z "$uname" ]] && continue
  used_mb=$(( used_bytes / 1048576 ))
  if [[ "$used_mb" -gt "$limit_mb" ]]; then
    check_with_debounce "$uname" "true" "exceeded bandwidth limit (${used_mb}MB/${limit_mb}MB)" "bandwidth"
  else
    check_with_debounce "$uname" "false" "" "bandwidth"
  fi
done < <(jq -r '.[] | select(.bw_limit_mb > 0) | [.username, .bw_limit_mb, .bw_used_bytes] | @tsv' "$SSH_LIMITS_JSON")

echo "$STRIKES" > "$STRIKES_FILE"
chmod 600 "$STRIKES_FILE"

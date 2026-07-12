#!/bin/bash
# VPN-Starter-Kit :: core/bandwidth.sh
# Account-attributable bandwidth reporting: sums real per-account usage
# across SSH, Xray (VMess/VLESS/Trojan), and WireGuard, rather than
# interface-wide vnstat totals. vnstat counted ALL server traffic (SSH
# admin access, apt/package installs, background system chatter), so a
# fresh box with zero VPN accounts still showed dozens of MB "used"
# before any client had ever connected.
#
# Each account source's own counter (bw_ssh_bytes/bw_wireguard_bytes/
# bw_xray_bytes) is a running cumulative total, not bucketed by day. To
# still show Today/Yesterday/Month the way vnstat did, a daily cron
# snapshot (bandwidth-snapshot.sh) records the combined total once a day;
# bw_day_stats()/bw_month_bytes() diff against that history. Source this
# file for bw_ensure()/bw_day_stats()/bw_month_bytes()/_bw_human().

SSH_LIMITS_JSON="/etc/vpn-script/ssh-limits.json"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_API_SERVER="127.0.0.1:10085"
WG_IFACE="wg0"
BW_HISTORY_JSON="/etc/vpn-script/bandwidth-history.json"
BW_SNAPSHOT_CRON="/etc/cron.d/vpn-bandwidth-snapshot"

# Bytes -> "824.30MB" / "4.12GB" / "1.03TB" style. Byte units use a capital
# B (GB/MB/TB) — lowercase "b" conventionally means bits.
_bw_human() {
  local bytes="$1"
  [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
  awk -v b="$bytes" 'BEGIN {
    if (b >= 1099511627776) printf "%.2fTB", b/1099511627776
    else if (b >= 1073741824) printf "%.2fGB", b/1073741824
    else if (b >= 1048576) printf "%.2fMB", b/1048576
    else if (b >= 1024) printf "%.2fKB", b/1024
    else printf "%dB", b
  }'
}

# Sum of bw_used_bytes across every tracked SSH/SlowDNS account (0 if the
# file doesn't exist yet — nothing created, nothing tracked).
bw_ssh_bytes() {
  local v
  v="$(jq '[.[].bw_used_bytes] | add // 0' "$SSH_LIMITS_JSON" 2>/dev/null)"
  [[ "$v" =~ ^[0-9]+$ ]] && echo "$v" || echo 0
}

# Sum of rx+tx across every WireGuard peer, straight from the kernel via
# `wg show <iface> dump` — native counters, no extra instrumentation needed.
bw_wireguard_bytes() {
  local v
  command -v wg >/dev/null 2>&1 || { echo 0; return; }
  v="$(wg show "$WG_IFACE" dump 2>/dev/null | tail -n +2 | awk -F'\t' '{rx+=$6; tx+=$7} END{print (rx+tx)+0}')"
  [[ "$v" =~ ^[0-9]+$ ]] && echo "$v" || echo 0
}

# Sum of uplink+downlink across every VMess/VLESS/Trojan client via Xray's
# Stats API. Returns 0 (not an error) if the API isn't enabled yet — see
# install/migrate-xray-stats-api.sh.
bw_xray_bytes() {
  local v
  command -v xray >/dev/null 2>&1 || { echo 0; return; }
  jq -e '.api.services // [] | index("StatsService")' "$XRAY_CONFIG" >/dev/null 2>&1 || { echo 0; return; }
  v="$(xray api statsquery --server="$XRAY_API_SERVER" -pattern "user>>>" 2>/dev/null \
    | jq '[.stat[]?.value | tonumber] | add // 0' 2>/dev/null)"
  [[ "$v" =~ ^[0-9]+$ ]] && echo "$v" || echo 0
}

# Combined current total across all three sources (a running total, right now).
bw_current_total_bytes() {
  echo $(( $(bw_ssh_bytes) + $(bw_xray_bytes) + $(bw_wireguard_bytes) ))
}

# Idempotent: lazy-installs the daily snapshot cron the first time the
# dashboard loads. No separate "enable" toggle, same pattern as every
# other cron worker in this repo.
bw_ensure() {
  mkdir -p /etc/vpn-script
  [[ -f "$BW_HISTORY_JSON" ]] || { echo '[]' > "$BW_HISTORY_JSON"; chmod 600 "$BW_HISTORY_JSON"; }
  [[ -f "$BW_SNAPSHOT_CRON" ]] && return
  mkdir -p /var/log/vpn-script
  echo "59 23 * * * root /etc/vpn-script/core/bandwidth-snapshot.sh >> /var/log/vpn-script/bandwidth-snapshot.log 2>&1" \
    > "$BW_SNAPSHOT_CRON"
  chmod 644 "$BW_SNAPSHOT_CRON"
  systemctl restart cron >/dev/null 2>&1 || true
}

# "today_bytes yesterday_bytes", diffed against the daily history file.
# today = current total - total as of the end of the most recent day
# before today (0 if no history yet — first day since install/enable).
# yesterday = yesterday's end-of-day snapshot minus the day before that
# (0 if yesterday was never snapshotted, e.g. the box was off, or this
# is the 2nd day since install). Clamped at 0: a renewal resets that
# account's SSH bw_used_bytes to 0, and deleting an account drops its
# bytes out of the sum entirely, so the combined total can legitimately
# go down between snapshots -- a negative "used" figure would be
# nonsensical, so it reads as 0 instead.
bw_day_stats() {
  local today yesterday current today_baseline yesterday_total day_before_yesterday_baseline today_used yesterday_used
  today="$(date +%F)"
  yesterday="$(date -d yesterday +%F)"
  current="$(bw_current_total_bytes)"

  today_baseline="$(jq --arg d "$today" '
    ([.[] | select(.date < $d)] | max_by(.date) | .total_bytes) // 0
  ' "$BW_HISTORY_JSON" 2>/dev/null)"
  [[ "$today_baseline" =~ ^[0-9]+$ ]] || today_baseline=0

  yesterday_total="$(jq --arg d "$yesterday" '
    ([.[] | select(.date == $d)] | .[0].total_bytes) // 0
  ' "$BW_HISTORY_JSON" 2>/dev/null)"
  [[ "$yesterday_total" =~ ^[0-9]+$ ]] || yesterday_total=0

  day_before_yesterday_baseline="$(jq --arg d "$yesterday" '
    ([.[] | select(.date < $d)] | max_by(.date) | .total_bytes) // 0
  ' "$BW_HISTORY_JSON" 2>/dev/null)"
  [[ "$day_before_yesterday_baseline" =~ ^[0-9]+$ ]] || day_before_yesterday_baseline=0

  today_used=$(( current - today_baseline ))
  (( today_used < 0 )) && today_used=0
  yesterday_used=$(( yesterday_total - day_before_yesterday_baseline ))
  (( yesterday_used < 0 )) && yesterday_used=0

  echo "$today_used $yesterday_used"
}

# Total used so far this calendar month: current total minus the last
# snapshot from before the 1st of this month (0 if no prior-month history).
bw_month_bytes() {
  local month_start current month_baseline month_used
  month_start="$(date +%Y-%m-01)"
  current="$(bw_current_total_bytes)"

  month_baseline="$(jq --arg d "$month_start" '
    ([.[] | select(.date < $d)] | max_by(.date) | .total_bytes) // 0
  ' "$BW_HISTORY_JSON" 2>/dev/null)"
  [[ "$month_baseline" =~ ^[0-9]+$ ]] || month_baseline=0

  month_used=$(( current - month_baseline ))
  (( month_used < 0 )) && month_used=0
  echo "$month_used"
}

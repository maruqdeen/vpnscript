#!/bin/bash
# VPN-Starter-Kit :: core/bandwidth-snapshot.sh
# Cron worker installed/removed by core/bandwidth.sh's bw_ensure(). Runs
# once daily at 23:59; records today's combined account-bandwidth total
# (SSH + Xray + WireGuard) so bw_day_stats()/bw_month_bytes() can diff
# against it. Upserts today's entry (replaces it if the job somehow runs
# twice the same day) rather than appending duplicates, and keeps the
# history file bounded to the last 400 days.
set -uo pipefail

CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CORE_DIR/bandwidth.sh"

bw_ensure

TODAY="$(date +%F)"
TOTAL="$(bw_current_total_bytes)"

tmp=$(mktemp)
jq --arg d "$TODAY" --argjson t "$TOTAL" '
  ([.[] | select(.date != $d)] + [{date: $d, total_bytes: $t}])
  | sort_by(.date)
  | .[-400:]
' "$BW_HISTORY_JSON" > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$BW_HISTORY_JSON"

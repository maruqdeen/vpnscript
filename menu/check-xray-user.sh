#!/bin/bash
# VPN-Starter-Kit :: menu/check-xray-user.sh
# Shows every Xray user for a given protocol (vmess/vless/trojan) with a
# session count. Xray has no per-connection OS process to count (unlike
# SSH's Dropbear PIDs), and its WS/gRPC inbounds sit behind nginx on
# loopback, so the source IP in Xray's own access log is always
# 127.0.0.1 (nginx) — counting distinct client IPs, the SSH approach,
# doesn't work here. Instead this counts "accepted" access-log lines
# carrying that user's email tag within the last 60s (matches nginx's
# WS idle timeout): each open WS/gRPC stream logs its own accepted line,
# so this approximates concurrent sessions. Best-effort, not a verified
# distinct-device count.
# Usage: check-xray-user.sh <vmess|vless|trojan>
set -uo pipefail

CONFIG="/usr/local/etc/xray/config.json"
ACCESS_LOG="/var/log/vpn-script/xray-access.log"
WINDOW_SECONDS=60
PROTO="${1:-}"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."; exit 1
fi
case "$PROTO" in
  vmess|vless|trojan) ;;
  *) echo "Usage: check-xray-user.sh <vmess|vless|trojan>"; exit 1 ;;
esac

if [[ ! -f "$CONFIG" ]]; then
  echo "Error: Xray config not found at $CONFIG"
  exit 1
fi

# de-duped: vmess/vless/trojan each have a WS + gRPC inbound sharing the
# same client list, so without unique the same email is listed twice.
mapfile -t USERS < <(jq -r --arg p "$PROTO" '
  [.inbounds[] | select(.protocol==$p) | .settings.clients[].email] | unique[]
' "$CONFIG" 2>/dev/null)

clear
echo ""
printf '%s\n' "=================================================="
printf "%30s\n" "CHECK ACTIVE ${PROTO^^} USER"
printf '%s\n' "=================================================="
echo ""

if [[ ${#USERS[@]} -eq 0 ]]; then
  echo "  (no accounts yet)"
  echo ""
  printf '%s\n' "=================================================="
  exit 0
fi

printf "%-28s %s\n" "USERNAME" "SESSIONS"
echo ""

if [[ ! -f "$ACCESS_LOG" ]]; then
  for email in "${USERS[@]}"; do
    printf "%-28s %s\n" "${email%%_*}" "0"
  done
  echo ""
  echo "(access log not found at $ACCESS_LOG — counts unavailable)"
  printf '%s\n' "=================================================="
  exit 0
fi

# Xray's access log timestamps are "YYYY/MM/DD HH:MM:SS ..." — same
# ordering as a plain string, so a string cutoff compare is enough and
# avoids forking `date` per log line.
CUTOFF_STR="$(date -d "@$(( $(date +%s) - WINDOW_SECONDS ))" +"%Y/%m/%d %H:%M:%S")"

for email in "${USERS[@]}"; do
  uname="${email%%_*}"
  count=$(awk -v needle="email: ${email}" -v cutoff="$CUTOFF_STR" '
    index($0, needle) {
      ts = $1" "$2
      if (ts >= cutoff) n++
    }
    END { print n+0 }
  ' "$ACCESS_LOG")
  printf "%-28s %s\n" "$uname" "$count"
done

echo ""
printf '%s\n' "=================================================="

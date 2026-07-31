#!/bin/bash
# VPN-Starter-Kit :: menu/check-xray-user.sh
# Shows every Xray user for a given protocol (vmess/vless/trojan/
# shadowsocks) with a session count. Xray has no per-connection OS
# process to count (unlike SSH's Dropbear PIDs), and for inbounds that
# sit behind nginx on loopback the source IP in Xray's own access log
# is 127.0.0.1 (nginx), not the real client — counting distinct client
# IPs, the SSH approach, doesn't work uniformly here.
#
# Each line in the access log is one accepted OUTBOUND connection the
# proxied traffic makes, not one per device — a single phone actively
# using an app can log a dozen+ lines in a few seconds (one per image
# load, API call, etc. — confirmed against a real log sample), so a raw
# line count wildly overcounts. Instead this counts DISTINCT "from
# IP:PORT" values per user within the last 60s: every accepted
# connection sharing the same source (same loopback ephemeral port, or
# the same real IP for inbounds that see one) collapses to one entry.
# Still an approximation of concurrent connections, not a verified
# distinct-device count — same caveat menu/lib-ssh-users.sh documents
# for the SSH side (one client can legitimately hold open more than one
# connection at a time) — but far closer than the raw line count was.
# Usage: check-xray-user.sh <vmess|vless|trojan|shadowsocks>
set -uo pipefail

CONFIG="/usr/local/etc/xray/config.json"
ACCESS_LOG="/var/log/vpn-script/xray-access.log"
WINDOW_SECONDS=60
PROTO="${1:-}"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."; exit 1
fi
case "$PROTO" in
  vmess|vless|trojan|shadowsocks) ;;
  *) echo "Usage: check-xray-user.sh <vmess|vless|trojan|shadowsocks>"; exit 1 ;;
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
  # $4 is the "IP:PORT" Xray logged as the connection's source (e.g.
  # "127.0.0.1:59188" for nginx-proxied inbounds, or a real client IP
  # for inbounds that see one) -- deduping on it collapses every
  # accepted-connection line from the SAME underlying connection down
  # to one entry, instead of counting each one.
  count=$(awk -v needle="email: ${email}" -v cutoff="$CUTOFF_STR" '
    index($0, needle) {
      ts = $1" "$2
      if (ts >= cutoff) seen[$4] = 1
    }
    END {
      n = 0
      for (k in seen) n++
      print n
    }
  ' "$ACCESS_LOG")
  printf "%-28s %s\n" "$uname" "$count"
done

echo ""
printf '%s\n' "=================================================="

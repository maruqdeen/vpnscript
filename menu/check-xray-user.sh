#!/bin/bash
# VPN-Starter-Kit :: menu/check-xray-user.sh
# Shows every Xray user for a given protocol (vmess/vless/trojan) with
# whether they're actively transferring data right now. Xray has no
# "logged in" concept like SSH — active detection uses the Stats API,
# sampling each user's uplink+downlink counters twice a few seconds apart;
# a nonzero delta means bytes moved during the sample window. Best-effort,
# same class of approximation as the SSH bandwidth-limit /proc/io sampling.
# Usage: check-xray-user.sh <vmess|vless|trojan>
set -uo pipefail

CONFIG="/usr/local/etc/xray/config.json"
API_SERVER="127.0.0.1:10085"
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

if ! command -v xray >/dev/null 2>&1; then
  echo "Error: xray binary not found on PATH."
  exit 1
fi

if ! jq -e '.api.services // [] | index("StatsService")' "$CONFIG" >/dev/null 2>&1; then
  echo "Stats API is not enabled on this server yet."
  echo "Run this once, then try again:"
  echo "  wget -qO- https://raw.githubusercontent.com/maruqdeen/vpnscript/main/install/migrate-xray-stats-api.sh | sudo bash"
  exit 1
fi

mapfile -t USERS < <(jq -r --arg p "$PROTO" '
  .inbounds[] | select(.protocol==$p) | .settings.clients[].email
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

_stats_raw() {
  xray api statsquery --server="$API_SERVER" -pattern "user>>>" 2>/dev/null
}

RAW1="$(_stats_raw)"
if ! jq -e . >/dev/null 2>&1 <<< "$RAW1"; then
  echo "Could not query the Xray Stats API — is xray running?"
  echo "  systemctl status xray"
  exit 1
fi

echo "Sampling live traffic (takes a few seconds)..."
sleep 3
RAW2="$(_stats_raw)"

declare -A BEFORE AFTER
while read -r name value; do
  [[ -z "$name" ]] && continue
  BEFORE["$name"]="$value"
done < <(jq -r '.stat[]? | "\(.name) \(.value)"' <<< "$RAW1")
while read -r name value; do
  [[ -z "$name" ]] && continue
  AFTER["$name"]="$value"
done < <(jq -r '.stat[]? | "\(.name) \(.value)"' <<< "$RAW2")

echo ""
printf "%-28s %s\n" "USERNAME" "STATUS"
echo ""

ACTIVE_COUNT=0
for email in "${USERS[@]}"; do
  uname="${email%%_*}"
  up_key="user>>>${email}>>>traffic>>>uplink"
  down_key="user>>>${email}>>>traffic>>>downlink"
  up_before="${BEFORE[$up_key]:-0}"; up_after="${AFTER[$up_key]:-0}"
  down_before="${BEFORE[$down_key]:-0}"; down_after="${AFTER[$down_key]:-0}"
  [[ "$up_before" =~ ^[0-9]+$ ]] || up_before=0
  [[ "$up_after" =~ ^[0-9]+$ ]] || up_after=0
  [[ "$down_before" =~ ^[0-9]+$ ]] || down_before=0
  [[ "$down_after" =~ ^[0-9]+$ ]] || down_after=0
  delta=$(( (up_after - up_before) + (down_after - down_before) ))
  status="Inactive"
  if (( delta > 0 )); then
    status=$'\e[32mActive\e[0m'
    (( ACTIVE_COUNT++ ))
  fi
  printf "%-28s %s\n" "$uname" "$status"
done

echo ""
echo "Active now: ${ACTIVE_COUNT} / ${#USERS[@]}"
printf '%s\n' "=================================================="

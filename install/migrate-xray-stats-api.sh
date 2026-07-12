#!/bin/bash
# VPN-Starter-Kit :: install/migrate-xray-stats-api.sh
# One-time, idempotent fix for servers installed before Xray's Stats API
# was wired up. Adds the "api"/"stats"/"policy" blocks needed for
# per-account Xray bandwidth tracking (core/bandwidth.sh's bw_xray_bytes,
# feeding the dashboard's BANDWITH USAGE line) to query live per-user
# traffic counters. NON-DESTRUCTIVE: existing inbounds/clients are
# untouched. Backs up the live config first and automatically rolls back
# if Xray fails to restart with the new blocks, since this touches a
# server that's already in production use.
# Usage: wget -qO- https://raw.githubusercontent.com/maruqdeen/vpnscript/main/install/migrate-xray-stats-api.sh | sudo bash
set -uo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."; exit 1
fi

CONFIG="/usr/local/etc/xray/config.json"
[[ -f "$CONFIG" ]] || { echo "Xray config not found at $CONFIG"; exit 1; }

if jq -e '.api.services // [] | index("StatsService")' "$CONFIG" >/dev/null 2>&1; then
  echo "Stats API already enabled, nothing to do."
  exit 0
fi

BACKUP="${CONFIG}.bak-$(date +%s)"
cp "$CONFIG" "$BACKUP"

echo ">>> Adding Stats API (api/stats/policy) to Xray config..."
tmp=$(mktemp)
jq '
  .api = {"tag": "api", "listen": "127.0.0.1:10085", "services": ["HandlerService","LoggerService","StatsService"]} |
  .stats = {} |
  .policy = {
    "levels": {"0": {"statsUserUplink": true, "statsUserDownlink": true}},
    "system": {"statsInboundUplink": true, "statsInboundDownlink": true}
  }
' "$CONFIG" > "$tmp"

if ! jq empty "$tmp" >/dev/null 2>&1; then
  echo "ERROR: produced invalid JSON, aborting (live config untouched)."
  rm -f "$tmp"
  exit 1
fi

chmod 644 "$tmp"
mv "$tmp" "$CONFIG"

systemctl restart xray
sleep 2
if systemctl is-active --quiet xray; then
  echo "    xray is active — Stats API enabled. Backup kept at $BACKUP"
else
  echo "    WARNING: xray failed to start with the Stats API config — rolling back."
  cp "$BACKUP" "$CONFIG"
  chmod 644 "$CONFIG"
  systemctl restart xray
  sleep 1
  if systemctl is-active --quiet xray; then
    echo "    Rolled back successfully — xray is active again on the previous config."
  else
    echo "    WARNING: xray still isn't active even after rollback — check: journalctl -u xray -n 30 --no-pager"
  fi
  exit 1
fi

echo ""
echo "Done. Pull the latest menu scripts too if you haven't:"
echo "  wget -qO- https://raw.githubusercontent.com/maruqdeen/vpnscript/main/install/update.sh | sudo bash"

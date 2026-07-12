#!/bin/bash
# VPN-Starter-Kit :: core/clean-expired.sh
# Deletes accounts whose expiry date has passed, across all three account
# types this panel manages. Enabled by default (unlike the other Security
# Mgt toggles) -- an expired account otherwise just lingers forever.
# OpenSSH/Dropbear already refuse login past expiry via PAM, but the
# account itself sticks around until removed by hand; Xray and WireGuard
# have no OS-level expiry enforcement at all, so their accounts stay
# fully usable past their tagged expiry date until something deletes them.
# Usage: clean-expired.sh <enable|disable|run>
#   enable/disable install/remove the daily cron job.
#   run is what the cron job actually calls.
set -uo pipefail

if [[ $EUID -ne 0 ]]; then echo "Run as root."; exit 1; fi

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/etc/vpn-script"
FLAG="$INSTALL_DIR/clean-expired.enabled"
CRON_FILE="/etc/cron.d/vpn-clean-expired"
XRAY_CONFIG="/usr/local/etc/xray/config.json"

ACTION="${1:-}"
case "$ACTION" in
  enable|disable|run) ;;
  *) echo "Usage: clean-expired.sh <enable|disable|run>"; exit 1 ;;
esac

if [[ "$ACTION" == "disable" ]]; then
  rm -f "$CRON_FILE" "$FLAG"
  echo "Clean Expired Users DISABLED."
  exit 0
fi

if [[ "$ACTION" == "enable" ]]; then
  mkdir -p /var/log/vpn-script
  echo "30 0 * * * root /etc/vpn-script/core/clean-expired.sh run >> /var/log/vpn-script/clean-expired.log 2>&1" \
    > "$CRON_FILE"
  chmod 644 "$CRON_FILE"
  systemctl restart cron >/dev/null 2>&1 || true
  touch "$FLAG"
  echo "Clean Expired Users ENABLED (runs daily at 00:30)."
  exit 0
fi

# ---- ACTION == run: the actual sweep ----
source "$BASE/../menu/lib-ssh-users.sh"
source "$BASE/ssh-limits.sh"
source "$BASE/lock-reasons.sh"
source "$BASE/wireguard.sh"

NOW=$(date +%s)
echo "$(date '+%F %T') clean-expired: starting sweep"

# --- SSH / SlowDNS ---
while read -r u; do
  [[ -z "$u" ]] && continue
  exp="$(ssh_user_expiry "$u")"
  [[ "$exp" == "never" ]] && continue
  exp_epoch="$(date -d "$exp" +%s 2>/dev/null)" || continue
  [[ -z "$exp_epoch" ]] && continue
  if (( exp_epoch < NOW )); then
    echo "$(date '+%F %T') clean-expired: removing SSH user '$u' (expired $exp)"
    pkill -u "$u" 2>/dev/null || true
    userdel "$u" 2>/dev/null || true
    ssh_limits_remove "$u"
    lock_reason_clear "$u"
  fi
done < <(ssh_user_list)

# --- Xray (VMess/VLESS/Trojan) ---
if [[ -f "$XRAY_CONFIG" ]]; then
  XRAY_CHANGED=0
  for proto in vmess vless trojan; do
    mapfile -t emails < <(jq -r --arg p "$proto" '
      [.inbounds[] | select(.protocol==$p) | .settings.clients[].email] | unique[]
    ' "$XRAY_CONFIG" 2>/dev/null)
    for email in "${emails[@]}"; do
      [[ -z "$email" ]] && continue
      exp="${email#*_}"
      exp_epoch="$(date -d "$exp" +%s 2>/dev/null)" || continue
      [[ -z "$exp_epoch" ]] && continue
      if (( exp_epoch < NOW )); then
        echo "$(date '+%F %T') clean-expired: removing $proto user '${email%%_*}' (expired $exp)"
        tmp=$(mktemp)
        jq --arg p "$proto" --arg email "$email" '
          (.inbounds[] | select(.protocol==$p) | .settings.clients)
            |= map(select(.email != $email))
        ' "$XRAY_CONFIG" > "$tmp" && chmod 644 "$tmp" && mv "$tmp" "$XRAY_CONFIG"
        XRAY_CHANGED=1
      fi
    done
  done
  [[ "$XRAY_CHANGED" -eq 1 ]] && systemctl restart xray
fi

# --- WireGuard ---
if [[ -f "$WG_CLIENTS_JSON" ]]; then
  WG_CHANGED=0
  while IFS=$'\t' read -r wuname wexp; do
    [[ -z "$wuname" ]] && continue
    exp_epoch="$(date -d "$wexp" +%s 2>/dev/null)" || continue
    [[ -z "$exp_epoch" ]] && continue
    if (( exp_epoch < NOW )); then
      echo "$(date '+%F %T') clean-expired: removing WireGuard peer '$wuname' (expired $wexp)"
      tmp=$(mktemp)
      jq --arg n "$wuname" 'map(select(.username != $n))' "$WG_CLIENTS_JSON" > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$WG_CLIENTS_JSON"
      WG_CHANGED=1
    fi
  done < <(jq -r '.[] | [.username, .expiry] | @tsv' "$WG_CLIENTS_JSON" 2>/dev/null)
  [[ "$WG_CHANGED" -eq 1 ]] && wg_sync_peers
fi

echo "$(date '+%F %T') clean-expired: sweep complete"

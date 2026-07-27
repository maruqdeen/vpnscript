#!/bin/bash
# VPN-Starter-Kit :: core/ssh-panel-actions.sh
# Non-interactive SSH actions needed ONLY by the web admin panel
# (core/admin-panel.py) -- login counts, locked-user management, and
# Autokill setup were never exposed to the Telegram bots, so unlike
# core/telegram-ssh-actions.sh (which has to preserve a legacy text-mode
# path), everything here is JSON-only from day one, always.
# Logic mirrors menu/check-login.sh, menu/check-locked-users.sh, and
# menu/autokill-setup.sh's underlying behavior exactly -- just
# non-interactive and machine-readable instead of read -rp/printf.
# Usage:
#   ssh-panel-actions.sh login-counts
#   ssh-panel-actions.sh locked-list
#   ssh-panel-actions.sh unlock-bandwidth <username> <extend_gb>
#   ssh-panel-actions.sh unlock-connlimit <username> <new_limit>
#   ssh-panel-actions.sh unlock-plain <username>
#   ssh-panel-actions.sh autokill-status
#   ssh-panel-actions.sh autokill-enable <limit>
#   ssh-panel-actions.sh autokill-disable
set -uo pipefail

if [[ $EUID -ne 0 ]]; then
  jq -n '{ok:false, error:"not_root", message:"Run as root."}'
  exit 1
fi

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$BASE_DIR/ssh-limits.sh"
source "$BASE_DIR/lock-reasons.sh"
source "$BASE_DIR/../menu/lib-ssh-users.sh"

STATE_DIR="/etc/vpn-script"
AUTOKILL_FLAG="$STATE_DIR/autokill.enabled"
AUTOKILL_LIMIT_FILE="$STATE_DIR/autokill.limit"
AUTOKILL_CRON="/etc/cron.d/vpn-autokill"
AUTOKILL_CHECK_SCRIPT="$STATE_DIR/menu/autokill-check.sh"

reason_label() {
  case "$1" in
    multilogin) echo "Multi login" ;;
    bandwidth)  echo "Bandwith Exceeded" ;;
    connection) echo "Conn Limit Exceeded" ;;
    *)          echo "Locked" ;;
  esac
}

err() {
  jq -n --arg code "$1" --arg msg "$2" '{ok:false, error:$code, message:$msg}'
}

ACTION="${1:-}"
[[ $# -gt 0 ]] && shift

case "$ACTION" in
  login-counts)
    {
      while read -r u; do
        [[ -z "$u" ]] && continue
        printf '%s\t%s\n' "$u" "$(ssh_user_login_count "$u")"
      done < <(ssh_user_list)
    } | jq -R -s -c '
      (split("\n") | map(select(length > 0))) as $lines |
      {ok:true, users: [$lines[] | split("\t") | {username: .[0], logins: (.[1] | tonumber)}]}
    '
    ;;

  locked-list)
    {
      while read -r u; do
        [[ -z "$u" ]] && continue
        pstate="$(passwd -S "$u" 2>/dev/null | awk '{print $2}')"
        [[ "$pstate" != "L" ]] && continue
        reason="$(lock_reason_get "$u")"
        printf '%s\t%s\t%s\n' "$u" "$reason" "$(reason_label "$reason")"
      done < <(ssh_user_list)
    } | jq -R -s -c '
      (split("\n") | map(select(length > 0))) as $lines |
      {ok:true, users: [$lines[] | split("\t") | {username: .[0], reason: .[1], reason_label: .[2]}]}
    '
    ;;

  unlock-bandwidth)
    USERNAME="${1:-}"; GB="${2:-}"
    if [[ -z "$USERNAME" || -z "$GB" ]]; then err "bad_request" "Usage: unlock-bandwidth <username> <gb>"; exit 1; fi
    if ! id "$USERNAME" >/dev/null 2>&1; then err "not_found" "No such user."; exit 1; fi
    if ! [[ "$GB" =~ ^[0-9]+$ ]]; then err "bad_request" "GB must be a number."; exit 1; fi
    tmp=$(mktemp)
    jq --arg u "$USERNAME" --argjson add "$(( GB * 1024 ))" '
      map(if .username == $u then .bw_limit_mb += $add else . end)
    ' "$SSH_LIMITS_JSON" > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$SSH_LIMITS_JSON"
    passwd -u "$USERNAME" >/dev/null 2>&1 || true
    lock_reason_clear "$USERNAME"
    jq -n --arg u "$USERNAME" --arg gb "$GB" '{ok:true, username:$u, message:("Unlocked, bandwidth limit increased by " + $gb + "GB")}'
    ;;

  unlock-connlimit)
    USERNAME="${1:-}"; NEWLIM="${2:-}"
    if [[ -z "$USERNAME" || -z "$NEWLIM" ]]; then err "bad_request" "Usage: unlock-connlimit <username> <new_limit>"; exit 1; fi
    if ! id "$USERNAME" >/dev/null 2>&1; then err "not_found" "No such user."; exit 1; fi
    if ! [[ "$NEWLIM" =~ ^[0-9]+$ ]]; then err "bad_request" "Limit must be a number."; exit 1; fi
    tmp=$(mktemp)
    jq --arg u "$USERNAME" --argjson lim "$NEWLIM" '
      map(if .username == $u then .conn_limit = $lim else . end)
    ' "$SSH_LIMITS_JSON" > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$SSH_LIMITS_JSON"
    passwd -u "$USERNAME" >/dev/null 2>&1 || true
    lock_reason_clear "$USERNAME"
    jq -n --arg u "$USERNAME" --arg lim "$NEWLIM" '{ok:true, username:$u, message:("Unlocked, connection limit set to " + $lim)}'
    ;;

  unlock-plain)
    USERNAME="${1:-}"
    if [[ -z "$USERNAME" ]]; then err "bad_request" "Usage: unlock-plain <username>"; exit 1; fi
    if ! id "$USERNAME" >/dev/null 2>&1; then err "not_found" "No such user."; exit 1; fi
    passwd -u "$USERNAME" >/dev/null 2>&1 || true
    lock_reason_clear "$USERNAME"
    jq -n --arg u "$USERNAME" '{ok:true, username:$u, message:"Unlocked"}'
    ;;

  autokill-status)
    if [[ -f "$AUTOKILL_FLAG" ]]; then
      limit="$(cat "$AUTOKILL_LIMIT_FILE" 2>/dev/null || echo 1)"
      jq -n --argjson limit "$limit" '{ok:true, enabled:true, limit:$limit}'
    else
      jq -n '{ok:true, enabled:false, limit:null}'
    fi
    ;;

  autokill-enable)
    LIMIT="${1:-2}"
    if ! [[ "$LIMIT" =~ ^[0-9]+$ ]] || [[ "$LIMIT" -lt 1 ]]; then LIMIT=2; fi
    mkdir -p "$STATE_DIR" /var/log/vpn-script
    echo "$LIMIT" > "$AUTOKILL_LIMIT_FILE"
    touch "$AUTOKILL_FLAG"
    cat > "$AUTOKILL_CRON" <<EOF
*/2 * * * * root $AUTOKILL_CHECK_SCRIPT >> /var/log/vpn-script/autokill.log 2>&1
EOF
    chmod 644 "$AUTOKILL_CRON"
    systemctl restart cron >/dev/null 2>&1 || true
    jq -n --argjson limit "$LIMIT" '{ok:true, enabled:true, limit:$limit}'
    ;;

  autokill-disable)
    rm -f "$AUTOKILL_FLAG" "$AUTOKILL_CRON"
    systemctl restart cron >/dev/null 2>&1 || true
    jq -n '{ok:true, enabled:false, limit:null}'
    ;;

  *)
    err "bad_request" "Usage: ssh-panel-actions.sh <login-counts|locked-list|unlock-bandwidth|unlock-connlimit|unlock-plain|autokill-status|autokill-enable|autokill-disable> ..."
    exit 1
    ;;
esac

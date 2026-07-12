#!/bin/bash
# VPN-Starter-Kit :: core/ssh-limits.sh
# Per-account connection + bandwidth limits for SSH/SlowDNS tunnel users.
# Source this file for the shared helpers below; core/ssh-limits-check.sh
# is the cron worker that actually enforces them.
#
# clients.json-style store, same pattern as WireGuard's clients.json:
#   [{"username":"joval","conn_limit":0,"bw_limit_mb":0,"bw_used_bytes":0}]
# conn_limit/bw_limit_mb: 0 means unlimited (matches "blank = unlimited"
# at creation time). bw_used_bytes is a running cumulative total since
# creation/last renewal — NOT a monthly-resetting cap, mirroring how
# conn_limit itself has no reset concept either.
SSH_LIMITS_JSON="/etc/vpn-script/ssh-limits.json"
SSH_BW_SAMPLES_JSON="/etc/vpn-script/ssh-bw-samples.json"
SSH_LIMITS_CRON="/etc/cron.d/vpn-ssh-limits"

ssh_limits_ensure_files() {
  mkdir -p /etc/vpn-script
  [[ -f "$SSH_LIMITS_JSON" ]] || { echo '[]' > "$SSH_LIMITS_JSON"; chmod 600 "$SSH_LIMITS_JSON"; }
  [[ -f "$SSH_BW_SAMPLES_JSON" ]] || { echo '{}' > "$SSH_BW_SAMPLES_JSON"; chmod 600 "$SSH_BW_SAMPLES_JSON"; }
}

# Idempotent: installs the enforcement cron job the first time any account
# gets a limit. No separate "enable" toggle (unlike autokill-multilogin) —
# per-account limits are meant to just work once assigned at creation.
ssh_limits_ensure_cron() {
  [[ -f "$SSH_LIMITS_CRON" ]] && return
  mkdir -p /var/log/vpn-script
  echo "*/2 * * * * root /etc/vpn-script/core/ssh-limits-check.sh >> /var/log/vpn-script/ssh-limits.log 2>&1" \
    > "$SSH_LIMITS_CRON"
  chmod 644 "$SSH_LIMITS_CRON"
  systemctl restart cron >/dev/null 2>&1 || true
}

# Record a new account's limits. Call right after creating the account.
ssh_limits_set() {
  local username="$1" conn_limit="${2:-0}" bw_limit_mb="${3:-0}"
  ssh_limits_ensure_files
  [[ "$conn_limit" =~ ^[0-9]+$ ]] || conn_limit=0
  [[ "$bw_limit_mb" =~ ^[0-9]+$ ]] || bw_limit_mb=0
  local tmp; tmp=$(mktemp)
  jq --arg u "$username" --argjson cl "$conn_limit" --argjson bl "$bw_limit_mb" '
    map(select(.username != $u)) + [{username:$u, conn_limit:$cl, bw_limit_mb:$bl, bw_used_bytes:0}]
  ' "$SSH_LIMITS_JSON" > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$SSH_LIMITS_JSON"
  ssh_limits_ensure_cron
}

# Drop a user's limit entry. Call on account deletion.
ssh_limits_remove() {
  local username="$1"
  [[ -f "$SSH_LIMITS_JSON" ]] || return 0
  local tmp; tmp=$(mktemp)
  jq --arg u "$username" 'map(select(.username != $u))' "$SSH_LIMITS_JSON" > "$tmp" \
    && chmod 600 "$tmp" && mv "$tmp" "$SSH_LIMITS_JSON"
}

# Reset a user's accumulated bandwidth usage and unlock them if they'd
# been locked for exceeding a limit — call on renewal, treating it like a
# fresh cycle. No-op (harmless) if the user has no limits entry at all.
ssh_limits_reset_usage() {
  local username="$1"
  if [[ -f "$SSH_LIMITS_JSON" ]] && jq -e --arg u "$username" '.[] | select(.username==$u)' "$SSH_LIMITS_JSON" >/dev/null 2>&1; then
    local tmp; tmp=$(mktemp)
    jq --arg u "$username" '
      map(if .username == $u then .bw_used_bytes = 0 else . end)
    ' "$SSH_LIMITS_JSON" > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$SSH_LIMITS_JSON"
  fi
  passwd -u "$username" >/dev/null 2>&1 || true
}

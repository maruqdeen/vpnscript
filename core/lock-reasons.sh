#!/bin/bash
# VPN-Starter-Kit :: core/lock-reasons.sh
# Tracks WHY an SSH/SlowDNS account was administratively locked
# (passwd -l), so menu/check-locked-users.sh can show a reason-appropriate
# recovery action instead of a generic one. Source this file; it is not
# meant to be executed directly.
LOCK_REASONS_JSON="/etc/vpn-script/lock-reasons.json"

lock_reasons_ensure_file() {
  mkdir -p /etc/vpn-script
  [[ -f "$LOCK_REASONS_JSON" ]] || { echo '{}' > "$LOCK_REASONS_JSON"; chmod 600 "$LOCK_REASONS_JSON"; }
}

# reason: "multilogin" | "bandwidth" | "connection"
lock_reason_set() {
  local username="$1" reason="$2"
  lock_reasons_ensure_file
  local tmp; tmp=$(mktemp)
  jq --arg u "$username" --arg r "$reason" '.[$u] = $r' "$LOCK_REASONS_JSON" > "$tmp" \
    && chmod 600 "$tmp" && mv "$tmp" "$LOCK_REASONS_JSON"
}

# Prints the reason, or an empty string if none recorded.
lock_reason_get() {
  local username="$1"
  [[ -f "$LOCK_REASONS_JSON" ]] || { echo ""; return; }
  jq -r --arg u "$username" '.[$u] // ""' "$LOCK_REASONS_JSON" 2>/dev/null
}

# Call whenever a user is unlocked or deleted, so a stale reason doesn't
# linger for the next time they get locked for a different cause.
lock_reason_clear() {
  local username="$1"
  [[ -f "$LOCK_REASONS_JSON" ]] || return 0
  local tmp; tmp=$(mktemp)
  jq --arg u "$username" 'del(.[$u])' "$LOCK_REASONS_JSON" > "$tmp" \
    && chmod 600 "$tmp" && mv "$tmp" "$LOCK_REASONS_JSON"
}

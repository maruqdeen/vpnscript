#!/bin/bash
# VPN-Starter-Kit :: core/ssh-passwords.sh
# Plaintext-password store for SSH/SlowDNS accounts, so "Generate Config"
# can redisplay a previously-created account's card later. Linux only
# keeps a password hash (chpasswd) — without this the plaintext is gone
# the moment the creation card scrolls off screen. Same pattern as
# ssh-limits.json: root-only 600 JSON, one entry per username.
SSH_PASSWORDS_JSON="/etc/vpn-script/ssh-passwords.json"

ssh_passwords_ensure_file() {
  mkdir -p /etc/vpn-script
  [[ -f "$SSH_PASSWORDS_JSON" ]] || { echo '{}' > "$SSH_PASSWORDS_JSON"; chmod 600 "$SSH_PASSWORDS_JSON"; }
}

# Record/replace a user's password. Call right after creating the account.
ssh_password_set() {
  local username="$1" password="$2"
  ssh_passwords_ensure_file
  local tmp; tmp=$(mktemp)
  jq --arg u "$username" --arg p "$password" '.[$u] = $p' \
    "$SSH_PASSWORDS_JSON" > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$SSH_PASSWORDS_JSON"
}

# Drop a user's stored password. Call on account deletion.
ssh_password_remove() {
  local username="$1"
  [[ -f "$SSH_PASSWORDS_JSON" ]] || return 0
  local tmp; tmp=$(mktemp)
  jq --arg u "$username" 'del(.[$u])' \
    "$SSH_PASSWORDS_JSON" > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$SSH_PASSWORDS_JSON"
}

# Prints the stored password for a user, or nothing if none recorded
# (accounts created before this feature existed).
ssh_password_get() {
  local username="$1"
  [[ -f "$SSH_PASSWORDS_JSON" ]] || return 0
  jq -r --arg u "$username" '.[$u] // empty' "$SSH_PASSWORDS_JSON" 2>/dev/null
}

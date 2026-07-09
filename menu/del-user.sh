#!/bin/bash
# VPN-Starter-Kit :: menu/del-user.sh
# Delete a user — either an Xray client (jq) or an SSH/SlowDNS account (userdel).
# Usage: del-user.sh [ssh|vless|vmess]   (omit the arg to be prompted for a type)
set -uo pipefail

CONFIG="/usr/local/etc/xray/config.json"
BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TYPE_ARG="${1:-}"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."; exit 1
fi

source "$BASE/lib-ssh-users.sh"

delete_xray() {
  local proto="$1"

  # list current users on this protocol (strip the _date suffix for display)
  echo ""
  echo "Current $proto users:"
  mapfile -t USERS < <(jq -r --arg p "$proto" '
    .inbounds[] | select(.protocol==$p) | .settings.clients[].email
  ' "$CONFIG" 2>/dev/null)

  if [[ ${#USERS[@]} -eq 0 ]]; then
    echo "  (none)"; return 1
  fi
  for u in "${USERS[@]}"; do echo "  - ${u%%_*}   (tag: $u)"; done

  echo ""
  read -rp "Enter username to delete: " NAME

  # find the exact email tag whose prefix matches
  local match=""
  for u in "${USERS[@]}"; do
    if [[ "${u%%_*}" == "$NAME" ]]; then match="$u"; break; fi
  done
  if [[ -z "$match" ]]; then
    echo "No $proto user named '$NAME'."; return 1
  fi

  tmp=$(mktemp)
  jq --arg p "$proto" --arg email "$match" '
    (.inbounds[] | select(.protocol==$p) | .settings.clients)
      |= map(select(.email != $email))
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"

  systemctl restart xray
  echo "Deleted $proto user '$NAME'."
}

delete_ssh() {
  echo ""
  print_ssh_table
  echo ""
  read -rp "Enter username to delete: " NAME

  if [[ -z "$NAME" ]]; then echo "Empty username."; return 1; fi
  if ! id "$NAME" >/dev/null 2>&1; then
    echo "No system user named '$NAME'."; return 1
  fi

  # safety rail: never delete a system/service account
  local uid; uid=$(id -u "$NAME")
  if [[ "$uid" -lt 1000 ]]; then
    echo "Refusing to delete system account '$NAME' (UID $uid < 1000)."; return 1
  fi

  # kill any live sessions, then remove the account
  pkill -u "$NAME" 2>/dev/null || true
  userdel "$NAME"
  echo "Deleted SSH/SlowDNS user '$NAME'."
}

case "$TYPE_ARG" in
  vless) delete_xray vless ;;
  vmess) delete_xray vmess ;;
  ssh)   delete_ssh ;;
  "")
    echo "What type of user do you want to delete?"
    echo "  [1] Xray VLESS"
    echo "  [2] Xray VMess"
    echo "  [3] SSH / SlowDNS"
    read -rp "Choose: " TYPE
    case "$TYPE" in
      1) delete_xray vless ;;
      2) delete_xray vmess ;;
      3) delete_ssh ;;
      *) echo "Invalid choice." ;;
    esac
    ;;
  *) echo "Usage: del-user.sh [ssh|vless|vmess]"; exit 1 ;;
esac
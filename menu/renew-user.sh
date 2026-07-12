#!/bin/bash
# VPN-Starter-Kit :: menu/renew-user.sh
# Extend a user's expiry — Xray (rewrite _date tag) or SSH/SlowDNS (chage -e).
# Usage: renew-user.sh [ssh|vless|vmess]   (omit the arg to be prompted for a type)
set -uo pipefail

CONFIG="/usr/local/etc/xray/config.json"
BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TYPE_ARG="${1:-}"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."; exit 1
fi

source "$BASE/lib-ssh-users.sh"
source "$BASE/../core/ssh-limits.sh"

renew_xray() {
  local proto="$1"

  echo ""
  echo "Current $proto users:"
  mapfile -t USERS < <(jq -r --arg p "$proto" '
    .inbounds[] | select(.protocol==$p) | .settings.clients[].email
  ' "$CONFIG" 2>/dev/null)

  if [[ ${#USERS[@]} -eq 0 ]]; then
    echo "  (none)"; return 1
  fi
  for u in "${USERS[@]}"; do echo "  - ${u%%_*}   (expires ${u#*_})"; done

  echo ""
  read -rp "Enter username to renew : " NAME
  read -rp "Add how many days        : " DAYS

  if ! [[ "$DAYS" =~ ^[0-9]+$ ]]; then echo "Days must be a number."; return 1; fi

  # find current tag by name prefix
  local old=""
  for u in "${USERS[@]}"; do
    if [[ "${u%%_*}" == "$NAME" ]]; then old="$u"; break; fi
  done
  if [[ -z "$old" ]]; then echo "No $proto user named '$NAME'."; return 1; fi

  # extend from today (handles already-expired users cleanly)
  local new_exp new_tag
  new_exp=$(date -d "+${DAYS} days" +%Y-%m-%d)
  new_tag="${NAME}_${new_exp}"

  tmp=$(mktemp)
  jq --arg p "$proto" --arg old "$old" --arg new "$new_tag" '
    (.inbounds[] | select(.protocol==$p) | .settings.clients[]
     | select(.email==$old) | .email) = $new
  ' "$CONFIG" > "$tmp" && chmod 644 "$tmp" && mv "$tmp" "$CONFIG"

  systemctl restart xray
  echo "Renewed $proto user '$NAME' -> expires $new_exp."
}

renew_ssh() {
  echo ""
  print_ssh_table
  echo ""
  read -rp "Enter username to renew : " NAME
  read -rp "Add how many days        : " DAYS

  if [[ -z "$NAME" ]]; then echo "Empty username."; return 1; fi
  if ! id "$NAME" >/dev/null 2>&1; then echo "No system user '$NAME'."; return 1; fi
  if ! [[ "$DAYS" =~ ^[0-9]+$ ]]; then echo "Days must be a number."; return 1; fi

  local uid; uid=$(id -u "$NAME")
  if [[ "$uid" -lt 1000 ]]; then
    echo "Refusing to touch system account '$NAME' (UID $uid)."; return 1
  fi

  local new_exp
  new_exp=$(date -d "+${DAYS} days" +%Y-%m-%d)
  chage -E "$new_exp" "$NAME"
  # Renewal = fresh cycle: clears any lock from an exceeded connection/
  # bandwidth limit and zeroes their accumulated usage. No-op if this
  # user never had a limit set.
  ssh_limits_reset_usage "$NAME"
  echo "Renewed SSH/SlowDNS user '$NAME' -> expires $new_exp."
}

case "$TYPE_ARG" in
  vless)  renew_xray vless ;;
  vmess)  renew_xray vmess ;;
  trojan) renew_xray trojan ;;
  ssh)    renew_ssh ;;
  "")
    echo "What type of user do you want to renew?"
    echo "  [1] Xray VLESS"
    echo "  [2] Xray VMess"
    echo "  [3] Xray Trojan"
    echo "  [4] SSH / SlowDNS"
    read -rp "Choose: " TYPE
    case "$TYPE" in
      1) renew_xray vless ;;
      2) renew_xray vmess ;;
      3) renew_xray trojan ;;
      4) renew_ssh ;;
      *) echo "Invalid choice." ;;
    esac
    ;;
  *) echo "Usage: renew-user.sh [ssh|vless|vmess|trojan]"; exit 1 ;;
esac
#!/bin/bash
# VPN-Starter-Kit :: core/telegram-wireguard-actions.sh
# Non-interactive WireGuard peer actions for the Telegram User Bot and
# the web admin panel to shell out to. `create` mirrors add-wireguard-
# user.sh's actual keygen/clients.json/sync logic, `delete`/`renew`
# mirror del-wireguard-user.sh/renew-wireguard-user.sh -- all take plain
# CLI args instead of `read -rp` prompts, and print plain text (no ANSI
# QR -- neither a Telegram message nor an admin-panel <pre> block is a
# terminal; QR-image delivery via sendPhoto would be a reasonable
# Telegram-specific follow-up).
# Usage:
#   telegram-wireguard-actions.sh create <username> <days>
#   telegram-wireguard-actions.sh list
#   telegram-wireguard-actions.sh delete <username>
#   telegram-wireguard-actions.sh renew <username> <days>
set -uo pipefail

if [[ $EUID -ne 0 ]]; then echo "Run as root."; exit 1; fi

CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CORE_DIR/wireguard.sh"

DOMAIN_FILE="/etc/vpn-script/domain"

ACTION="${1:-}"
[[ $# -gt 0 ]] && shift

case "$ACTION" in
  create)
    USERNAME="${1:-}"; DAYS="${2:-}"
    if [[ -z "$USERNAME" || -z "$DAYS" ]]; then
      echo "Usage: create <username> <days>"; exit 1
    fi
    if ! [[ "$USERNAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
      echo "Invalid username. Use letters, digits, - and _ only."; exit 1
    fi
    if ! [[ "$DAYS" =~ ^[0-9]+$ ]]; then echo "Expiry must be a number of days."; exit 1; fi

    wg_ensure_server

    if jq -e --arg n "$USERNAME" '.[] | select(.username==$n)' "$WG_CLIENTS_JSON" >/dev/null 2>&1; then
      echo "Error: user '$USERNAME' already exists."; exit 1
    fi

    IP="$(wg_next_ip)"
    if [[ -z "$IP" ]]; then
      echo "Subnet full (253 peers max) -- delete an old peer first."; exit 1
    fi

    PRIV="$(wg genkey)"
    PUB="$(echo "$PRIV" | wg pubkey)"
    PSK="$(wg genpsk)"
    EXPIRY=$(date -d "+${DAYS} days" +%Y-%m-%d)
    SERVER_PUB="$(cat "$WG_SERVER_PUB_FILE")"

    HOSTNAME_VAL="$(cat "$DOMAIN_FILE" 2>/dev/null)"
    [[ -z "$HOSTNAME_VAL" ]] && HOSTNAME_VAL="$(curl -s https://api.ipify.org || hostname -I | awk '{print $1}')"

    tmp=$(mktemp)
    jq --arg u "$USERNAME" --arg e "$EXPIRY" --arg addr "$IP" \
       --arg priv "$PRIV" --arg pub "$PUB" --arg psk "$PSK" \
      '. += [{username:$u, expiry:$e, address:$addr, private_key:$priv, public_key:$pub, preshared_key:$psk}]' \
      "$WG_CLIENTS_JSON" > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$WG_CLIENTS_JSON"

    wg_sync_peers

    cat <<MSG
====================================
   Wireguard Account
====================================
Remarks       : ${USERNAME}
Address       : ${IP}/24
Endpoint      : ${HOSTNAME_VAL}:${WG_PORT}
Expired On    : ${EXPIRY}
====================================
[Interface]
PrivateKey = ${PRIV}
Address = ${IP}/24
DNS = 1.1.1.1, 1.0.0.1

[Peer]
PublicKey = ${SERVER_PUB}
PresharedKey = ${PSK}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = ${HOSTNAME_VAL}:${WG_PORT}
PersistentKeepalive = 25
====================================
MSG
    ;;

  list)
    wg_ensure_server
    if [[ "${PANEL_JSON:-0}" == "1" ]]; then
      jq -c '{ok:true, users: [.[] | {username, expiry, address}]}' "$WG_CLIENTS_JSON" 2>/dev/null \
        || echo '{"ok":true,"users":[]}'
      exit 0
    fi
    COUNT=$(jq 'length' "$WG_CLIENTS_JSON" 2>/dev/null || echo 0)
    if [[ "$COUNT" -eq 0 ]]; then
      echo "(no WireGuard accounts)"
      exit 0
    fi
    echo "WireGuard accounts:"
    jq -r '.[] | "- " + .username + "  (expires " + .expiry + ", " + .address + "/32)"' "$WG_CLIENTS_JSON"
    ;;

  delete)
    USERNAME="${1:-}"
    if [[ -z "$USERNAME" ]]; then echo "Usage: delete <username>"; exit 1; fi
    wg_ensure_server
    if ! jq -e --arg n "$USERNAME" '.[] | select(.username==$n)' "$WG_CLIENTS_JSON" >/dev/null 2>&1; then
      echo "No WireGuard peer named '$USERNAME'."; exit 1
    fi
    tmp=$(mktemp)
    jq --arg n "$USERNAME" 'map(select(.username != $n))' "$WG_CLIENTS_JSON" > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$WG_CLIENTS_JSON"
    wg_sync_peers
    echo "Deleted WireGuard peer '${USERNAME}'."
    ;;

  renew)
    USERNAME="${1:-}"; DAYS="${2:-}"
    if [[ -z "$USERNAME" || -z "$DAYS" ]]; then echo "Usage: renew <username> <days>"; exit 1; fi
    if ! [[ "$DAYS" =~ ^[0-9]+$ ]]; then echo "Days must be a number."; exit 1; fi
    wg_ensure_server
    if ! jq -e --arg n "$USERNAME" '.[] | select(.username==$n)' "$WG_CLIENTS_JSON" >/dev/null 2>&1; then
      echo "No WireGuard peer named '$USERNAME'."; exit 1
    fi
    # Expiry is a tracked date only (WireGuard has no native expiry
    # enforcement) -- no wg_sync_peers needed, unlike create/delete which
    # change the actual live peer set.
    NEW_EXP=$(date -d "+${DAYS} days" +%Y-%m-%d)
    tmp=$(mktemp)
    jq --arg n "$USERNAME" --arg e "$NEW_EXP" \
      '(.[] | select(.username==$n) | .expiry) = $e' \
      "$WG_CLIENTS_JSON" > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$WG_CLIENTS_JSON"
    echo "Renewed WireGuard peer '${USERNAME}' -> expires ${NEW_EXP}."
    ;;

  *)
    echo "Usage: telegram-wireguard-actions.sh <create|list|delete|renew> ..."
    exit 1
    ;;
esac

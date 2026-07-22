#!/bin/bash
# VPN-Starter-Kit :: core/telegram-ssh-actions.sh
# Non-interactive SSH account actions for the Telegram bot
# (core/telegram-bot.py) to shell out to. Mirrors add-ssh-user.sh /
# del-user.sh / renew-user.sh's underlying logic, but takes plain CLI
# args instead of `read -rp` prompts, and prints plain text suitable for
# relaying back as a Telegram message rather than an ANSI-colored card.
# Usage:
#   telegram-ssh-actions.sh create <username> <password> <days> [conn_limit] [bw_limit_gb]
#   telegram-ssh-actions.sh list
#   telegram-ssh-actions.sh delete <username>
#   telegram-ssh-actions.sh renew <username> <days>
set -uo pipefail

if [[ $EUID -ne 0 ]]; then echo "Run as root."; exit 1; fi

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$BASE_DIR/ssh-limits.sh"
source "$BASE_DIR/lock-reasons.sh"
source "$BASE_DIR/../menu/lib-ssh-users.sh"

# ---- sources for the full account card (same as add-ssh-user.sh) ----
DOMAIN_FILE="/etc/vpn-script/domain"
SLOWDNS_DIR="/etc/vpn-script/slowdns"
NS_DOMAIN_FILE="/etc/vpn-script/ns-domain"

ACTION="${1:-}"
[[ $# -gt 0 ]] && shift

case "$ACTION" in
  create)
    USERNAME="${1:-}"; PASSWORD="${2:-}"; DAYS="${3:-}"; CONN_LIMIT="${4:-0}"; BW_LIMIT_GB="${5:-0}"

    if [[ -z "$USERNAME" || -z "$PASSWORD" || -z "$DAYS" ]]; then
      echo "Usage: /createssh <username> <password> <days> [conn_limit] [bw_limit_gb]"; exit 1
    fi
    if ! [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
      echo "Invalid username. Use lowercase letters, digits, - and _ only."; exit 1
    fi
    if ! [[ "$DAYS" =~ ^[0-9]+$ ]]; then echo "Expiry must be a number of days."; exit 1; fi
    if ! [[ "$CONN_LIMIT" =~ ^[0-9]+$ ]]; then echo "Connection limit must be a number."; exit 1; fi
    if ! [[ "$BW_LIMIT_GB" =~ ^[0-9]+$ ]]; then echo "Bandwidth limit must be a number of GB."; exit 1; fi
    if id "$USERNAME" >/dev/null 2>&1; then
      echo "Error: system user '$USERNAME' already exists."; exit 1
    fi

    BW_LIMIT_MB=$(( BW_LIMIT_GB * 1024 ))
    EXPIRY_ISO=$(date -d "+${DAYS} days" +%Y-%m-%d)
    EXPIRY_CARD=$(date -d "+${DAYS} days" +%d/%m/%y)

    useradd -M -s /bin/false -e "$EXPIRY_ISO" "$USERNAME"
    echo "${USERNAME}:${PASSWORD}" | chpasswd
    ssh_limits_set "$USERNAME" "$CONN_LIMIT" "$BW_LIMIT_MB"

    CONN_DISPLAY="Unlimited"; [[ "$CONN_LIMIT" -gt 0 ]] && CONN_DISPLAY="$CONN_LIMIT"
    BW_DISPLAY="Unlimited"; [[ "$BW_LIMIT_GB" -gt 0 ]] && BW_DISPLAY="${BW_LIMIT_GB}GB"

    SERVER_IP="$(curl -s https://api.ipify.org || hostname -I | awk '{print $1}')"
    if [[ -f "$DOMAIN_FILE" && -s "$DOMAIN_FILE" ]]; then
      HOSTNAME_VAL="$(cat "$DOMAIN_FILE")"
    else
      HOSTNAME_VAL="$SERVER_IP"
    fi
    if [[ -f "$NS_DOMAIN_FILE" && -s "$NS_DOMAIN_FILE" ]]; then
      NS_DOMAIN="$(cat "$NS_DOMAIN_FILE")"
    else
      NS_DOMAIN="(not set)"
    fi
    if [[ -f "$SLOWDNS_DIR/server.pub" ]]; then
      PUBKEY="$(cat "$SLOWDNS_DIR/server.pub")"
    else
      PUBKEY="(slowdns pubkey not found)"
    fi

    cat <<MSG
====== PREMIUM SERVER ==============
 User Details
  - Username   : ${USERNAME}
  - Password   : ${PASSWORD}
  - IP         : ${SERVER_IP}
  - Expiration : ${EXPIRY_CARD}
  - Conn Limit : ${CONN_DISPLAY}
  - BW Limit   : ${BW_DISPLAY}
================================
SSH (WS|SSL)
  - Hostname  : ${HOSTNAME_VAL}
  - Ws ports  : 80, 8080, 8880
  - Tls port  : 443
  - Ohp port  : 8181
  - Payload   : GET / HTTP/1.1[crlf]Host: [host][crlf]Connection: Upgrade[crlf]User-Agent: [ua][crlf]Upgrade: websocket[crlf][crlf]
================================
OVPN (TCP|UDP)
  - Ovpn Tcp     : http://${HOSTNAME_VAL}:85/ovpn/client-tcp.ovpn
  - Ovpn Udp     : http://${HOSTNAME_VAL}:81/ovpn/client-udp.ovpn
================================
HTTP & SOCKS PROXY
  - HTTP Proxy   : ${HOSTNAME_VAL}:3128:${USERNAME}:${PASSWORD}
  - SOCKS5 Proxy : ${HOSTNAME_VAL}:1080:${USERNAME}:${PASSWORD}
================================
DNSTT (SlowDNS):
  - Nameserver : ${NS_DOMAIN}
  - PubKey     :
${PUBKEY}
  - DNS IP     : 1.1.1.1 / 8.8.8.8
======== ©CREEB SPACE ===================
MSG
    ;;

  list)
    users="$(ssh_user_list)"
    if [[ -z "$users" ]]; then
      echo "(no SSH accounts)"
      exit 0
    fi
    echo "SSH accounts:"
    while read -r u; do
      [[ -z "$u" ]] && continue
      exp="$(ssh_user_expiry "$u")"
      pstate="$(passwd -S "$u" 2>/dev/null | awk '{print $2}')"
      lock_note=""; [[ "$pstate" == "L" ]] && lock_note=" [LOCKED]"
      echo "- ${u}  (expires ${exp})${lock_note}"
    done <<< "$users"
    ;;

  delete)
    USERNAME="${1:-}"
    if [[ -z "$USERNAME" ]]; then echo "Usage: /deletessh <username>"; exit 1; fi
    if ! id "$USERNAME" >/dev/null 2>&1; then
      echo "No system user named '$USERNAME'."; exit 1
    fi
    uid=$(id -u "$USERNAME")
    if [[ "$uid" -lt 1000 ]]; then
      echo "Refusing to delete system account '$USERNAME' (UID $uid < 1000)."; exit 1
    fi
    pkill -u "$USERNAME" 2>/dev/null || true
    userdel "$USERNAME"
    ssh_limits_remove "$USERNAME"
    lock_reason_clear "$USERNAME"
    echo "Deleted SSH user '${USERNAME}'."
    ;;

  renew)
    USERNAME="${1:-}"; DAYS="${2:-}"
    if [[ -z "$USERNAME" || -z "$DAYS" ]]; then echo "Usage: /renewssh <username> <days>"; exit 1; fi
    if ! id "$USERNAME" >/dev/null 2>&1; then echo "No system user '$USERNAME'."; exit 1; fi
    if ! [[ "$DAYS" =~ ^[0-9]+$ ]]; then echo "Days must be a number."; exit 1; fi
    uid=$(id -u "$USERNAME")
    if [[ "$uid" -lt 1000 ]]; then
      echo "Refusing to touch system account '$USERNAME' (UID $uid)."; exit 1
    fi
    new_exp=$(date -d "+${DAYS} days" +%Y-%m-%d)
    chage -E "$new_exp" "$USERNAME"
    ssh_limits_reset_usage "$USERNAME"
    lock_reason_clear "$USERNAME"
    echo "Renewed '${USERNAME}' -> expires ${new_exp}."
    ;;

  *)
    echo "Usage: telegram-ssh-actions.sh <create|list|delete|renew> ..."
    exit 1
    ;;
esac

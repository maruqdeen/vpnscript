#!/bin/bash
# VPN-Starter-Kit :: menu/generate-ssh-config.sh
# Reprint an existing SSH/SlowDNS account's full card (e.g. the original
# card was lost) — same layout as add-ssh-user.sh. Needs core/ssh-passwords.sh
# for the password: Linux only stores a hash, not the plaintext, so
# add-ssh-user.sh records it there specifically so this can work.
set -uo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."; exit 1
fi

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$BASE/lib-ssh-users.sh"
source "$BASE/../core/ssh-passwords.sh"

DOMAIN_FILE="/etc/vpn-script/domain"
SLOWDNS_DIR="/etc/vpn-script/slowdns"
NS_DOMAIN_FILE="/etc/vpn-script/ns-domain"

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

echo ""
print_ssh_table
echo ""
read -rp "Enter username to generate config for: " NAME

if [[ -z "$NAME" ]]; then echo "Empty username."; exit 1; fi
if ! id "$NAME" >/dev/null 2>&1; then
  echo "No system user named '$NAME'."; exit 1
fi

PASSWORD="$(ssh_password_get "$NAME")"
if [[ -z "$PASSWORD" && "$NAME" == "trial" ]]; then
  PASSWORD="trial"
fi
if [[ -z "$PASSWORD" ]]; then
  PASSWORD="(not recorded — this account predates Generate Config; recreate or use Renew)"
fi

EXPIRY_CARD="$(ssh_user_expiry "$NAME")"
LIMITS_DISPLAY="$(ssh_user_limits_display "$NAME")"

cat <<CARD

====== PREMIUM SERVER ==============
 User Details
  - Username   : ${NAME}
  - Password   : ${PASSWORD}
  - IP         : ${SERVER_IP}
  - Expiration : ${EXPIRY_CARD}
  - Limits     : ${LIMITS_DISPLAY}
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
  - HTTP Proxy   : ${HOSTNAME_VAL}:3128:${NAME}:${PASSWORD}
  - SOCKS5 Proxy : ${HOSTNAME_VAL}:1080:${NAME}:${PASSWORD}
================================
DNSTT (SlowDNS):
  - Nameserver : ${NS_DOMAIN}
  - PubKey     :
${PUBKEY}
  - DNS IP     : 1.1.1.1 / 8.8.8.8
====== © CREEBSPACE   ==============

CARD

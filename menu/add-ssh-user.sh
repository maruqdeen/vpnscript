#!/bin/bash
# VPN-Starter-Kit :: menu/add-ssh-user.sh
# Create a Linux account for SSH-WebSocket + SlowDNS (one account covers both),
# then print a ready-to-share account card.
set -uo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."; exit 1
fi

# ---- sources for the card ----
DOMAIN_FILE="/etc/vpn-script/domain"          # saved once at install
SLOWDNS_DIR="/etc/vpn-script/slowdns"
NS_DOMAIN_FILE="/etc/vpn-script/ns-domain"    # saved once at install

SERVER_IP="$(curl -s https://api.ipify.org || hostname -I | awk '{print $1}')"

# Hostname: use saved domain if present, else fall back to the raw IP
if [[ -f "$DOMAIN_FILE" && -s "$DOMAIN_FILE" ]]; then
  HOSTNAME_VAL="$(cat "$DOMAIN_FILE")"
else
  HOSTNAME_VAL="$SERVER_IP"
fi

# SlowDNS nameserver: read from its own file (reliable, no parsing)
if [[ -f "$NS_DOMAIN_FILE" && -s "$NS_DOMAIN_FILE" ]]; then
  NS_DOMAIN="$(cat "$NS_DOMAIN_FILE")"
else
  NS_DOMAIN="(not set)"
fi

# SlowDNS public key
if [[ -f "$SLOWDNS_DIR/server.pub" ]]; then
  PUBKEY="$(cat "$SLOWDNS_DIR/server.pub")"
else
  PUBKEY="(slowdns pubkey not found)"
fi

# ---- gather input ----
read -rp "Enter Username : " USERNAME
read -rp "Enter Password : " PASSWORD
read -rp "Expiry (days)  : " DAYS

if [[ -z "$USERNAME" ]]; then echo "Username cannot be empty."; exit 1; fi
if ! [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
  echo "Invalid username. Use lowercase letters, digits, - and _ only."; exit 1
fi
if [[ -z "$PASSWORD" ]]; then echo "Password cannot be empty."; exit 1; fi
if ! [[ "$DAYS" =~ ^[0-9]+$ ]]; then echo "Expiry must be a number of days."; exit 1; fi
if id "$USERNAME" >/dev/null 2>&1; then
  echo "Error: system user '$USERNAME' already exists."; exit 1
fi

EXPIRY_ISO=$(date -d "+${DAYS} days" +%Y-%m-%d)
EXPIRY_CARD=$(date -d "+${DAYS} days" +%d/%m/%y)

# ---- create the account ----
useradd -M -s /bin/false -e "$EXPIRY_ISO" "$USERNAME"
echo "${USERNAME}:${PASSWORD}" | chpasswd

# ---- print the card ----
cat <<CARD

====== PREMIUM SERVER ======
 User Details
  - Username   : ${USERNAME}
  - Password   : ${PASSWORD}
  - IP         : ${SERVER_IP}
  - Expiration : ${EXPIRY_CARD}
================================
SSH (WS|SSL)
  - Hostname  : ${HOSTNAME_VAL}
  - Ws ports  : 80, 8080, 8880
  - Tls port  : 443
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
================================

CARD

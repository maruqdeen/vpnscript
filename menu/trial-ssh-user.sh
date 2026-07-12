#!/bin/bash
# VPN-Starter-Kit :: menu/trial-ssh-user.sh
# One-command 24-hour trial SSH-WS + SlowDNS account.
# Fixed credentials (username: trial / password: trial) so testers can log in
# instantly; the account is force-expired exactly 24 hours after creation.
set -uo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."; exit 1
fi

USERNAME="trial"
PASSWORD="trial"

# ---- sources for the card (same as add-ssh-user.sh) ----
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

# ---- a trial account is single-slot: replace any previous one + its timer ----
systemctl stop trial-expire.timer trial-expire.service >/dev/null 2>&1 || true
systemctl reset-failed trial-expire.timer trial-expire.service >/dev/null 2>&1 || true
if id "$USERNAME" >/dev/null 2>&1; then
  echo "An active trial account already exists — replacing it."
  pkill -u "$USERNAME" 2>/dev/null || true
  userdel "$USERNAME" 2>/dev/null || true
fi

# OS-level expiry is day-granularity only, so it can't hit "24h" exactly.
# +2 days is just a safety-net backstop (guarantees cleanup even across a
# reboot, which would otherwise wipe the transient timer below) — it never
# fires before the real 24h cutoff. The systemd timer does the precise cut.
EXPIRY_ISO=$(date -d "+2 days" +%Y-%m-%d)
EXPIRY_CARD=$(date -d "+24 hours" +"%d/%m/%y %H:%M")

useradd -M -s /bin/false -e "$EXPIRY_ISO" "$USERNAME"
echo "${USERNAME}:${PASSWORD}" | chpasswd

# Exact 24h cutoff — no extra package needed, systemd is already present.
if ! systemd-run --unit=trial-expire --on-active=24h \
     /bin/bash -c "pkill -u ${USERNAME} 2>/dev/null; userdel ${USERNAME} 2>/dev/null" \
     >/dev/null 2>&1; then
  echo "Warning: could not schedule the 24h auto-expiry timer."
  echo "         Account is still capped by OS expiry (within 48h)."
fi

cat <<CARD

====== TRIAL SERVER (24 HOURS) ======
 User Details
  - Username   : ${USERNAME}
  - Password   : ${PASSWORD}
  - IP         : ${SERVER_IP}
  - Expiration : ${EXPIRY_CARD} (24 hours from now)
================================
SSH (WS|SSL)
  - Hostname  : ${HOSTNAME_VAL}
  - Ws ports  : 80, 8080, 8880
  - Tls port  : 443
  - Payload   : GET / HTTP/1.1[crlf]Host: [host][crlf]Connection: Upgrade[crlf]User-Agent: [ua][crlf]Upgrade: websocket[crlf][crlf]
================================
SSH (OHP)
  - Hostname  : ${HOSTNAME_VAL}
  - Ohp port  : 8181
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
NOTE: shared trial login — one active trial at a time, auto-deleted after 24h.
================================

CARD

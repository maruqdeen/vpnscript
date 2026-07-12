#!/bin/bash
# VPN-Starter-Kit :: core/ddos-protection.sh
# Basic DDoS mitigation: SYN cookies + generous SYN/ICMP rate limiting.
# Disabled by default.
#
# Thresholds are deliberately generous, not tight. This box legitimately
# serves bursty, high-connection-count traffic by design — SSH, VMess/
# VLESS/Trojan (WS + gRPC, often several streams per client), OpenVPN,
# WireGuard, and an HTTP/SOCKS5 proxy all running at once — so a strict
# per-IP connection cap would end up DDoS-ing this box's own legitimate
# users on a busy day. These limits only kick in under genuine flood-
# level traffic, not normal multi-protocol VPN usage. No connlimit rule
# is added at all for the same reason: proxy usage alone can legitimately
# open many concurrent connections from one client IP.
# Usage: ddos-protection.sh <enable|disable>
set -uo pipefail

if [[ $EUID -ne 0 ]]; then echo "Run as root."; exit 1; fi

ACTION="${1:-}"
INSTALL_DIR="/etc/vpn-script"
FLAG="$INSTALL_DIR/ddos-protection.enabled"
SYSCTL_FILE="/etc/sysctl.d/99-vpn-ddos.conf"

case "$ACTION" in
  enable|disable) ;;
  *) echo "Usage: ddos-protection.sh <enable|disable>"; exit 1 ;;
esac

if [[ "$ACTION" == "disable" ]]; then
  while iptables -C INPUT -p tcp --syn -m limit --limit 100/s --limit-burst 200 -j ACCEPT 2>/dev/null; do
    iptables -D INPUT -p tcp --syn -m limit --limit 100/s --limit-burst 200 -j ACCEPT
  done
  while iptables -C INPUT -p tcp --syn -j DROP 2>/dev/null; do
    iptables -D INPUT -p tcp --syn -j DROP
  done
  while iptables -C INPUT -p icmp --icmp-type echo-request -m limit --limit 10/s --limit-burst 20 -j ACCEPT 2>/dev/null; do
    iptables -D INPUT -p icmp --icmp-type echo-request -m limit --limit 10/s --limit-burst 20 -j ACCEPT
  done
  while iptables -C INPUT -p icmp --icmp-type echo-request -j DROP 2>/dev/null; do
    iptables -D INPUT -p icmp --icmp-type echo-request -j DROP
  done
  netfilter-persistent save >/dev/null 2>&1 || iptables-save >/etc/iptables/rules.v4 2>/dev/null || true
  rm -f "$SYSCTL_FILE"
  sysctl --system >/dev/null 2>&1 || true
  rm -f "$FLAG"
  echo "DDoS protection DISABLED."
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
command -v iptables >/dev/null 2>&1 || apt-get install -y iptables >/dev/null

cat > "$SYSCTL_FILE" <<'EOF'
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_synack_retries = 2
net.ipv4.icmp_echo_ignore_broadcasts = 1
EOF
sysctl --system >/dev/null 2>&1 || true

# New TCP connections: generous rate limit (100/s, burst 200), then drop
# anything past that — only bites under genuine flood-level traffic.
iptables -C INPUT -p tcp --syn -m limit --limit 100/s --limit-burst 200 -j ACCEPT 2>/dev/null \
  || iptables -A INPUT -p tcp --syn -m limit --limit 100/s --limit-burst 200 -j ACCEPT
iptables -C INPUT -p tcp --syn -j DROP 2>/dev/null \
  || iptables -A INPUT -p tcp --syn -j DROP

# ICMP echo flood limiting.
iptables -C INPUT -p icmp --icmp-type echo-request -m limit --limit 10/s --limit-burst 20 -j ACCEPT 2>/dev/null \
  || iptables -A INPUT -p icmp --icmp-type echo-request -m limit --limit 10/s --limit-burst 20 -j ACCEPT
iptables -C INPUT -p icmp --icmp-type echo-request -j DROP 2>/dev/null \
  || iptables -A INPUT -p icmp --icmp-type echo-request -j DROP

netfilter-persistent save >/dev/null 2>&1 || iptables-save >/etc/iptables/rules.v4 2>/dev/null || true

touch "$FLAG"
echo "DDoS protection ENABLED."
echo "  SYN cookies on, new-connection rate capped at 100/s (burst 200)"
echo "  ICMP echo capped at 10/s (burst 20)"
echo "  Thresholds are intentionally generous for a multi-protocol VPN box —"
echo "  they guard against flood-level traffic, not normal bursty usage."

#!/bin/bash
# VPN-Starter-Kit :: core/slowdns-redirect.sh
# DNS arrives on UDP 53 (privileged). Redirect it to dnstt on 5300 so the
# server doesn't need to run as root or bind a privileged port directly.
set -euo pipefail

iptables -I INPUT -p udp --dport 5300 -j ACCEPT
iptables -t nat -I PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 5300

# Persist (iptables-persistent was installed in setup.sh)
netfilter-persistent save >/dev/null 2>&1 || iptables-save >/etc/iptables/rules.v4

echo ">>> DNS redirect active: UDP 53 -> 5300"
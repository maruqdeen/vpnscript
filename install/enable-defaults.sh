#!/bin/bash
# VPN-Starter-Kit :: install/enable-defaults.sh
# Turns on the services that now ship enabled-by-default on fresh installs
# (HAProxy SSH-SSL, SSLH multiplex, OpenVPN, HTTP+SOCKS5 proxy) — for
# servers that were installed before these defaults changed. Safe to
# re-run; each underlying core/*.sh script is idempotent.
# Requires a domain to already be set (menu > Settings > Change Primary
# Domain) since HAProxy needs a TLS cert to exist.
# Usage (on the VPS, as root):
#   wget -qO- https://raw.githubusercontent.com/maruqdeen/vpnscript/main/install/enable-defaults.sh | sudo bash
set -uo pipefail

INSTALL_DIR="/etc/vpn-script"
CORE_DIR="$INSTALL_DIR/core"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root:  sudo bash enable-defaults.sh"
  exit 1
fi

MISSING=0
for f in haproxy.sh sslh.sh openvpn.sh proxy.sh; do
  if [[ ! -f "$CORE_DIR/$f" ]]; then
    echo "Missing $CORE_DIR/$f"
    MISSING=1
  fi
done
if [[ "$MISSING" -eq 1 ]]; then
  echo ""
  echo "Run install/update.sh first to pull the latest core scripts:"
  echo "  wget -qO- https://raw.githubusercontent.com/maruqdeen/vpnscript/main/install/update.sh | sudo bash"
  exit 1
fi

echo ">>> Enabling HAProxy (SSH-SSL)..."
bash "$CORE_DIR/haproxy.sh" enable

echo ">>> Enabling SSLH multiplex..."
bash "$CORE_DIR/sslh.sh" enable

echo ">>> Enabling OpenVPN (first run builds a PKI + DH params, can take a few minutes)..."
bash "$CORE_DIR/openvpn.sh" enable

echo ">>> Enabling HTTP + SOCKS5 proxy..."
bash "$CORE_DIR/proxy.sh" enable

echo ""
echo "==================================================="
echo " Defaults enabled: HAProxy, SSLH, OpenVPN, Proxy"
echo " (BadVPN stays off unless you enable it yourself)"
echo "==================================================="

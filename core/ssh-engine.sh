#!/bin/bash
# VPN-Starter-Kit :: core/ssh-engine.sh
# Chooses which SSH daemon *tunnel* traffic (ws.py, SlowDNS, and
# HAProxy/SSLH if enabled) is forwarded into: Dropbear, OpenSSH, or both.
# SAFETY: this NEVER stops the OpenSSH (ssh) service — only Dropbear,
# which is tunnel-only, is ever started/stopped here. OpenSSH stays your
# admin access path on :22 no matter what's chosen.
# Usage: ssh-engine.sh <dropbear|openssh|both>
set -uo pipefail

if [[ $EUID -ne 0 ]]; then echo "Run as root."; exit 1; fi

MODE="${1:-}"
INSTALL_DIR="/etc/vpn-script"
TARGET_PORT_FILE="$INSTALL_DIR/ssh-target-port"
ENGINE_FILE="$INSTALL_DIR/ssh-engine"
NS_DOMAIN_FILE="$INSTALL_DIR/ns-domain"
CORE_DIR="$INSTALL_DIR/core"

case "$MODE" in
  dropbear) TARGET_PORT=143 ;;
  openssh)  TARGET_PORT=22  ;;
  both)     TARGET_PORT=143 ;;
  *) echo "Usage: ssh-engine.sh <dropbear|openssh|both>"; exit 1 ;;
esac

# Dropbear: stopped only for openssh-only mode (safe — it's tunnel-only,
# unrelated to admin access). Kept running for dropbear/both.
if [[ "$MODE" == "openssh" ]]; then
  systemctl disable --now dropbear >/dev/null 2>&1 || true
else
  systemctl enable --now dropbear >/dev/null 2>&1 || true
fi

# OpenSSH itself is never touched here, by design.

echo "$TARGET_PORT" > "$TARGET_PORT_FILE"
echo "$MODE" > "$ENGINE_FILE"

# ws.py/ohp.py read their target port from a file at startup — restart
# both to pick it up.
systemctl restart ws-proxy >/dev/null 2>&1 || true
systemctl restart ohp-proxy >/dev/null 2>&1 || true

# Rewrite + restart SlowDNS pointed at the new target port.
if [[ -f "$CORE_DIR/lib-slowdns-unit.sh" ]]; then
  source "$CORE_DIR/lib-slowdns-unit.sh"
  write_slowdns_unit "$(cat "$NS_DOMAIN_FILE" 2>/dev/null || echo CHANGE_ME)" "$TARGET_PORT"
  systemctl restart slowdns >/dev/null 2>&1 || true
fi

# Keep HAProxy/SSLH/Stunnel/UDP-Custom backends in sync if they're enabled.
[[ -f "$CORE_DIR/haproxy.sh" ]]    && bash "$CORE_DIR/haproxy.sh" regen
[[ -f "$CORE_DIR/sslh.sh" ]]       && bash "$CORE_DIR/sslh.sh" regen
[[ -f "$CORE_DIR/stunnel.sh" ]]    && bash "$CORE_DIR/stunnel.sh" regen
[[ -f "$CORE_DIR/udp-custom.sh" ]] && bash "$CORE_DIR/udp-custom.sh" regen

echo "SSH tunnel engine set to '$MODE' (tunnel target: 127.0.0.1:$TARGET_PORT)."

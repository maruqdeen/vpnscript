#!/bin/bash
# VPN-Starter-Kit :: core/haproxy.sh
# Lazy-install HAProxy to offer direct SSH-over-SSL on a dedicated port
# (444) — a separate connection mode from the WebSocket-based SSH-WS nginx
# already provides, and it never touches nginx's 80/8080/443. HAProxy
# TLS-terminates then forwards plaintext to whatever the current SSH
# tunnel engine target is (see core/ssh-engine.sh).
# Runs as our OWN unit (vpn-haproxy.service) against our OWN config file,
# so it can never collide with the distro package's default haproxy.service.
# Disabled by default.
# Usage: haproxy.sh <enable|disable|regen>
set -uo pipefail

if [[ $EUID -ne 0 ]]; then echo "Run as root."; exit 1; fi

ACTION="${1:-}"
INSTALL_DIR="/etc/vpn-script"
HAPROXY_DIR="$INSTALL_DIR/haproxy"
CFG="$HAPROXY_DIR/haproxy.cfg"
FLAG="$INSTALL_DIR/haproxy.enabled"
UNIT="/etc/systemd/system/vpn-haproxy.service"
PORT=444

case "$ACTION" in
  enable|disable|regen) ;;
  *) echo "Usage: haproxy.sh <enable|disable|regen>"; exit 1 ;;
esac

target_port() { cat "$INSTALL_DIR/ssh-target-port" 2>/dev/null || echo 143; }

write_cfg() {
  mkdir -p "$HAPROXY_DIR"
  # HAProxy wants one combined PEM, unlike nginx's split cert/key files.
  if ! cat "$INSTALL_DIR/tls/fullchain.pem" "$INSTALL_DIR/tls/privkey.pem" \
        > "$INSTALL_DIR/tls/haproxy.pem" 2>/dev/null; then
    echo "Missing TLS cert at $INSTALL_DIR/tls/ — set a domain first"
    echo "(Settings > Change Primary Domain & Ns Domain)."
    return 1
  fi

  cat > "$CFG" <<EOF
global
    daemon
    maxconn 4096

defaults
    mode tcp
    timeout connect 5s
    timeout client  1h
    timeout server  1h

frontend ssh_ssl_in
    bind *:${PORT} ssl crt ${INSTALL_DIR}/tls/haproxy.pem
    default_backend ssh_backend

backend ssh_backend
    server tunnel 127.0.0.1:$(target_port)
EOF
}

if [[ "$ACTION" == "regen" ]]; then
  [[ -f "$FLAG" ]] || exit 0
  write_cfg && systemctl restart vpn-haproxy >/dev/null 2>&1 || true
  exit 0
fi

if [[ "$ACTION" == "disable" ]]; then
  systemctl disable --now vpn-haproxy >/dev/null 2>&1 || true
  rm -f "$FLAG"
  echo "HAProxy (SSH-SSL) DISABLED."
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive
command -v haproxy >/dev/null 2>&1 || apt-get install -y haproxy >/dev/null
# never let the distro's default service fight over our port
systemctl disable --now haproxy >/dev/null 2>&1 || true

write_cfg || exit 1

cat > "$UNIT" <<EOF
[Unit]
Description=HAProxy SSH-over-SSL front door (VPN-Starter-Kit)
After=network.target

[Service]
Type=simple
ExecStart=/usr/sbin/haproxy -W -db -f ${CFG}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now vpn-haproxy
touch "$FLAG"
echo "HAProxy (SSH-SSL) ENABLED — connect with TLS on port ${PORT}."

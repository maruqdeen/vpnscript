#!/bin/bash
# VPN-Starter-Kit :: core/sslh.sh
# Lazy-install SSLH to multiplex ONE public port between raw SSH and
# TLS-wrapped SSH: plain SSH-looking connections go straight to the SSH
# tunnel engine's target (Dropbear/OpenSSH); TLS-looking connections are
# handed to HAProxy's SSH-SSL listener (core/haproxy.sh) for
# TLS-termination — so SSLH's TLS branch only actually works while
# HAProxy is also enabled.
# Runs as our OWN unit (vpn-sslh.service) against our OWN config, so it
# can never collide with the distro package's default sslh.service.
# Disabled by default.
# Usage: sslh.sh <enable|disable|regen>
set -uo pipefail

if [[ $EUID -ne 0 ]]; then echo "Run as root."; exit 1; fi

ACTION="${1:-}"
INSTALL_DIR="/etc/vpn-script"
SSLH_DIR="$INSTALL_DIR/sslh"
CFG="$SSLH_DIR/sslh.cfg"
FLAG="$INSTALL_DIR/sslh.enabled"
UNIT="/etc/systemd/system/vpn-sslh.service"
PORT=446
TLS_BACKEND_PORT=444

case "$ACTION" in
  enable|disable|regen) ;;
  *) echo "Usage: sslh.sh <enable|disable|regen>"; exit 1 ;;
esac

target_port() { cat "$INSTALL_DIR/ssh-target-port" 2>/dev/null || echo 143; }

write_cfg() {
  mkdir -p "$SSLH_DIR"
  cat > "$CFG" <<EOF
listen:
(
  { host: "0.0.0.0"; port: "${PORT}"; }
);

protocols:
(
  { name: "ssh"; host: "127.0.0.1"; port: "$(target_port)"; },
  { name: "tls"; host: "127.0.0.1"; port: "${TLS_BACKEND_PORT}"; }
);
EOF
}

if [[ "$ACTION" == "regen" ]]; then
  [[ -f "$FLAG" ]] || exit 0
  write_cfg && systemctl restart vpn-sslh >/dev/null 2>&1 || true
  exit 0
fi

if [[ "$ACTION" == "disable" ]]; then
  systemctl disable --now vpn-sslh >/dev/null 2>&1 || true
  rm -f "$FLAG"
  echo "SSLH multiplex DISABLED."
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive
command -v sslh >/dev/null 2>&1 || apt-get install -y sslh >/dev/null
systemctl disable --now sslh >/dev/null 2>&1 || true

write_cfg

cat > "$UNIT" <<EOF
[Unit]
Description=SSLH SSH/TLS multiplexer (VPN-Starter-Kit)
After=network.target

[Service]
Type=simple
ExecStart=/usr/sbin/sslh --foreground --config ${CFG}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now vpn-sslh
touch "$FLAG"
echo "SSLH multiplex ENABLED on port ${PORT}."
echo "  ssh branch -> tunnel engine target"
echo "  tls branch -> HAProxy:${TLS_BACKEND_PORT}"
if [[ ! -f "$INSTALL_DIR/haproxy.enabled" ]]; then
  echo "Note: HAProxy isn't enabled yet, so SSLH's TLS branch won't connect until you enable it too."
fi

#!/bin/bash
# VPN-Starter-Kit :: core/stunnel.sh
# Lazy-install Stunnel to wrap SSH/Dropbear in TLS on ports that look like
# ordinary mail services (110 = POP3S, 587 = SMTP submission) -- a
# different disguise from HAProxy's dedicated SSH-SSL port (444), useful
# against firewalls that specifically target port 444 but leave common
# mail ports alone. Port 443 deliberately excluded -- nginx already owns
# it for Xray/WS/TLS.
# Runs as our OWN unit (vpn-stunnel.service) against our own config, so it
# can never collide with the distro package's default stunnel4.service.
# Disabled by default.
# Usage: stunnel.sh <enable|disable|regen>
set -uo pipefail

if [[ $EUID -ne 0 ]]; then echo "Run as root."; exit 1; fi

ACTION="${1:-}"
INSTALL_DIR="/etc/vpn-script"
STUNNEL_DIR="$INSTALL_DIR/stunnel"
CFG="$STUNNEL_DIR/stunnel.conf"
FLAG="$INSTALL_DIR/stunnel.enabled"
UNIT="/etc/systemd/system/vpn-stunnel.service"
PORTS=(110 587)

case "$ACTION" in
  enable|disable|regen) ;;
  *) echo "Usage: stunnel.sh <enable|disable|regen>"; exit 1 ;;
esac

target_port() { cat "$INSTALL_DIR/ssh-target-port" 2>/dev/null || echo 143; }

write_cfg() {
  mkdir -p "$STUNNEL_DIR"
  if [[ ! -f "$INSTALL_DIR/tls/fullchain.pem" || ! -f "$INSTALL_DIR/tls/privkey.pem" ]]; then
    echo "Missing TLS cert at $INSTALL_DIR/tls/ — set a domain first"
    echo "(Settings > Change Primary Domain & Ns Domain)."
    return 1
  fi

  {
    echo "pid = ${STUNNEL_DIR}/stunnel.pid"
    echo "foreground = yes"
    echo ""
    for port in "${PORTS[@]}"; do
      echo "[ssh-${port}]"
      echo "accept = ${port}"
      echo "connect = 127.0.0.1:$(target_port)"
      echo "cert = ${INSTALL_DIR}/tls/fullchain.pem"
      echo "key = ${INSTALL_DIR}/tls/privkey.pem"
      echo ""
    done
  } > "$CFG"
}

if [[ "$ACTION" == "regen" ]]; then
  [[ -f "$FLAG" ]] || exit 0
  write_cfg && systemctl restart vpn-stunnel >/dev/null 2>&1 || true
  exit 0
fi

if [[ "$ACTION" == "disable" ]]; then
  systemctl disable --now vpn-stunnel >/dev/null 2>&1 || true
  rm -f "$FLAG"
  echo "Stunnel DISABLED."
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
command -v stunnel4 >/dev/null 2>&1 || apt-get install -y stunnel4 >/dev/null
# never let the distro's default service fight over our config/ports
systemctl disable --now stunnel4 >/dev/null 2>&1 || true

# Debian/Ubuntu packaging has moved the actual binary between
# /usr/bin/stunnel4 and /usr/bin/stunnel across versions (same class of
# gotcha that bit SSLH's binary path earlier) -- resolve whichever exists
# instead of assuming one.
STUNNEL_BIN=""
for cand in /usr/bin/stunnel4 /usr/bin/stunnel /usr/sbin/stunnel4 /usr/sbin/stunnel; do
  if [[ -x "$cand" ]]; then STUNNEL_BIN="$cand"; break; fi
done
if [[ -z "$STUNNEL_BIN" ]]; then
  echo "ERROR: no stunnel binary found after install (checked stunnel4, stunnel)."
  exit 1
fi

write_cfg || exit 1

cat > "$UNIT" <<EOF
[Unit]
Description=Stunnel SSH-over-TLS (VPN-Starter-Kit)
After=network.target

[Service]
Type=simple
ExecStart=${STUNNEL_BIN} ${CFG}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable vpn-stunnel >/dev/null 2>&1 || true
systemctl restart vpn-stunnel

sleep 1
if systemctl is-active --quiet vpn-stunnel; then
  touch "$FLAG"
  echo "Stunnel ENABLED — connect with TLS on ports ${PORTS[*]}."
else
  echo "ERROR: vpn-stunnel failed to start. Check: journalctl -u vpn-stunnel -n 30 --no-pager"
  exit 1
fi

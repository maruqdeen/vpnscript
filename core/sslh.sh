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
export NEEDRESTART_MODE=a
command -v sslh >/dev/null 2>&1 || apt-get install -y sslh >/dev/null
systemctl disable --now sslh >/dev/null 2>&1 || true

# The Debian/Ubuntu sslh package picks fork-vs-select via update-alternatives
# (a debconf question, "sslh/default"), and under a noninteractive frontend
# that alternative doesn't reliably land at /usr/sbin/sslh across releases —
# sometimes it's left unset, which silently breaks ExecStart. Resolve the
# real binary directly instead of assuming the /usr/sbin/sslh symlink exists.
SSLH_BIN=""
for cand in /usr/sbin/sslh /usr/sbin/sslh-select /usr/sbin/sslh-fork /usr/bin/sslh; do
  if [[ -x "$cand" ]]; then SSLH_BIN="$cand"; break; fi
done
if [[ -z "$SSLH_BIN" ]]; then
  echo "ERROR: no sslh binary found after install (checked sslh, sslh-select, sslh-fork)."
  echo "  Try:  apt-get install --reinstall sslh"
  exit 1
fi

write_cfg

cat > "$UNIT" <<EOF
[Unit]
Description=SSLH SSH/TLS multiplexer (VPN-Starter-Kit)
After=network.target

[Service]
Type=simple
# This build's flags are short-form only (confirmed via `sslh --help` on a
# live Ubuntu 22.04 box: 1.20-1+deb11u1build0.22.04.1) -- no --foreground,
# no --config. -F takes the path glued directly on, no space, or sslh
# silently falls back to its own default search paths and fails to start.
ExecStart=${SSLH_BIN} -f -F${CFG}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now vpn-sslh >/dev/null 2>&1 || true

# systemctl enable --now doesn't fail the script if the unit dies right
# after starting (e.g. a config error) — verify it's actually up before
# claiming success, instead of touching the enabled-flag regardless.
sleep 1
if systemctl is-active --quiet vpn-sslh; then
  touch "$FLAG"
  echo "SSLH multiplex ENABLED on port ${PORT}."
  echo "  ssh branch -> tunnel engine target"
  echo "  tls branch -> HAProxy:${TLS_BACKEND_PORT}"
  if [[ ! -f "$INSTALL_DIR/haproxy.enabled" ]]; then
    echo "Note: HAProxy isn't enabled yet, so SSLH's TLS branch won't connect until you enable it too."
  fi
else
  echo "ERROR: vpn-sslh failed to start. Check:  journalctl -u vpn-sslh -n 30 --no-pager"
  exit 1
fi

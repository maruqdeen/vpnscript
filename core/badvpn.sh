#!/bin/bash
# VPN-Starter-Kit :: core/badvpn.sh
# Lazy build-from-source install of badvpn-udpgw (UDP gateway for SSH
# tunnel clients, e.g. HTTP Injector's "UDPGW" field). Bound to
# 127.0.0.1:7300 ONLY — it has no authentication of its own, so it must
# never be reached except through an already-authenticated SSH tunnel
# (the client does a local port-forward to 127.0.0.1:7300 on the server).
# Exposing this port publicly would let anyone relay arbitrary UDP through
# your server. Disabled by default.
# Usage: badvpn.sh <enable|disable>
set -uo pipefail

if [[ $EUID -ne 0 ]]; then echo "Run as root."; exit 1; fi

ACTION="${1:-}"
INSTALL_DIR="/etc/vpn-script"
BADVPN_DIR="$INSTALL_DIR/badvpn"
BUILD_DIR="/tmp/badvpn-build"
BIN="$BADVPN_DIR/badvpn-udpgw"
FLAG="$INSTALL_DIR/badvpn.enabled"
UNIT="/etc/systemd/system/vpn-badvpn.service"

case "$ACTION" in
  enable|disable) ;;
  *) echo "Usage: badvpn.sh <enable|disable>"; exit 1 ;;
esac

if [[ "$ACTION" == "disable" ]]; then
  systemctl disable --now vpn-badvpn >/dev/null 2>&1 || true
  rm -f "$FLAG"
  echo "BadVPN (UDPGW) DISABLED."
  exit 0
fi

mkdir -p "$BADVPN_DIR"

if [[ ! -s "$BIN" ]]; then
  echo ">>> Building badvpn-udpgw from source (first run only, ~1 min)..."
  export DEBIAN_FRONTEND=noninteractive
  command -v cmake >/dev/null 2>&1 || apt-get install -y cmake >/dev/null
  command -v gcc   >/dev/null 2>&1 || apt-get install -y build-essential >/dev/null
  command -v git   >/dev/null 2>&1 || apt-get install -y git >/dev/null

  rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"
  git clone --depth 1 https://github.com/ambrop72/badvpn.git "$BUILD_DIR/src" \
    || { echo "Source download failed. Check network."; exit 1; }
  mkdir -p "$BUILD_DIR/build" && cd "$BUILD_DIR/build"
  cmake -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 "$BUILD_DIR/src" >/dev/null \
    || { echo "cmake configure failed."; exit 1; }
  make >/dev/null || { echo "Build failed. See output above."; exit 1; }
  cp udpgw/badvpn-udpgw "$BIN"
  chmod +x "$BIN"
  cd / && rm -rf "$BUILD_DIR"
  echo "    built: $BIN"
fi

cat > "$UNIT" <<EOF
[Unit]
Description=BadVPN UDPGW (VPN-Starter-Kit)
After=network.target

[Service]
Type=simple
ExecStart=$BIN --listen-addr 127.0.0.1:7300 --max-clients 1000 --max-connections-for-client 10
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now vpn-badvpn
touch "$FLAG"
echo "BadVPN (UDPGW) ENABLED — 127.0.0.1:7300."
echo "Reach it via an SSH local port-forward from the tunnel client only —"
echo "never expose 7300 publicly (it has no authentication of its own)."

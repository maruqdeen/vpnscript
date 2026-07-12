#!/bin/bash
# VPN-Starter-Kit :: core/openvpn.sh
# Lazy-install OpenVPN with 3 listeners: TCP/1194, UDP/1194, UDP/443.
# (TCP/443 is skipped on purpose — nginx already owns TCP 443 for
# TLS/Xray/WS traffic, and two processes can't bind the same port.)
# Uses ONE shared client identity for everyone rather than per-account
# certs — the account card hands out a single static download link, so a
# single shared client cert matches that design. Self-contained .ovpn
# files (cert/key inline) are served by nginx on ports 85 (tcp) and 81
# (udp), same content on both — reachable at either port either way.
# Usage: openvpn.sh <enable|disable>
set -uo pipefail

if [[ $EUID -ne 0 ]]; then echo "Run as root."; exit 1; fi

ACTION="${1:-}"
case "$ACTION" in
  enable|disable) ;;
  *) echo "Usage: openvpn.sh <enable|disable>"; exit 1 ;;
esac

INSTALL_DIR="/etc/vpn-script"
OVPN_DIR="/etc/openvpn"
PKI_DIR="$OVPN_DIR/easy-rsa"
DL_DIR="$INSTALL_DIR/ovpn-dl/ovpn"
FLAG="$INSTALL_DIR/openvpn.enabled"
UNITS=(openvpn@vpn-tcp1194 openvpn@vpn-udp1194 openvpn@vpn-udp443)

if [[ "$ACTION" == "disable" ]]; then
  systemctl disable --now "${UNITS[@]}" >/dev/null 2>&1 || true
  rm -f "$FLAG"
  echo "OpenVPN DISABLED (TCP/1194, UDP/1194, UDP/443)."
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
command -v openvpn >/dev/null 2>&1 || apt-get install -y openvpn >/dev/null
[[ -d /usr/share/easy-rsa ]] || apt-get install -y easy-rsa >/dev/null

IFACE="$(ip route show default | awk '{print $5; exit}')"
[[ -z "$IFACE" ]] && IFACE="eth0"

# ---- 1. PKI (only the first time) ----
if [[ ! -s "$PKI_DIR/pki/issued/server.crt" ]]; then
  echo ">>> Building OpenVPN PKI (CA + server + one shared client cert)..."
  mkdir -p "$PKI_DIR"
  cp -r /usr/share/easy-rsa/* "$PKI_DIR/" 2>/dev/null || true
  cd "$PKI_DIR" || exit 1
  ./easyrsa init-pki >/dev/null
  EASYRSA_BATCH=1 ./easyrsa build-ca nopass >/dev/null
  EASYRSA_BATCH=1 ./easyrsa build-server-full server nopass >/dev/null
  EASYRSA_BATCH=1 ./easyrsa build-client-full client nopass >/dev/null
  openvpn --genkey secret "$PKI_DIR/pki/ta.key"
  echo ">>> Generating DH parameters (can take a couple of minutes)..."
  ./easyrsa gen-dh >/dev/null
  cd - >/dev/null || exit 1
fi

# ---- 2. Per-listener server configs ----
write_server_conf() {
  local name="$1" proto="$2" port="$3" subnet="$4" dev="$5"
  cat > "$OVPN_DIR/${name}.conf" <<EOF
port ${port}
proto ${proto}
dev ${dev}
topology subnet
server ${subnet} 255.255.255.0
ca ${PKI_DIR}/pki/ca.crt
cert ${PKI_DIR}/pki/issued/server.crt
key ${PKI_DIR}/pki/private/server.key
dh ${PKI_DIR}/pki/dh.pem
tls-crypt ${PKI_DIR}/pki/ta.key
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 8.8.8.8"
keepalive 10 120
persist-key
persist-tun
user nobody
group nogroup
status /var/log/vpn-script/openvpn-${name}-status.log
verb 3
EOF
}

write_server_conf vpn-tcp1194 tcp-server 1194 10.8.0.0  tun-tcp1194
write_server_conf vpn-udp1194 udp        1194 10.9.0.0  tun-udp1194
write_server_conf vpn-udp443  udp        443  10.10.0.0 tun-udp443

# ---- 3. IP forwarding + NAT so clients actually reach the internet ----
cat > /etc/sysctl.d/99-vpn-ovpn-forward.conf <<'EOF'
net.ipv4.ip_forward=1
EOF
sysctl --system >/dev/null 2>&1 || true

for subnet in 10.8.0.0/24 10.9.0.0/24 10.10.0.0/24; do
  iptables -t nat -C POSTROUTING -s "$subnet" -o "$IFACE" -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -s "$subnet" -o "$IFACE" -j MASQUERADE
done
netfilter-persistent save >/dev/null 2>&1 || iptables-save >/etc/iptables/rules.v4

# ---- 4. Shared client .ovpn files (self-contained, inline certs) ----
mkdir -p "$DL_DIR"
DOMAIN="$(cat "$INSTALL_DIR/domain" 2>/dev/null)"
SERVER_HOST="${DOMAIN:-$(curl -s https://api.ipify.org || echo "$IFACE")}"

write_client_ovpn() {
  local out="$1"; shift
  {
    echo "client"
    echo "dev tun"
    for r in "$@"; do echo "remote $r"; done
    echo "resolv-retry infinite"
    echo "nobind"
    echo "persist-key"
    echo "persist-tun"
    echo "remote-cert-tls server"
    echo "verb 3"
    echo "<ca>"
    cat "$PKI_DIR/pki/ca.crt"
    echo "</ca>"
    echo "<cert>"
    sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' "$PKI_DIR/pki/issued/client.crt"
    echo "</cert>"
    echo "<key>"
    cat "$PKI_DIR/pki/private/client.key"
    echo "</key>"
    echo "<tls-crypt>"
    cat "$PKI_DIR/pki/ta.key"
    echo "</tls-crypt>"
  } > "$out"
}

write_client_ovpn "$DL_DIR/client-tcp.ovpn" "$SERVER_HOST 1194 tcp"
write_client_ovpn "$DL_DIR/client-udp.ovpn" "$SERVER_HOST 1194 udp" "$SERVER_HOST 443 udp"

# ---- 5. Download portal (nginx, ports 85 + 81 — additive, own conf file) ----
cat > /etc/nginx/conf.d/vpn-ovpn-dl.conf <<EOF
server {
    listen 85;
    listen [::]:85;
    listen 81;
    listen [::]:81;
    server_name _;
    root ${INSTALL_DIR}/ovpn-dl;
    location /ovpn/ { autoindex off; }
}
EOF
if nginx -t 2>&1; then
  systemctl reload nginx
else
  echo "WARNING: nginx config test failed — the .ovpn download portal (85/81)"
  echo "         may not be active. Check: nginx -t"
fi

# ---- 6. Enable + start all 3 listeners ----
systemctl daemon-reload
systemctl enable --now "${UNITS[@]}" >/dev/null 2>&1 || true

# enable --now not failing the script doesn't mean the units actually
# came up -- verify each one before claiming success, instead of
# touching the enabled-flag and printing ENABLED regardless.
sleep 1
FAILED=()
for u in "${UNITS[@]}"; do
  systemctl is-active --quiet "$u" || FAILED+=("$u")
done

if [[ ${#FAILED[@]} -eq 0 ]]; then
  touch "$FLAG"
  echo "OpenVPN ENABLED."
  echo "  TCP : ${SERVER_HOST}:1194"
  echo "  UDP : ${SERVER_HOST}:1194 (falls back to :443 udp)"
  echo "  Download portal:"
  echo "    http://${SERVER_HOST}:85/ovpn/client-tcp.ovpn"
  echo "    http://${SERVER_HOST}:81/ovpn/client-udp.ovpn"
else
  echo "ERROR: the following listener(s) failed to start: ${FAILED[*]}"
  for u in "${FAILED[@]}"; do
    echo "  Check:  journalctl -u $u -n 30 --no-pager"
  done
  exit 1
fi

#!/bin/bash
# VPN-Starter-Kit :: core/wireguard.sh
# Shared WireGuard helpers: lazy server bootstrap, peer sync, IP
# allocation. Source this file; it is not meant to be executed directly.
#
# WireGuard is a completely separate technology from the Xray protocols
# (vless/vmess/trojan) — a kernel-level UDP service, not an Xray inbound,
# so it doesn't go through nginx at all. It's set up lazily: the first
# time an admin creates a WireGuard account, wg_ensure_server() installs
# wireguard-tools + qrencode, generates the server's own keypair, and
# brings up the wg0 interface. No separate "enable" step needed.
#
# clients.json is the authoritative source of truth for peers (same
# pattern as Xray's config.json) — wg0.conf's [Peer] blocks are always
# regenerated FROM it, never hand-edited, so the two can't drift.

WG_IFACE="wg0"
WG_DIR="/etc/wireguard"
WG_SUBNET="10.7.20"
WG_PORT="51820"
WG_STATE_DIR="/etc/vpn-script/wireguard"
WG_CLIENTS_JSON="$WG_STATE_DIR/clients.json"
WG_INTERFACE_CONF="$WG_DIR/wg0-interface.conf"
WG_SERVER_PUB_FILE="$WG_STATE_DIR/server-public.key"

# Idempotent: safe to call before every action (add/del/renew/list).
wg_ensure_server() {
  mkdir -p "$WG_STATE_DIR"
  [[ -f "$WG_CLIENTS_JSON" ]] || { echo '[]' > "$WG_CLIENTS_JSON"; chmod 600 "$WG_CLIENTS_JSON"; }

  export DEBIAN_FRONTEND=noninteractive
  command -v wg >/dev/null 2>&1 || apt-get install -y wireguard >/dev/null
  command -v qrencode >/dev/null 2>&1 || apt-get install -y qrencode >/dev/null

  # Idempotent even if core/openvpn.sh already enabled this.
  cat > /etc/sysctl.d/99-vpn-wg-forward.conf <<'EOF'
net.ipv4.ip_forward=1
EOF
  sysctl --system >/dev/null 2>&1 || true

  if [[ ! -f "$WG_INTERFACE_CONF" ]]; then
    echo ">>> Bootstrapping WireGuard server (first run only)..."
    mkdir -p "$WG_DIR"
    chmod 700 "$WG_DIR"
    local iface priv pub
    iface="$(ip route show default | awk '{print $5; exit}')"
    [[ -z "$iface" ]] && iface="eth0"
    priv="$(wg genkey)"
    pub="$(echo "$priv" | wg pubkey)"
    echo "$pub" > "$WG_SERVER_PUB_FILE"
    cat > "$WG_INTERFACE_CONF" <<EOF
[Interface]
PrivateKey = ${priv}
Address = ${WG_SUBNET}.1/24
ListenPort = ${WG_PORT}
PostUp = iptables -t nat -A POSTROUTING -s ${WG_SUBNET}.0/24 -o ${iface} -j MASQUERADE; iptables -A FORWARD -i ${WG_IFACE} -j ACCEPT; iptables -A FORWARD -o ${WG_IFACE} -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s ${WG_SUBNET}.0/24 -o ${iface} -j MASQUERADE; iptables -D FORWARD -i ${WG_IFACE} -j ACCEPT; iptables -D FORWARD -o ${WG_IFACE} -j ACCEPT
EOF
    chmod 600 "$WG_INTERFACE_CONF"
  fi

  wg_sync_peers
  systemctl enable --now "wg-quick@${WG_IFACE}" >/dev/null 2>&1 || true
}

# Regenerate wg0.conf's [Peer] blocks from clients.json and hot-reload —
# `wg syncconf` applies the diff live, without dropping existing peer
# connections (unlike a full `systemctl restart`).
wg_sync_peers() {
  {
    cat "$WG_INTERFACE_CONF"
    echo ""
    jq -r '.[] |
      "[Peer]\n# " + .username + "_" + .expiry + "\nPublicKey = " + .public_key + "\nPresharedKey = " + .preshared_key + "\nAllowedIPs = " + .address + "/32\n"
    ' "$WG_CLIENTS_JSON"
  } > "$WG_DIR/${WG_IFACE}.conf"
  chmod 600 "$WG_DIR/${WG_IFACE}.conf"

  if systemctl is-active --quiet "wg-quick@${WG_IFACE}"; then
    wg syncconf "$WG_IFACE" <(wg-quick strip "$WG_IFACE") 2>/dev/null \
      || systemctl restart "wg-quick@${WG_IFACE}"
  fi
}

# Lowest unused host address (2-254) in the tunnel subnet. Prints nothing
# if the /24 is full (253 peers max).
wg_next_ip() {
  local used
  used="$(jq -r '.[].address' "$WG_CLIENTS_JSON" 2>/dev/null)"
  for i in $(seq 2 254); do
    if ! grep -qx "${WG_SUBNET}.${i}" <<< "$used"; then
      echo "${WG_SUBNET}.${i}"
      return
    fi
  done
}

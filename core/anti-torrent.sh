#!/bin/bash
# VPN-Starter-Kit :: core/anti-torrent.sh
# Blocks common BitTorrent/DHT protocol signatures on the FORWARD chain —
# i.e. traffic being routed THROUGH the box by OpenVPN/WireGuard clients,
# not traffic TO the box itself, so this can't touch the admin's own SSH
# session (INPUT chain) or the Xray/SSH-WS tunnels (encrypted TLS/WS —
# there's no plaintext BitTorrent signature to match inside those anyway).
# Heuristic string-matching, not a real DPI engine: it'll miss encrypted
# torrent traffic and could rarely false-positive on unrelated payloads
# that happen to contain the same byte sequence. Disabled by default.
# Usage: anti-torrent.sh <enable|disable>
set -uo pipefail

if [[ $EUID -ne 0 ]]; then echo "Run as root."; exit 1; fi

ACTION="${1:-}"
INSTALL_DIR="/etc/vpn-script"
FLAG="$INSTALL_DIR/anti-torrent.enabled"

case "$ACTION" in
  enable|disable) ;;
  *) echo "Usage: anti-torrent.sh <enable|disable>"; exit 1 ;;
esac

# Common BitTorrent/DHT/tracker signatures seen in cleartext handshakes
# and HTTP tracker announces.
SIGNATURES=(
  "BitTorrent protocol"
  "BitTorrent"
  "peer_id="
  "announce.php?passkey="
  "get_peers"
  "announce_peer"
  "find_node"
  ".torrent"
)

if [[ "$ACTION" == "disable" ]]; then
  for sig in "${SIGNATURES[@]}"; do
    while iptables -C FORWARD -m string --string "$sig" --algo bm -j DROP 2>/dev/null; do
      iptables -D FORWARD -m string --string "$sig" --algo bm -j DROP
    done
  done
  netfilter-persistent save >/dev/null 2>&1 || iptables-save >/etc/iptables/rules.v4 2>/dev/null || true
  rm -f "$FLAG"
  echo "Anti-torrent filtering DISABLED."
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
command -v iptables >/dev/null 2>&1 || apt-get install -y iptables >/dev/null

for sig in "${SIGNATURES[@]}"; do
  iptables -C FORWARD -m string --string "$sig" --algo bm -j DROP 2>/dev/null \
    || iptables -A FORWARD -m string --string "$sig" --algo bm -j DROP
done
netfilter-persistent save >/dev/null 2>&1 || iptables-save >/etc/iptables/rules.v4 2>/dev/null || true

touch "$FLAG"
echo "Anti-torrent filtering ENABLED (${#SIGNATURES[@]} signatures, FORWARD chain)."
echo "  Heuristic string-match only — won't catch encrypted/obfuscated torrent traffic."

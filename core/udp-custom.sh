#!/bin/bash
# VPN-Starter-Kit :: core/udp-custom.sh
# "SSH UDP Custom": tunnels SSH/Dropbear over UDP across a huge public
# port range (1-65535) so clients can pick any port to dodge port-based
# blocking. A single process can't usefully bind 65535 sockets, so this
# runs ONE actual udp2raw server on an internal port and uses iptables to
# REDIRECT the whole public UDP range to it -- EXCLUDING every UDP port
# already used elsewhere in this stack (SlowDNS 53, OpenVPN 1194/443,
# WireGuard 51820), or those services would silently break.
#
# Built on udp2raw (github.com/wangyu-/udp2raw, fetched from its official
# GitHub releases) rather than a hand-rolled relay: reliably tunneling a
# TCP-like stream over raw UDP (packet loss/reordering handling) is a hard
# problem udp2raw already solves properly; a naive relay could silently
# corrupt SSH sessions under real packet loss.
#
# Own systemd unit (vpn-udpcustom.service). Disabled by default.
# Usage: udp-custom.sh <enable|disable|regen>
set -uo pipefail

if [[ $EUID -ne 0 ]]; then echo "Run as root."; exit 1; fi

ACTION="${1:-}"
INSTALL_DIR="/etc/vpn-script"
UDPC_DIR="$INSTALL_DIR/udp-custom"
BIN="$UDPC_DIR/udp2raw"
KEY_FILE="$UDPC_DIR/key"
FLAG="$INSTALL_DIR/udpcustom.enabled"
UNIT="/etc/systemd/system/vpn-udpcustom.service"
INTERNAL_PORT=39001
# UDP ports already used elsewhere in this stack -- never redirect these,
# or SlowDNS/OpenVPN/WireGuard would silently stop receiving traffic.
EXCLUDE_PORTS=(53 443 1194 51820 "$INTERNAL_PORT")

case "$ACTION" in
  enable|disable|regen) ;;
  *) echo "Usage: udp-custom.sh <enable|disable|regen>"; exit 1 ;;
esac

target_port() { cat "$INSTALL_DIR/ssh-target-port" 2>/dev/null || echo 143; }

iptables_rule() {
  local action="$1" # -A or -D
  local exclude_csv
  exclude_csv="$(IFS=,; echo "${EXCLUDE_PORTS[*]}")"
  iptables -t nat "$action" PREROUTING -p udp -m multiport ! --dports "$exclude_csv" \
    -j REDIRECT --to-port "$INTERNAL_PORT" 2>/dev/null
}

write_unit() {
  cat > "$UNIT" <<EOF
[Unit]
Description=SSH UDP Custom - udp2raw server (VPN-Starter-Kit)
After=network.target

[Service]
Type=simple
ExecStart=${BIN} -s -l0.0.0.0:${INTERNAL_PORT} -r127.0.0.1:$(target_port) -k "$(cat "$KEY_FILE")" --raw-mode udp
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
}

if [[ "$ACTION" == "regen" ]]; then
  [[ -f "$FLAG" && -x "$BIN" && -f "$KEY_FILE" ]] || exit 0
  write_unit
  systemctl daemon-reload
  systemctl restart vpn-udpcustom >/dev/null 2>&1 || true
  exit 0
fi

if [[ "$ACTION" == "disable" ]]; then
  systemctl disable --now vpn-udpcustom >/dev/null 2>&1 || true
  iptables_rule -D
  netfilter-persistent save >/dev/null 2>&1 || true
  rm -f "$FLAG"
  echo "SSH UDP Custom DISABLED."
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
mkdir -p "$UDPC_DIR"

if [[ ! -x "$BIN" ]]; then
  echo ">>> Downloading udp2raw (github.com/wangyu-/udp2raw)..."
  command -v jq >/dev/null 2>&1 || apt-get install -y jq >/dev/null

  case "$(uname -m)" in
    x86_64)  ARCH_PATTERN="amd64" ;;
    # udp2raw's release only labels this "arm" with no 32/64-bit distinction
    # in the filename; unconfirmed whether it's actually aarch64-compatible.
    # The is-active check below will fail loudly (wrong-architecture binaries
    # simply can't exec) rather than silently claim success if this guess
    # is wrong -- x86_64 is the confirmed, primary target here regardless.
    aarch64) ARCH_PATTERN="arm" ;;
    *) echo "Unsupported architecture: $(uname -m)"; exit 1 ;;
  esac

  DL_URL="$(curl -s https://api.github.com/repos/wangyu-/udp2raw/releases/latest \
    | jq -r '.assets[] | select(.name | test("binaries")) | .browser_download_url' | head -1)"
  if [[ -z "$DL_URL" ]]; then
    echo "ERROR: could not find a udp2raw release asset (network issue, or GitHub API rate limit)."
    exit 1
  fi

  TMP=$(mktemp -d)
  if ! wget -qO "$TMP/udp2raw.tar.gz" "$DL_URL"; then
    echo "ERROR: udp2raw download failed."
    rm -rf "$TMP"
    exit 1
  fi
  tar -xzf "$TMP/udp2raw.tar.gz" -C "$TMP"
  # exact name, not a wildcard: the release also ships _hw_aes/_asm_aes
  # variants (e.g. udp2raw_amd64_hw_aes) that need AES-NI CPU support not
  # guaranteed on every VPS -- a wildcard match could grab one of those
  # non-deterministically instead of the plain, universally-compatible binary.
  FOUND_BIN="$(find "$TMP" -iname "udp2raw_${ARCH_PATTERN}" -type f | head -1)"
  if [[ -z "$FOUND_BIN" ]]; then
    echo "ERROR: no matching udp2raw binary for architecture ${ARCH_PATTERN} in the release archive."
    rm -rf "$TMP"
    exit 1
  fi
  cp "$FOUND_BIN" "$BIN"
  chmod +x "$BIN"
  rm -rf "$TMP"
fi

[[ -f "$KEY_FILE" ]] || LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 24 > "$KEY_FILE"
chmod 600 "$KEY_FILE"

write_unit
systemctl daemon-reload
systemctl enable vpn-udpcustom >/dev/null 2>&1 || true
systemctl restart vpn-udpcustom

sleep 1
if ! systemctl is-active --quiet vpn-udpcustom; then
  echo "ERROR: vpn-udpcustom failed to start. Check: journalctl -u vpn-udpcustom -n 30 --no-pager"
  exit 1
fi

iptables_rule -A
netfilter-persistent save >/dev/null 2>&1 || iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

touch "$FLAG"
echo "SSH UDP Custom ENABLED."
echo "  Public UDP ports 1-65535 (except 53/443/1194/51820, already used"
echo "  elsewhere in this stack) are forwarded into the tunnel over UDP."
echo "  Shared key: $(cat "$KEY_FILE")  (client's udp2raw must use the SAME key)"

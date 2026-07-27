#!/bin/bash
# VPN-Starter-Kit :: menu/generate-xray-config.sh
# Reprint an existing Xray user's full account card (e.g. the original
# card was lost) — rebuilds the exact same links add-user.sh would, from
# the id/password already stored in config.json (no extra persistence
# needed here, unlike SSH's password).
# Usage: generate-xray-config.sh <vless|vmess|trojan|shadowsocks> [username]
#   No username: interactive (lists accounts, then prompts) -- the bash
#   menu's call path, unchanged.
#   With a username: non-interactive, for the web admin panel.
set -uo pipefail

CONFIG="/usr/local/etc/xray/config.json"
PROTOCOL="${1:-}"
DOMAIN_FILE="/etc/vpn-script/domain"

case "$PROTOCOL" in
  vless|vmess|trojan|shadowsocks) ;;
  *) echo "Usage: generate-xray-config.sh <vless|vmess|trojan|shadowsocks>"; exit 1 ;;
esac

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."; exit 1
fi
if [[ ! -f "$CONFIG" ]]; then
  echo "Error: Xray config not found at $CONFIG"
  exit 1
fi

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../core" && pwd)/xray-links.sh"

# dedupe: vmess/vless/trojan each have a WS + gRPC inbound sharing one
# client list, so without unique the same email would be listed twice.
mapfile -t USERS < <(jq -r --arg p "$PROTOCOL" '
  [.inbounds[] | select(.protocol==$p) | .settings.clients[].email] | unique[]
' "$CONFIG" 2>/dev/null)

NAME="${2:-}"
if [[ -z "$NAME" ]]; then
  echo ""
  echo "Current $PROTOCOL users:"
  if [[ ${#USERS[@]} -eq 0 ]]; then
    echo "  (none)"; exit 1
  fi
  for u in "${USERS[@]}"; do echo "  - ${u%%_*}   (expires ${u#*_})"; done

  echo ""
  read -rp "Enter username to generate config for: " NAME
fi

MATCH=""
for u in "${USERS[@]}"; do
  if [[ "${u%%_*}" == "$NAME" ]]; then MATCH="$u"; break; fi
done
if [[ -z "$MATCH" ]]; then
  echo "No $PROTOCOL user named '$NAME'."; exit 1
fi
EXPIRY="${MATCH#*_}"

CLIENT_JSON="$(jq -c --arg p "$PROTOCOL" --arg email "$MATCH" '
  [.inbounds[] | select(.protocol==$p) | .settings.clients[] | select(.email==$email)][0]
' "$CONFIG")"

HOSTNAME_VAL="$(cat "$DOMAIN_FILE" 2>/dev/null)"
[[ -z "$HOSTNAME_VAL" ]] && HOSTNAME_VAL="$(curl -s https://api.ipify.org || hostname -I | awk '{print $1}')"

case "$PROTOCOL" in
vmess)
  ID="$(echo "$CLIENT_JSON" | jq -r '.id')"
  LINK_TLS="$(vmess_link "$NAME" "$HOSTNAME_VAL" "443" "$ID" "ws" "/vmess" "tls")"
  LINK_PLAIN="$(vmess_link "$NAME" "$HOSTNAME_VAL" "80" "$ID" "ws" "/vmess" "")"
  LINK_GRPC="$(vmess_link "$NAME" "$HOSTNAME_VAL" "443" "$ID" "grpc" "vmess-grpc" "tls")"

  cat <<CARD
====================================
   Xray/Vmess Account
====================================
Remarks       : ${NAME}
Domain        : ${HOSTNAME_VAL}
Port TLS      : 443
Port none TLS : 80
Port GRPC     : 443
id            : ${ID}
alterId       : 0
Security      : auto
Network       : ws
Path          : /vmess
ServiceName   : vmess-grpc
====================================
Link TLS      : ${LINK_TLS}
====================================
Link none TLS : ${LINK_PLAIN}
====================================
Link GRPC     : ${LINK_GRPC}
====================================
Expired On    : ${EXPIRY}
====================================
CARD
  ;;
vless)
  ID="$(echo "$CLIENT_JSON" | jq -r '.id')"
  LINK_TLS="$(vless_link "$NAME" "$HOSTNAME_VAL" "443" "$ID" "ws" "/vless" "tls")"
  LINK_PLAIN="$(vless_link "$NAME" "$HOSTNAME_VAL" "80" "$ID" "ws" "/vless" "none")"
  LINK_GRPC="$(vless_link "$NAME" "$HOSTNAME_VAL" "443" "$ID" "grpc" "vless-grpc" "tls")"

  cat <<CARD
====================================
   Xray/Vless Account
====================================
Remarks       : ${NAME}
Domain        : ${HOSTNAME_VAL}
Port TLS      : 443
Port none TLS : 80
Port GRPC     : 443
id            : ${ID}
Encryption    : none
Network       : ws
Path          : /vless
ServiceName   : vless-grpc
====================================
Link TLS      : ${LINK_TLS}
====================================
Link none TLS : ${LINK_PLAIN}
====================================
Link GRPC     : ${LINK_GRPC}
====================================
Expired On    : ${EXPIRY}
====================================
CARD
  ;;
trojan)
  PASSWORD="$(echo "$CLIENT_JSON" | jq -r '.password')"
  LINK_TLS="$(trojan_link "$NAME" "$HOSTNAME_VAL" "443" "$PASSWORD" "ws" "/trojan")"
  LINK_GRPC="$(trojan_link "$NAME" "$HOSTNAME_VAL" "443" "$PASSWORD" "grpc" "trojan-grpc")"

  cat <<CARD
====================================
   Xray/Trojan Account
====================================
Remarks       : ${NAME}
Domain        : ${HOSTNAME_VAL}
Port TLS      : 443
Port GRPC     : 443
password      : ${PASSWORD}
Network       : ws
Path          : /trojan
ServiceName   : trojan-grpc
====================================
Link TLS      : ${LINK_TLS}
====================================
Link GRPC     : ${LINK_GRPC}
====================================
Expired On    : ${EXPIRY}
====================================
CARD
  ;;
shadowsocks)
  METHOD="$(echo "$CLIENT_JSON" | jq -r '.method')"
  PASSWORD="$(echo "$CLIENT_JSON" | jq -r '.password')"
  LINK="$(ss_link "$NAME" "$HOSTNAME_VAL" "8388" "$METHOD" "$PASSWORD")"

  cat <<CARD
====================================
   Xray/Shadowsocks Account
====================================
Remarks       : ${NAME}
Domain        : ${HOSTNAME_VAL}
Port          : 8388
Method        : ${METHOD}
password      : ${PASSWORD}
====================================
Link          : ${LINK}
====================================
Expired On    : ${EXPIRY}
====================================
CARD
  ;;
esac

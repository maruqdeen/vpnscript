#!/bin/bash
# VPN-Starter-Kit :: menu/menu-xray.sh
# Shared submenu for Xray protocols. Usage: menu-xray.sh <vmess|vless>
set -uo pipefail

BASE="/etc/vpn-script/menu"
PROTO="${1:-}"

if [[ $EUID -ne 0 ]]; then echo "Run as root."; exit 1; fi
if [[ "$PROTO" != "vmess" && "$PROTO" != "vless" ]]; then
  echo "Usage: menu-xray.sh <vmess|vless>"; exit 1
fi

PROTO_UP="$(echo "$PROTO" | tr '[:lower:]' '[:upper:]')"

# colors
BL=$'\e[38;5;111m'; Y=$'\e[33m'; X=$'\e[0m'

pause() { read -rp $'\nPress Enter to continue...' _; }

while true; do
  clear
  echo ""
  printf "  ${BL}[01]${X} Create XRAY ${PROTO_UP} WS\n"
  printf "  ${BL}[02]${X} Trial XRAY ${PROTO_UP} WS\n"
  printf "  ${BL}[03]${X} Extending XRAY ${PROTO_UP} WS Active\n"
  printf "  ${BL}[04]${X} Delete XRAY ${PROTO_UP} WS\n"
  printf "  ${BL}[05]${X} Check User Login XRAY ${PROTO_UP} WS\n"
  echo ""
  printf "  ${BL}└"; printf '─%.0s' {1..48}; printf "┘${X}\n"
  echo ""
  printf "  ${Y}[00]${X} Main Menu\n"
  echo ""
  read -rp " Select menu : " opt

  case "$opt" in
    1|01) bash "$BASE/add-user.sh" "$PROTO" ; pause ;;
    3|03) bash "$BASE/renew-user.sh" ; pause ;;
    4|04) bash "$BASE/del-user.sh" ; pause ;;

    2|02) echo "Trial account — not built yet."; pause ;;
    5|05) echo "Check user login — not built yet."; pause ;;

    0|00) exit 0 ;;
    *) echo "Invalid option."; sleep 1 ;;
  esac
done


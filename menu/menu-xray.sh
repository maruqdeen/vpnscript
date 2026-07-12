#!/bin/bash
# VPN-Starter-Kit :: menu/menu-xray.sh
# Shared submenu for Xray protocols: vmess, vless, trojan — all three have
# a working backend (Xray inbound + nginx route).
# Usage: menu-xray.sh <vmess|vless|trojan>
set -uo pipefail

BASE="/etc/vpn-script/menu"
PROTO="${1:-}"

if [[ $EUID -ne 0 ]]; then echo "Run as root."; exit 1; fi
case "$PROTO" in
  vmess|vless|trojan) ;;
  *) echo "Usage: menu-xray.sh <vmess|vless|trojan>"; exit 1 ;;
esac

PROTO_UP="$(echo "$PROTO" | tr '[:lower:]' '[:upper:]')"
PROTO_DISPLAY="${PROTO^}"

# colors
BL=$'\e[38;5;111m'; Y=$'\e[33m'; X=$'\e[0m'

pause() { read -rp $'\nPress Enter to continue...' _; }

center() {
  local text="$1" width=52 pad
  pad=$(( (width - ${#text}) / 2 ))
  (( pad < 0 )) && pad=0
  printf "%${pad}s%s\n" "" "$text"
}

while true; do
  clear
  echo ""
  printf '%s\n' "===================================================="
  center "XRAY ${PROTO_UP} MANAGER"
  printf '%s\n' "===================================================="
  echo ""
  printf "  ${BL}[01]${X} Create XRAY ${PROTO_DISPLAY} Acc\n"
  printf "  ${BL}[02]${X} Create XRAY ${PROTO_DISPLAY} Trial Acc\n"
  printf "  ${BL}[03]${X} Extending XRAY ${PROTO_DISPLAY} User Acc\n"
  printf "  ${BL}[04]${X} Delete XRAY ${PROTO_DISPLAY} WS User Acc\n"
  printf "  ${BL}[05]${X} Check Active User using XRAY ${PROTO_DISPLAY}\n"
  echo ""
  printf "  ${Y}[00]${X} Main Menu\n"
  echo ""
  read -rp " Select menu : " opt

  case "$opt" in
    1|01) bash "$BASE/add-user.sh" "$PROTO" ; pause ;;
    3|03) bash "$BASE/renew-user.sh" "$PROTO" ; pause ;;
    4|04) bash "$BASE/del-user.sh" "$PROTO" ; pause ;;

    2|02)
      case "$PROTO" in
        vmess)  bash "$BASE/trial-vmess-user.sh" ;;
        vless)  bash "$BASE/trial-vless-user.sh" ;;
        trojan) bash "$BASE/trial-trojan-user.sh" ;;
      esac
      pause ;;
    5|05) bash "$BASE/check-xray-user.sh" "$PROTO" ; pause ;;

    0|00) exit 0 ;;
    *) echo "Invalid option."; sleep 1 ;;
  esac
done

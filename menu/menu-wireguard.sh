#!/bin/bash
# VPN-Starter-Kit :: menu/menu-wireguard.sh
# WireGuard submenu. Unlike the Xray protocols (vless/vmess/trojan),
# WireGuard is a separate kernel-level UDP service — no nginx routing, no
# Xray inbound. The server bootstraps itself lazily the first time an
# account is created (see core/wireguard.sh).
set -uo pipefail

BASE="/etc/vpn-script/menu"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."; exit 1
fi

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
  center "WIREGUARD MANAGER"
  printf '%s\n' "===================================================="
  echo ""
  printf "  ${BL}[01]${X} Create Wireguard Acc\n"
  printf "  ${BL}[02]${X} Renew Wireguard Acc\n"
  printf "  ${BL}[03]${X} Delete Wireguard Acc\n"
  printf "  ${BL}[04]${X} List Wireguard Acc\n"
  printf "  ${BL}[05]${X} Check Active Wireguard User\n"
  echo ""
  printf "  ${Y}[00]${X} Main Menu\n"
  echo ""
  read -rp " Select menu : " opt

  case "$opt" in
    1|01) bash "$BASE/add-wireguard-user.sh" ; pause ;;
    2|02) bash "$BASE/renew-wireguard-user.sh" ; pause ;;
    3|03) bash "$BASE/del-wireguard-user.sh" ; pause ;;
    4|04) bash "$BASE/list-wireguard-user.sh" ; pause ;;
    5|05) bash "$BASE/check-wireguard-user.sh" ; pause ;;
    0|00) exit 0 ;;
    *) echo "Invalid option."; sleep 1 ;;
  esac
done

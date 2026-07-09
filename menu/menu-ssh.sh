#!/bin/bash
# VPN-Starter-Kit :: menu/menu-ssh.sh
# SSH / DNS submenu (one account covers SSH-WS + SlowDNS).
set -uo pipefail

BASE="/etc/vpn-script/menu"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."; exit 1
fi

# colors
BL=$'\e[38;5;111m'; Y=$'\e[33m'; G=$'\e[32m'; D=$'\e[2m'; X=$'\e[0m'

pause() { read -rp $'\nPress Enter to continue...' _; }
todo()  { echo "This feature isn't built yet."; }

while true; do
  clear
  echo ""
  printf "  ${BL}[01]${X} Create SSH WS\n"
  printf "  ${BL}[02]${X} Trial SSH WS\n"
  printf "  ${BL}[03]${X} Renew SSH WS\n"
  printf "  ${BL}[04]${X} Delete SSH WS\n"
  printf "  ${BL}[05]${X} Check User Login SSH WS\n"
  printf "  ${BL}[06]${X} List Member SSH WS\n"
  printf "  ${BL}[07]${X} Delete User Expired SSH WS\n"
  printf "  ${BL}[08]${X} Set up Autokill SSH WS\n"
  printf "  ${BL}[09]${X} Cek Users Multi Login SSH WS\n"
  echo ""
  printf "  ${BL}└"; printf '─%.0s' {1..48}; printf "┘${X}\n"
  echo ""
  printf "  ${Y}[00]${X} Main Menu\n"
  echo ""
  read -rp " Select menu : " opt

  case "$opt" in
    1|01) bash "$BASE/add-ssh-user.sh" ; pause ;;
    2|02) bash "$BASE/trial-ssh-user.sh" ; pause ;;
    3|03) bash "$BASE/renew-user.sh" ; pause ;;
    4|04) bash "$BASE/del-user.sh" ; pause ;;
    5|05) bash "$BASE/check-login.sh" ; pause ;;
    6|06) bash "$BASE/list-users.sh" ; pause ;;
    8|08) bash "$BASE/autokill-setup.sh" ; pause ;;
    9|09) bash "$BASE/multilogin-check.sh" ; pause ;;

    7|07) echo "Delete expired — not built yet."; pause ;;

    0|00) exit 0 ;;
    *) echo "Invalid option."; sleep 1 ;;
  esac
done


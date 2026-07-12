#!/bin/bash
# VPN-Starter-Kit :: menu/menu-ssh.sh
# SSH / DNS submenu (one account covers SSH-WS + SlowDNS).
set -uo pipefail

BASE="/etc/vpn-script/menu"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."; exit 1
fi

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
  center "SSH & DNS MANAGER"
  printf '%s\n' "===================================================="
  echo ""
  printf "  ${BL}[01]${X} Create User Acc\n"
  printf "  ${BL}[02]${X} Create Trial Acc\n"
  printf "  ${BL}[03]${X} Renew User Acc\n"
  printf "  ${BL}[04]${X} Delete User Acc\n"
  printf "  ${BL}[05]${X} Check Active Users\n"
  printf "  ${BL}[06]${X} List created User Acc\n"
  printf "  ${BL}[07]${X} Set up Autokill Multi Login\n"
  printf "  ${BL}[08]${X} Check Locked Users\n"
  echo ""
  printf "  ${Y}[00]${X} Main Menu\n"
  echo ""
  read -rp " Select menu : " opt

  case "$opt" in
    1|01) bash "$BASE/add-ssh-user.sh" ; pause ;;
    2|02) bash "$BASE/trial-ssh-user.sh" ; pause ;;
    3|03) bash "$BASE/renew-user.sh" ssh ; pause ;;
    4|04) bash "$BASE/del-user.sh" ssh ; pause ;;
    5|05) bash "$BASE/check-login.sh" ; pause ;;
    6|06) bash "$BASE/list-users.sh" ; pause ;;
    7|07) bash "$BASE/autokill-setup.sh" ; pause ;;
    8|08) bash "$BASE/check-locked-users.sh" ; pause ;;

    0|00) exit 0 ;;
    *) echo "Invalid option."; sleep 1 ;;
  esac
done

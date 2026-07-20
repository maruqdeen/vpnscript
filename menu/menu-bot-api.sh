#!/bin/bash
# VPN-Starter-Kit :: menu/menu-bot-api.sh
# Bot & Api Setup submenu. TelegramBot is live; Web Api is still a menu
# shell only — functionality intentionally not implemented yet, per
# explicit instruction to hold off until the exact behavior is specified.
set -uo pipefail

if [[ $EUID -ne 0 ]]; then echo "Run as root."; exit 1; fi

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
  center "BOT & API SETUP"
  printf '%s\n' "===================================================="
  echo ""
  printf "  ${BL}[1]${X} Connect to TelegramBot\n"
  printf "  ${BL}[2]${X} Setup Web Api\n"
  echo ""
  printf "  ${Y}[0]${X} Main Menu\n"
  echo ""
  read -rp " Select menu : " opt

  case "$opt" in
    1) bash "$BASE/telegram-bot-setup.sh" ; pause ;;
    2) echo "Setup Web Api — not built yet." ; pause ;;
    0) exit 0 ;;
    *) echo "Invalid option."; sleep 1 ;;
  esac
done

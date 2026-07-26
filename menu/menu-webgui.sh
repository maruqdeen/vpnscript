#!/bin/bash
# VPN-Starter-Kit :: menu/menu-webgui.sh
# WebGui submenu -- installs/manages Webmin (webmin.com), a full
# browser-based server control panel, as a companion to this text menu.
set -uo pipefail

BASE="/etc/vpn-script/menu"
CORE_DIR="/etc/vpn-script/core"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."; exit 1
fi

BL=$'\e[38;5;111m'; Y=$'\e[33m'; G=$'\e[32m'; R=$'\e[31m'; X=$'\e[0m'

pause() { read -rp $'\nPress Enter to continue...' _; }

center() {
  local text="$1" width=52 pad
  pad=$(( (width - ${#text}) / 2 ))
  (( pad < 0 )) && pad=0
  printf "%${pad}s%s\n" "" "$text"
}

status_line() {
  if command -v webmin >/dev/null 2>&1 || dpkg -s webmin >/dev/null 2>&1; then
    printf "%sInstalled%s" "$G" "$X"
  else
    printf "%sNot Installed%s" "$R" "$X"
  fi
}

while true; do
  clear
  echo ""
  printf '%s\n' "===================================================="
  center "WEBGUI MENU"
  printf '%s\n' "===================================================="
  echo ""
  printf "Status : %b\n" "$(status_line)"
  echo ""
  printf "  ${BL}[1]${X} Install WebGui\n"
  printf "  ${BL}[2]${X} Restart WebGui\n"
  printf "  ${BL}[3]${X} Uninstall WebGui\n"
  echo ""
  printf "  ${Y}[0]${X} Back to Menu\n"
  echo ""
  read -rp " Select menu : " opt

  case "$opt" in
    1) bash "$CORE_DIR/webmin.sh" install ; pause ;;
    2) bash "$CORE_DIR/webmin.sh" restart ; pause ;;
    3) bash "$CORE_DIR/webmin.sh" uninstall ; pause ;;
    0) exit 0 ;;
    *) echo "Invalid option."; sleep 1 ;;
  esac
done

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

admin_panel_status_line() {
  if [[ -f "/etc/vpn-script/admin-panel.enabled" ]]; then
    printf "%sEnabled%s" "$G" "$X"
  else
    printf "%sDisabled%s" "$R" "$X"
  fi
}

while true; do
  clear
  echo ""
  printf '%s\n' "===================================================="
  center "WEBGUI MENU"
  printf '%s\n' "===================================================="
  echo ""
  printf "Webmin Status       : %b\n" "$(status_line)"
  printf "Admin Panel Status  : %b\n" "$(admin_panel_status_line)"
  echo ""
  printf "  ${BL}[1]${X} Install WebGui\n"
  printf "  ${BL}[2]${X} Restart WebGui\n"
  printf "  ${BL}[3]${X} Uninstall WebGui\n"
  printf "  ${BL}[4]${X} Setup Admin Panel\n"
  echo ""
  printf "  ${Y}[0]${X} Back to Menu\n"
  echo ""
  read -rp " Select menu : " opt

  case "$opt" in
    1) bash "$CORE_DIR/webmin.sh" install ; pause ;;
    2) bash "$CORE_DIR/webmin.sh" restart ; pause ;;
    3) bash "$CORE_DIR/webmin.sh" uninstall ; pause ;;
    4)
      if [[ -f "/etc/vpn-script/admin-panel.enabled" ]]; then
        echo "Admin Panel is currently ENABLED."
        echo "  [1] Disable"
        echo "  [0] Back"
        read -rp "Choose: " sub
        case "$sub" in
          1) bash "$CORE_DIR/admin-panel-setup.sh" disable ;;
        esac
      else
        bash "$CORE_DIR/admin-panel-setup.sh" enable
      fi
      pause ;;
    0) exit 0 ;;
    *) echo "Invalid option."; sleep 1 ;;
  esac
done

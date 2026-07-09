#!/bin/bash
# VPN-Starter-Kit :: menu/menu-settings.sh
# Settings submenu — Restart All Services + SSH banner editor (both functional).
set -uo pipefail

if [[ $EUID -ne 0 ]]; then echo "Run as root."; exit 1; fi

BANNER_FILE="/etc/vpn-script/banner.txt"

# colors
BL=$'\e[38;5;111m'; Y=$'\e[33m'; G=$'\e[32m'; X=$'\e[0m'

pause() { read -rp $'\nPress Enter to continue...' _; }

restart_all() {
  echo ">>> Restarting all services..."
  for u in xray nginx dropbear ws-proxy slowdns; do
    if systemctl restart "$u" 2>/dev/null; then
      printf "  %s%s%s restarted\n" "$G" "$u" "$X"
    else
      printf "  %s could not restart\n" "$u"
    fi
  done
}

edit_banner() {
  echo "Current SSH banner:"
  echo "-----------------------------------"
  cat "$BANNER_FILE" 2>/dev/null || echo "(none set)"
  echo "-----------------------------------"
  echo ""
  echo "Enter new banner text. Finish with a single '.' on its own line:"
  local tmp; tmp="$(mktemp)"
  while IFS= read -r ln; do
    [[ "$ln" == "." ]] && break
    echo "$ln" >> "$tmp"
  done
  mv "$tmp" "$BANNER_FILE"
  # apply to Dropbear (it reads a banner file via -b)
  if grep -q 'DROPBEAR_BANNER' /etc/default/dropbear 2>/dev/null; then
    sed -i "s|^DROPBEAR_BANNER=.*|DROPBEAR_BANNER=\"$BANNER_FILE\"|" /etc/default/dropbear
  else
    echo "DROPBEAR_BANNER=\"$BANNER_FILE\"" >> /etc/default/dropbear
  fi
  systemctl restart dropbear 2>/dev/null || true
  echo "Banner updated and applied to Dropbear."
}

while true; do
  clear
  echo ""
  printf "  ${BL}[01]${X} Restart All Services\n"
  printf "  ${BL}[02]${X} Set / Edit SSH Banner\n"
  echo ""
  printf "  ${BL}└"; printf '─%.0s' {1..48}; printf "┘${X}\n"
  echo ""
  printf "  ${Y}[00]${X} Main Menu\n"
  echo ""
  read -rp " Select menu : " opt

  case "$opt" in
    1|01) restart_all ; pause ;;
    2|02) edit_banner ; pause ;;
    0|00) exit 0 ;;
    *) echo "Invalid option."; sleep 1 ;;
  esac
done


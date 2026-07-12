#!/bin/bash
# VPN-Starter-Kit :: menu/menu-security.sh
# Security Mgt submenu.
set -uo pipefail

if [[ $EUID -ne 0 ]]; then echo "Run as root."; exit 1; fi

INSTALL_DIR="/etc/vpn-script"
CORE_DIR="$INSTALL_DIR/core"

# colors
BL=$'\e[38;5;111m'; Y=$'\e[33m'; X=$'\e[0m'

pause() { read -rp $'\nPress Enter to continue...' _; }

center() {
  local text="$1" width=52 pad
  pad=$(( (width - ${#text}) / 2 ))
  (( pad < 0 )) && pad=0
  printf "%${pad}s%s\n" "" "$text"
}

# ---- [1] Fail2ban ----
toggle_fail2ban() {
  if [[ -f "$INSTALL_DIR/fail2ban.enabled" ]]; then
    echo "Fail2ban (OpenSSH brute-force protection): ENABLED"
  else
    echo "Fail2ban (OpenSSH brute-force protection): DISABLED (default)"
  fi
  echo ""
  echo "  [1] Enable"
  echo "  [2] Disable"
  echo "  [0] Back"
  read -rp "Choose: " opt
  case "$opt" in
    1) bash "$CORE_DIR/fail2ban.sh" enable ;;
    2) bash "$CORE_DIR/fail2ban.sh" disable ;;
    0) return ;;
    *) echo "Invalid option." ;;
  esac
}

# ---- [2] Anti-Torrent ----
toggle_anti_torrent() {
  if [[ -f "$INSTALL_DIR/anti-torrent.enabled" ]]; then
    echo "Anti-Torrent filtering: ENABLED"
  else
    echo "Anti-Torrent filtering: DISABLED (default)"
  fi
  echo "(heuristic string-match on the FORWARD chain — VPN client traffic only)"
  echo ""
  echo "  [1] Enable"
  echo "  [2] Disable"
  echo "  [0] Back"
  read -rp "Choose: " opt
  case "$opt" in
    1) bash "$CORE_DIR/anti-torrent.sh" enable ;;
    2) bash "$CORE_DIR/anti-torrent.sh" disable ;;
    0) return ;;
    *) echo "Invalid option." ;;
  esac
}

# ---- [3] DDoS Protection ----
toggle_ddos() {
  if [[ -f "$INSTALL_DIR/ddos-protection.enabled" ]]; then
    echo "DDoS Protection: ENABLED"
  else
    echo "DDoS Protection: DISABLED (default)"
  fi
  echo "(SYN cookies + generous rate limiting — tuned for this box's normal"
  echo " bursty multi-protocol traffic, not a hard per-IP connection cap)"
  echo ""
  echo "  [1] Enable"
  echo "  [2] Disable"
  echo "  [0] Back"
  read -rp "Choose: " opt
  case "$opt" in
    1) bash "$CORE_DIR/ddos-protection.sh" enable ;;
    2) bash "$CORE_DIR/ddos-protection.sh" disable ;;
    0) return ;;
    *) echo "Invalid option." ;;
  esac
}

# ---- [4] Clean All Expired User ----
toggle_clean_expired() {
  if [[ -f "$INSTALL_DIR/clean-expired.enabled" ]]; then
    echo "Clean All Expired User: ENABLED (default) — daily sweep at 00:30"
  else
    echo "Clean All Expired User: DISABLED"
  fi
  echo "(deletes SSH/Xray/WireGuard accounts past their expiry date)"
  echo ""
  echo "  [1] Enable"
  echo "  [2] Disable"
  echo "  [3] Run now"
  echo "  [0] Back"
  read -rp "Choose: " opt
  case "$opt" in
    1) bash "$CORE_DIR/clean-expired.sh" enable ;;
    2) bash "$CORE_DIR/clean-expired.sh" disable ;;
    3) bash "$CORE_DIR/clean-expired.sh" run ;;
    0) return ;;
    *) echo "Invalid option." ;;
  esac
}

while true; do
  clear
  echo ""
  printf '%s\n' "===================================================="
  center "SECURITY MANAGER"
  printf '%s\n' "===================================================="
  echo ""
  printf "  ${BL}[1]${X} Setup Fail2ban\n"
  printf "  ${BL}[2]${X} Setup Anti-Torrent\n"
  printf "  ${BL}[3]${X} DDOS Protection\n"
  printf "  ${BL}[4]${X} Clean All Expired User\n"
  echo ""
  printf "  ${Y}[0]${X} Main Menu\n"
  echo ""
  read -rp " Select menu : " opt

  case "$opt" in
    1) toggle_fail2ban ; pause ;;
    2) toggle_anti_torrent ; pause ;;
    3) toggle_ddos ; pause ;;
    4) toggle_clean_expired ; pause ;;
    0) exit 0 ;;
    *) echo "Invalid option."; sleep 1 ;;
  esac
done

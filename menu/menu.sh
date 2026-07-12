#!/bin/bash
# VPN-Starter-Kit :: menu/menu.sh
# Main interactive dashboard. Installed path: /etc/vpn-script/menu/menu.sh
# Reached globally by the `menu` command.
set -uo pipefail

BASE="/etc/vpn-script/menu"
INSTALL_DIR="/etc/vpn-script"
XRAY_CONFIG="/usr/local/etc/xray/config.json"

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root:  sudo menu"
  exit 1
fi

source "$BASE/lib-ssh-users.sh"
source "$INSTALL_DIR/core/wireguard.sh"
source "$INSTALL_DIR/core/bandwidth.sh"

# ---- colors ----
G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; C=$'\e[36m'; B=$'\e[1m'; D=$'\e[2m'; X=$'\e[0m'

pause() { read -rp $'\nPress Enter to return to menu...' _; }

# ---- helpers for the header ----
svc() {
  # svc <unit> <label>  -> prints "Label: Active|Inactive" colored
  local unit="$1" label="$2"
  if systemctl is-active --quiet "$unit" 2>/dev/null; then
    printf "%s: %sActive%s" "$label" "$G" "$X"
  else
    printf "%s: %sInactive%s" "$label" "$R" "$X"
  fi
}

# Fixed total width (51, matching the plain bottom divider), title
# centered — NOT a fixed equals-count on each side, which is what made
# every section header a different overall length before (title length
# varied, so the total line length varied right along with it).
line() {
  local title="$1" width=51 pad_total left right
  pad_total=$(( width - ${#title} - 2 ))
  (( pad_total < 0 )) && pad_total=0
  left=$(( pad_total / 2 ))
  right=$(( pad_total - left ))
  printf '%s %s %s\n' "$(printf '=%.0s' $(seq 1 "$left"))" "$title" "$(printf '=%.0s' $(seq 1 "$right"))"
}

# count_xray <protocol> -> number of clients configured for that inbound (0 if absent)
count_xray() {
  # vmess/vless/trojan each have a WS + gRPC inbound sharing one client
  # list, so counting raw clients across .inbounds[] double-counts every
  # account; dedupe by email first.
  jq -r --arg p "$1" '[.inbounds[]? | select(.protocol==$p) | .settings.clients[]?.email] | unique | length' \
    "$XRAY_CONFIG" 2>/dev/null || echo 0
}

draw_header() {
  clear

  # --- SERVER INFO ---
  local uptime_str ip os ram_used ram_total cpu domain nsdomain
  uptime_str="$(uptime -p 2>/dev/null | sed 's/^up //')"
  [[ -z "$uptime_str" ]] && uptime_str="n/a"
  ip="$(curl -s --max-time 3 https://api.ipify.org || hostname -I | awk '{print $1}')"
  os="$( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Unknown}" ) ( $(uname -m) )"
  ram_total="$(free -m | awk '/^Mem:/{print $2}')"
  ram_used="$(free -m | awk '/^Mem:/{print $3}')"
  cpu="$(top -bn1 | awk '/Cpu\(s\)/{printf "%.0f", $2+$4}')"
  domain="$(cat "$INSTALL_DIR/domain" 2>/dev/null)";      [[ -z "$domain" ]]   && domain="(not set)"
  nsdomain="$(cat "$INSTALL_DIR/ns-domain" 2>/dev/null)"; [[ -z "$nsdomain" ]] && nsdomain="(not set)"
  local reboot_status
  if [[ -f "$INSTALL_DIR/autoreboot.enabled" ]]; then
    reboot_status="Daily $(cat "$INSTALL_DIR/autoreboot.time" 2>/dev/null || echo '?')"
  else
    reboot_status="Not set"
  fi

  line "SERVER INFO"
  echo ""
  printf "Server Uptime      = %s\n" "$uptime_str"
  printf "Server IP          = %s%s%s\n" "$C" "$ip" "$X"
  printf "Operating System   = %s\n" "$os"
  printf "Cloudflare Domain  = %s%s%s\n" "$C" "$domain" "$X"
  printf "NS Domain          = %s%s%s\n" "$C" "$nsdomain" "$X"
  printf "Ram Usage          = %s MB / %s MB\n" "$ram_used" "$ram_total"
  printf "CPU Usage          = %s %%\n" "$cpu"
  printf "Time Reboot VPS    = %s%s%s\n" "$D" "$reboot_status" "$X"

  # --- ACTIVE SERVICE ---
  echo ""
  line "ACTIVE SERVICE"
  echo ""
  printf "  %s | %s | %s\n" "$(svc ssh SSH)" "$(svc nginx Nginx)" "$(svc dropbear Dropbear)"
  printf "  %s | %s | %s\n" "$(svc slowdns Slowdns)" "$(svc xray Xray)" "$(svc ws-proxy SSH-WS)"
  printf "  %s | %s | %s\n" "$(svc vpn-haproxy HAProxy)" "$(svc vpn-sslh SSLH)" "$(svc vpn-badvpn BadVPN)"
  printf "  %s | %s | %s\n" "$(svc openvpn@vpn-tcp1194 OVPN-TCP)" "$(svc openvpn@vpn-udp1194 OVPN-UDP)" "$(svc squid Proxy)"

  # --- ACTIVE ACCOUNT ---
  local ssh_count vmess_count vless_count trojan_count wg_count
  ssh_count="$(ssh_user_list | grep -c .)"
  vmess_count="$(count_xray vmess)"
  vless_count="$(count_xray vless)"
  trojan_count="$(count_xray trojan)"
  wg_count="$(jq 'length' "$WG_CLIENTS_JSON" 2>/dev/null || echo 0)"

  echo ""
  line "ACTIVE ACCOUNT"
  echo ""
  printf "  SSH : %s | Vmess: %s | Vless: %s | Trojan: %s | Wireguard: %s\n" \
    "$ssh_count" "$vmess_count" "$vless_count" "$trojan_count" "$wg_count"

  # --- CONTROL MANAGER ---
  echo ""
  line "CONTROL MANAGER"
  echo ""
}

while true; do
  draw_header

  # two-column menu
  printf "  ${B}[1]${X} SSH / DNS Menu       ${B}[6]${X}  Settings\n"
  printf "  ${B}[2]${X} VMess Menu           ${B}[7]${X}  Running Service\n"
  printf "  ${B}[3]${X} VLESS Menu           ${B}[8]${X}  Bot & Api Setup\n"
  printf "  ${B}[4]${X} Trojan Menu          ${B}[9]${X}  Security Mgt\n"
  printf "  ${B}[5]${X} Wireguard Menu       ${B}[10]${X} WebMin\n"
  echo ""
  printf "  ${B}[0]${X} Exit\n"
  echo ""

  # --- BANDWITH USAGE ---
  bw_iface="$(bw_ensure)"
  read -r bw_today_b bw_yesterday_b < <(bw_day_stats "$bw_iface")
  bw_month_b="$(bw_month_bytes "$bw_iface")"

  line "BANDWITH USAGE"
  echo ""
  printf "Bandwidth  Used Today      = %s\n" "$(_bw_human "$bw_today_b")"
  printf "Bandwidth  Used yesterday  = %s\n" "$(_bw_human "$bw_yesterday_b")"
  printf "Total Bandwith Used in a Month = %s\n" "$(_bw_human "$bw_month_b")"
  echo ""

  printf '%s\n' "==================================================="
  read -rp " Choose an option: " opt

  case "$opt" in
    1)  bash "$BASE/menu-ssh.sh" ;;
    2)  bash "$BASE/menu-xray.sh" vmess ;;
    3)  bash "$BASE/menu-xray.sh" vless ;;
    4)  bash "$BASE/menu-xray.sh" trojan ;;
    5)  bash "$BASE/menu-wireguard.sh" ;;
    6)  bash "$BASE/menu-settings.sh" ;;
    7)  systemctl --no-pager --type=service | grep -E 'xray|nginx|dropbear|ws-proxy|slowdns' ; pause ;;
    8)  echo "Bot & Api Setup — not built yet." ; pause ;;
    9)  echo "Security Mgt — not built yet." ; pause ;;
    10) echo "WebMin — not built yet." ; pause ;;
    0)  clear; exit 0 ;;
    *)  echo "Invalid option."; sleep 1 ;;
  esac
done

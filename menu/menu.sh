#!/bin/bash
# VPN-Starter-Kit :: menu/menu.sh
# Main interactive dashboard. Installed path: /etc/vpn-script/menu/menu.sh
# Reached globally by the `menu` command.
set -uo pipefail

BASE="/etc/vpn-script/menu"
INSTALL_DIR="/etc/vpn-script"

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root:  sudo menu"
  exit 1
fi

source "$BASE/lib-ssh-users.sh"

# ---- colors ----
G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; C=$'\e[36m'; B=$'\e[1m'; D=$'\e[2m'; X=$'\e[0m'

pause() { read -rp $'\nPress Enter to return to menu...' _; }

# svc_fmt <label> <true|false>  -> prints "Label: Active|Inactive" colored
svc_fmt() {
  local label="$1" active="$2"
  if [[ "$active" == "true" ]]; then
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

# Script-scope (not local) -- the main loop reuses this same snapshot for
# the BANDWITH USAGE section right after calling draw_header, so the
# expensive stats gathering (curl/free/top/jq/systemctl) only runs once
# per redraw instead of twice.
stats=""

draw_header() {
  clear

  stats="$(bash "$INSTALL_DIR/core/dashboard-stats.sh" 2>/dev/null)"
  if [[ -z "$stats" ]]; then
    echo "Error: could not load dashboard stats (core/dashboard-stats.sh)."
    return
  fi

  # --- SERVER INFO ---
  local uptime_str ip os ram_used ram_total cpu domain nsdomain reboot_status
  IFS=$'\t' read -r uptime_str ip os ram_used ram_total cpu domain nsdomain reboot_status < <(
    jq -r '[.server.uptime, .server.ip, .server.os, .server.ram_used_mb, .server.ram_total_mb, .server.cpu_pct, .server.domain, .server.ns_domain, .server.reboot_status] | @tsv' <<<"$stats"
  )

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
  local svc_ssh svc_nginx svc_dropbear svc_slowdns svc_xray svc_ws svc_ohp svc_hap svc_sslh svc_badvpn svc_ovt svc_ovu svc_proxy
  IFS=$'\t' read -r svc_ssh svc_nginx svc_dropbear svc_slowdns svc_xray svc_ws svc_ohp svc_hap svc_sslh svc_badvpn svc_ovt svc_ovu svc_proxy < <(
    jq -r '[.services.ssh, .services.nginx, .services.dropbear, .services.slowdns, .services.xray, .services["ws-proxy"], .services["ohp-proxy"], .services["vpn-haproxy"], .services["vpn-sslh"], .services["vpn-badvpn"], .services["openvpn-tcp"], .services["openvpn-udp"], .services.proxy] | @tsv' <<<"$stats"
  )

  echo ""
  line "ACTIVE SERVICE"
  echo ""
  printf "  %s | %s | %s\n" "$(svc_fmt SSH "$svc_ssh")" "$(svc_fmt Nginx "$svc_nginx")" "$(svc_fmt Dropbear "$svc_dropbear")"
  printf "  %s | %s | %s | %s\n" "$(svc_fmt Slowdns "$svc_slowdns")" "$(svc_fmt Xray "$svc_xray")" "$(svc_fmt SSH-WS "$svc_ws")" "$(svc_fmt SSH-OHP "$svc_ohp")"
  printf "  %s | %s | %s\n" "$(svc_fmt HAProxy "$svc_hap")" "$(svc_fmt SSLH "$svc_sslh")" "$(svc_fmt BadVPN "$svc_badvpn")"
  printf "  %s | %s | %s\n" "$(svc_fmt OVPN-TCP "$svc_ovt")" "$(svc_fmt OVPN-UDP "$svc_ovu")" "$(svc_fmt Proxy "$svc_proxy")"

  # --- ACTIVE ACCOUNT (Shadowsocks now included -- this line predated
  # the Shadowsocks rebuild and never counted it) ---
  local acc_ssh acc_vmess acc_vless acc_trojan acc_ss acc_wg
  IFS=$'\t' read -r acc_ssh acc_vmess acc_vless acc_trojan acc_ss acc_wg < <(
    jq -r '[.accounts.ssh, .accounts.vmess, .accounts.vless, .accounts.trojan, .accounts.shadowsocks, .accounts.wireguard] | @tsv' <<<"$stats"
  )

  echo ""
  line "ACTIVE ACCOUNT"
  echo ""
  printf "  SSH : %s | Vmess: %s | Vless: %s | Trojan: %s | SS: %s | Wireguard: %s\n" \
    "$acc_ssh" "$acc_vmess" "$acc_vless" "$acc_trojan" "$acc_ss" "$acc_wg"

  # --- CONTROL MANAGER ---
  echo ""
  line "CONTROL MANAGER"
  echo ""
}

while true; do
  draw_header

  # two-column menu
  printf "  ${B}[1]${X} Ssh|Ovpn|Dns Menu    ${B}[7]${X}  Settings\n"
  printf "  ${B}[2]${X} VMess Menu           ${B}[8]${X}  Bot & Api Setup\n"
  printf "  ${B}[3]${X} VLESS Menu           ${B}[9]${X}  Security Mgt\n"
  printf "  ${B}[4]${X} Trojan Menu          ${B}[10]${X} WebGui\n"
  printf "  ${B}[5]${X} Shadowsocks Menu     ${B}[11]${X} Backup\n"
  printf "  ${B}[6]${X} Wireguard Menu       ${B}[12]${X} Uninstall\n"
  echo ""
  printf "  ${B}[0]${X} Exit\n"
  echo ""

  # --- BANDWITH USAGE (account totals: SSH + Xray + WireGuard, not
  # whole-interface traffic — so a box with zero accounts shows 0).
  # Reuses the same $stats snapshot draw_header just fetched above,
  # rather than re-running dashboard-stats.sh's curl/free/top/jq/systemctl
  # calls a second time for the same redraw. ---
  IFS=$'\t' read -r bw_today_human bw_yesterday_human bw_month_human < <(
    jq -r '[.bandwidth.today_human, .bandwidth.yesterday_human, .bandwidth.month_human] | @tsv' <<<"$stats"
  )

  line "BANDWITH USAGE"
  echo ""
  printf "Bandwidth  Used Today      = %s\n" "$bw_today_human"
  printf "Bandwidth  Used yesterday  = %s\n" "$bw_yesterday_human"
  printf "Total Bandwith Used in a Month = %s\n" "$bw_month_human"
  echo ""

  printf '%s\n' "==================================================="
  read -rp " Choose an option: " opt

  case "$opt" in
    1)  bash "$BASE/menu-ssh.sh" ;;
    2)  bash "$BASE/menu-xray.sh" vmess ;;
    3)  bash "$BASE/menu-xray.sh" vless ;;
    4)  bash "$BASE/menu-xray.sh" trojan ;;
    5)  bash "$BASE/menu-xray.sh" shadowsocks ;;
    6)  bash "$BASE/menu-wireguard.sh" ;;
    7)  bash "$BASE/menu-settings.sh" ;;
    8)  bash "$BASE/menu-bot-api.sh" ;;
    9)  bash "$BASE/menu-security.sh" ;;
    10) bash "$BASE/menu-webgui.sh" ;;
    11) bash "$BASE/menu-backup.sh" ;;
    12) bash "$INSTALL_DIR/install/uninstall.sh"
        # A completed uninstall just deleted $INSTALL_DIR out from under
        # this very process -- a running script keeps executing whatever's
        # already loaded even after its own file is gone, so without this
        # check the loop would just redraw a dashboard for a panel that no
        # longer exists. Check the actual resulting state (not an exit
        # code) so this is correct whether the uninstall ran to completion
        # or was cancelled partway.
        if [[ ! -d "$INSTALL_DIR" ]]; then
          clear
          echo "VPN-Starter-Kit has been uninstalled. Goodbye."
          exit 0
        fi
        pause ;;
    0)  clear; exit 0 ;;
    *)  echo "Invalid option."; sleep 1 ;;
  esac
done

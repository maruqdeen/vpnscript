#!/bin/bash
# VPN-Starter-Kit :: core/dashboard-stats.sh
# Single source of truth for "current dashboard stats" -- server info,
# active services, account counts, bandwidth -- consumed by both
# menu.sh's own header and the web admin panel's dashboard, so there is
# exactly one place computing these numbers instead of two that could
# drift apart. Extracted from menu.sh's original inline draw_header().
# Usage: dashboard-stats.sh   (prints one JSON object, no args)
set -uo pipefail

CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/etc/vpn-script"

source "$CORE_DIR/../menu/lib-ssh-users.sh"
source "$CORE_DIR/wireguard.sh"
# XRAY_CONFIG comes from bandwidth.sh (sourced next) -- deliberately not
# redeclared here, since a second copy of the same path in two files is
# exactly the kind of thing that silently drifts if one is ever changed
# without the other (source order would then win invisibly).
source "$CORE_DIR/bandwidth.sh"

svc_active() {
  systemctl is-active --quiet "$1" 2>/dev/null && echo true || echo false
}

# vmess/vless/trojan each have a WS + gRPC inbound sharing one client
# list, so counting raw clients across .inbounds[] double-counts every
# account; dedupe by email first. Shadowsocks has a single inbound.
count_xray() {
  jq -r --arg p "$1" '[.inbounds[]? | select(.protocol==$p) | .settings.clients[]?.email] | unique | length' \
    "$XRAY_CONFIG" 2>/dev/null || echo 0
}

# ---- server info ----
uptime_str="$(uptime -p 2>/dev/null | sed 's/^up //')"
[[ -z "$uptime_str" ]] && uptime_str="n/a"
ip="$(curl -s --max-time 3 https://api.ipify.org || hostname -I | awk '{print $1}')"
os="$( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Unknown}" ) ( $(uname -m) )"
ram_total="$(free -m | awk '/^Mem:/{print $2}')"
ram_used="$(free -m | awk '/^Mem:/{print $3}')"
cpu="$(top -bn1 | awk '/Cpu\(s\)/{printf "%.0f", $2+$4}')"
domain="$(cat "$INSTALL_DIR/domain" 2>/dev/null)";      [[ -z "$domain" ]]   && domain="(not set)"
nsdomain="$(cat "$INSTALL_DIR/ns-domain" 2>/dev/null)"; [[ -z "$nsdomain" ]] && nsdomain="(not set)"
if [[ -f "$INSTALL_DIR/autoreboot.enabled" ]]; then
  reboot_status="Daily $(cat "$INSTALL_DIR/autoreboot.time" 2>/dev/null || echo '?')"
else
  reboot_status="Not set"
fi

: "${ram_total:=0}"
: "${ram_used:=0}"
: "${cpu:=0}"

# ---- active accounts (shadowsocks added here -- menu.sh's original
# inline version predates the Shadowsocks rebuild and never counted it) ----
ssh_count="$(ssh_user_list | grep -c .)"
vmess_count="$(count_xray vmess)"
vless_count="$(count_xray vless)"
trojan_count="$(count_xray trojan)"
ss_count="$(count_xray shadowsocks)"
wg_count="$(jq 'length' "$WG_CLIENTS_JSON" 2>/dev/null || echo 0)"

: "${ssh_count:=0}"
: "${vmess_count:=0}"
: "${vless_count:=0}"
: "${trojan_count:=0}"
: "${ss_count:=0}"
: "${wg_count:=0}"

# ---- bandwidth ----
bw_ensure
read -r bw_today_b bw_yesterday_b < <(bw_day_stats)
bw_month_b="$(bw_month_bytes)"

: "${bw_today_b:=0}"
: "${bw_yesterday_b:=0}"
: "${bw_month_b:=0}"

jq -n \
  --arg uptime "$uptime_str" \
  --arg ip "$ip" \
  --arg os "$os" \
  --argjson ram_used "$ram_used" \
  --argjson ram_total "$ram_total" \
  --argjson cpu "$cpu" \
  --arg domain "$domain" \
  --arg ns_domain "$nsdomain" \
  --arg reboot_status "$reboot_status" \
  --argjson svc_ssh "$(svc_active ssh)" \
  --argjson svc_nginx "$(svc_active nginx)" \
  --argjson svc_dropbear "$(svc_active dropbear)" \
  --argjson svc_slowdns "$(svc_active slowdns)" \
  --argjson svc_xray "$(svc_active xray)" \
  --argjson svc_ws_proxy "$(svc_active ws-proxy)" \
  --argjson svc_ohp_proxy "$(svc_active ohp-proxy)" \
  --argjson svc_haproxy "$(svc_active vpn-haproxy)" \
  --argjson svc_sslh "$(svc_active vpn-sslh)" \
  --argjson svc_badvpn "$(svc_active vpn-badvpn)" \
  --argjson svc_ovpn_tcp "$(svc_active openvpn@vpn-tcp1194)" \
  --argjson svc_ovpn_udp "$(svc_active openvpn@vpn-udp1194)" \
  --argjson svc_proxy "$(svc_active squid)" \
  --argjson acc_ssh "$ssh_count" \
  --argjson acc_vmess "$vmess_count" \
  --argjson acc_vless "$vless_count" \
  --argjson acc_trojan "$trojan_count" \
  --argjson acc_ss "$ss_count" \
  --argjson acc_wg "$wg_count" \
  --argjson bw_today "$bw_today_b" \
  --argjson bw_yesterday "$bw_yesterday_b" \
  --argjson bw_month "$bw_month_b" \
  --arg bw_today_human "$(_bw_human "$bw_today_b")" \
  --arg bw_yesterday_human "$(_bw_human "$bw_yesterday_b")" \
  --arg bw_month_human "$(_bw_human "$bw_month_b")" \
  '{
    server: {uptime:$uptime, ip:$ip, os:$os, ram_used_mb:$ram_used, ram_total_mb:$ram_total, cpu_pct:$cpu, domain:$domain, ns_domain:$ns_domain, reboot_status:$reboot_status},
    services: {ssh:$svc_ssh, nginx:$svc_nginx, dropbear:$svc_dropbear, slowdns:$svc_slowdns, xray:$svc_xray, "ws-proxy":$svc_ws_proxy, "ohp-proxy":$svc_ohp_proxy, "vpn-haproxy":$svc_haproxy, "vpn-sslh":$svc_sslh, "vpn-badvpn":$svc_badvpn, "openvpn-tcp":$svc_ovpn_tcp, "openvpn-udp":$svc_ovpn_udp, proxy:$svc_proxy},
    accounts: {ssh:$acc_ssh, vmess:$acc_vmess, vless:$acc_vless, trojan:$acc_trojan, shadowsocks:$acc_ss, wireguard:$acc_wg},
    bandwidth: {today_bytes:$bw_today, yesterday_bytes:$bw_yesterday, month_bytes:$bw_month, today_human:$bw_today_human, yesterday_human:$bw_yesterday_human, month_human:$bw_month_human}
  }'

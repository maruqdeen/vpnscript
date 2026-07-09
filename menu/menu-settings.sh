#!/bin/bash
# VPN-Starter-Kit :: menu/menu-settings.sh
# Settings submenu.
set -uo pipefail

if [[ $EUID -ne 0 ]]; then echo "Run as root."; exit 1; fi

INSTALL_DIR="/etc/vpn-script"
CORE_DIR="$INSTALL_DIR/core"
BANNER_FILE="$INSTALL_DIR/banner.txt"
DOMAIN_FILE="$INSTALL_DIR/domain"
NS_DOMAIN_FILE="$INSTALL_DIR/ns-domain"
AUTOREBOOT_FLAG="$INSTALL_DIR/autoreboot.enabled"
AUTOREBOOT_TIME_FILE="$INSTALL_DIR/autoreboot.time"
AUTOREBOOT_CRON="/etc/cron.d/vpn-auto-reboot"

# colors
BL=$'\e[38;5;111m'; Y=$'\e[33m'; G=$'\e[32m'; X=$'\e[0m'

pause() { read -rp $'\nPress Enter to continue...' _; }

center() {
  local text="$1" width=52 pad
  pad=$(( (width - ${#text}) / 2 ))
  (( pad < 0 )) && pad=0
  printf "%${pad}s%s\n" "" "$text"
}

# ---- [01] Change Primary Domain & Ns Domain ----
change_domains() {
  echo "Current primary domain : $(cat "$DOMAIN_FILE" 2>/dev/null || echo '(not set)')"
  read -rp "New primary (TLS/WS) domain [blank = keep current]: " NEW_DOMAIN
  if [[ -n "$NEW_DOMAIN" ]]; then
    if [[ ! -x "$CORE_DIR/tls.sh" ]]; then
      echo "Missing $CORE_DIR/tls.sh — re-run the installer (or copy core/tls.sh"
      echo "from the repo into $CORE_DIR/) before changing the domain."
    else
      echo "$NEW_DOMAIN" > "$DOMAIN_FILE"
      echo ">>> Reissuing TLS cert for '$NEW_DOMAIN' (nginx restarts briefly)..."
      bash "$CORE_DIR/tls.sh" "$NEW_DOMAIN"
    fi
  fi

  echo ""
  echo "Current NS domain       : $(cat "$NS_DOMAIN_FILE" 2>/dev/null || echo '(not set)')"
  read -rp "New SlowDNS NS domain [blank = keep current]: " NEW_NS
  if [[ -n "$NEW_NS" ]]; then
    echo "$NEW_NS" > "$NS_DOMAIN_FILE"
    cat > /etc/systemd/system/slowdns.service <<EOF
[Unit]
Description=SlowDNS (DNSTT) Server (VPN-Starter-Kit)
After=network.target

[Service]
Type=simple
ExecStart=/etc/vpn-script/slowdns/dnstt-server \\
  -udp :5300 \\
  -privkey-file /etc/vpn-script/slowdns/server.key \\
  ${NEW_NS} \\
  127.0.0.1:143
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl restart slowdns
    echo "NS domain updated -> $NEW_NS (slowdns restarted)."
  fi
}

# ---- [02] All Service Port Info ----
port_info() {
  local domain nsdomain
  domain="$(cat "$DOMAIN_FILE" 2>/dev/null)"; [[ -z "$domain" ]] && domain="(not set)"
  nsdomain="$(cat "$NS_DOMAIN_FILE" 2>/dev/null)"; [[ -z "$nsdomain" ]] && nsdomain="(not set)"

  printf '%s\n' "===================================================="
  echo " SERVICE PORTS"
  printf '%s\n' "===================================================="
  printf "  %-26s %s\n" "Xray VLESS (path /vless)" "80, 8080, 443(tls)"
  printf "  %-26s %s\n" "Xray VMess (path /vmess)" "80, 8080, 443(tls)"
  printf "  %-26s %s\n" "SSH-WS (path /)" "80, 8080, 8880, 443(tls)"
  printf "  %-26s %s\n" "Dropbear (internal)" "127.0.0.1:143"
  printf "  %-26s %s\n" "SlowDNS" "UDP 53 -> 5300"
  printf "  %-26s %s\n" "OpenSSH (admin)" "22"
  echo ""
  printf "  TLS/WS domain : %s\n" "$domain"
  printf "  SlowDNS NS    : %s\n" "$nsdomain"
  printf '%s\n' "===================================================="
}

# ---- [03] Change Service Port ----
change_service_port() {
  echo "Change Service Port — not built yet."
  echo "Reworking nginx/ws.py ports safely on a live server is its own task."
}

# ---- [04] Speedtest VPS ----
speedtest_vps() {
  printf '%s\n' "===================================================="
  echo " SPEEDTEST VPS  (speed.cloudflare.com, no extra packages)"
  printf '%s\n' "===================================================="
  echo ""

  echo -n "Latency      : "
  local t
  t="$(curl -o /dev/null -s -w '%{time_connect}' --max-time 10 https://speed.cloudflare.com/ 2>/dev/null)"
  if [[ -n "$t" ]]; then awk -v t="$t" 'BEGIN{printf "%.0f ms\n", t*1000}'; else echo "failed"; fi

  echo -n "Download     : "
  local dl
  dl="$(curl -o /dev/null -s --max-time 20 -w '%{speed_download}' \
        "https://speed.cloudflare.com/__down?bytes=50000000" 2>/dev/null)"
  if [[ -n "$dl" && "$dl" != "0" ]]; then awk -v s="$dl" 'BEGIN{printf "%.2f Mbps\n", (s*8)/1000000}'; else echo "failed"; fi

  echo -n "Upload       : "
  local ul
  ul="$(head -c 20000000 /dev/urandom | curl -o /dev/null -s --max-time 20 -w '%{speed_upload}' \
        -X POST --data-binary @- "https://speed.cloudflare.com/__up" 2>/dev/null)"
  if [[ -n "$ul" && "$ul" != "0" ]]; then awk -v s="$ul" 'BEGIN{printf "%.2f Mbps\n", (s*8)/1000000}'; else echo "failed"; fi

  printf '%s\n' "===================================================="
}

# ---- [05] Set Auto Reboot ----
set_auto_reboot() {
  if [[ -f "$AUTOREBOOT_FLAG" ]]; then
    echo "Auto reboot: ENABLED — daily at $(cat "$AUTOREBOOT_TIME_FILE" 2>/dev/null || echo '?')"
  else
    echo "Auto reboot: DISABLED"
  fi
  echo ""
  echo "  [1] Enable"
  echo "  [2] Disable"
  echo "  [0] Back"
  read -rp "Choose: " opt

  case "$opt" in
    1)
      read -rp "Reboot time, 24h HH:MM [default 04:00]: " HHMM
      HHMM="${HHMM:-04:00}"
      if ! [[ "$HHMM" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        echo "Invalid time, defaulting to 04:00."; HHMM="04:00"
      fi
      local hh="${HHMM%%:*}" mm="${HHMM##*:}"
      echo "$HHMM" > "$AUTOREBOOT_TIME_FILE"
      touch "$AUTOREBOOT_FLAG"
      echo "$((10#$mm)) $((10#$hh)) * * * root /sbin/reboot" > "$AUTOREBOOT_CRON"
      chmod 644 "$AUTOREBOOT_CRON"
      systemctl restart cron >/dev/null 2>&1 || true
      echo "Auto reboot ENABLED — daily at $HHMM."
      ;;
    2)
      rm -f "$AUTOREBOOT_FLAG" "$AUTOREBOOT_CRON"
      systemctl restart cron >/dev/null 2>&1 || true
      echo "Auto reboot DISABLED."
      ;;
    0) return ;;
    *) echo "Invalid option." ;;
  esac
}

# ---- [06] Check Running Service ----
check_running() {
  printf '%s\n' "===================================================="
  echo " RUNNING SERVICES"
  printf '%s\n' "===================================================="
  systemctl --no-pager --type=service | grep -E 'xray|nginx|dropbear|ws-proxy|slowdns|cron'
}

# ---- [07] Restart All Service ----
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

# ---- [08] Change Banner ----
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
  printf '%s\n' "===================================================="
  center "SETTING MANAGER"
  printf '%s\n' "===================================================="
  echo ""
  printf "  ${BL}[01]${X} Change Primary Domain & Ns Domain\n"
  printf "  ${BL}[02]${X} All Service Port Info\n"
  printf "  ${BL}[03]${X} Change Service Port\n"
  printf "  ${BL}[04]${X} Speedtest VPS\n"
  printf "  ${BL}[05]${X} Set Auto Reboot\n"
  printf "  ${BL}[06]${X} Check Running Service\n"
  printf "  ${BL}[07]${X} Restart All Service\n"
  printf "  ${BL}[08]${X} Change Banner\n"
  echo ""
  printf "  ${Y}[00]${X} Main Menu\n"
  echo ""
  read -rp " Select menu : " opt

  case "$opt" in
    1|01) change_domains ; pause ;;
    2|02) port_info ; pause ;;
    3|03) change_service_port ; pause ;;
    4|04) speedtest_vps ; pause ;;
    5|05) set_auto_reboot ; pause ;;
    6|06) check_running ; pause ;;
    7|07) restart_all ; pause ;;
    8|08) edit_banner ; pause ;;
    0|00) exit 0 ;;
    *) echo "Invalid option."; sleep 1 ;;
  esac
done

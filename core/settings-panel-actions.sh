#!/bin/bash
# VPN-Starter-Kit :: core/settings-panel-actions.sh
# Non-interactive actions for the web admin panel's Settings section,
# for the pieces of menu/menu-settings.sh that only ever existed as
# interactive functions in that file (domain/NS-domain change, banner,
# auto-reboot, and the plain read-only reports) -- everything else in
# Settings (HAProxy/SSLH/BadVPN/OpenVPN/Proxy/Stunnel/UDP-Custom/SSH
# Engine toggles) already has its own standalone core/*.sh enable|disable
# script that the bash menu calls directly, so the panel does the same,
# no new wrapper needed for those.
# Usage:
#   settings-panel-actions.sh get-domains
#   settings-panel-actions.sh set-domain <domain>
#   settings-panel-actions.sh set-ns-domain <ns-domain>
#   settings-panel-actions.sh get-banner
#   settings-panel-actions.sh set-banner            (reads new text from stdin)
#   settings-panel-actions.sh autoreboot-status
#   settings-panel-actions.sh autoreboot-enable <HH:MM>
#   settings-panel-actions.sh autoreboot-disable
#   settings-panel-actions.sh port-info
#   settings-panel-actions.sh speedtest
#   settings-panel-actions.sh check-running
#   settings-panel-actions.sh restart-all
#   settings-panel-actions.sh clear-ram-cache
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

ACTION="${1:-}"
[[ $# -gt 0 ]] && shift

case "$ACTION" in
  get-domains)
    domain="$(cat "$DOMAIN_FILE" 2>/dev/null)"
    nsdomain="$(cat "$NS_DOMAIN_FILE" 2>/dev/null)"
    jq -n --arg d "$domain" --arg n "$nsdomain" '{ok:true, domain:$d, ns_domain:$n}'
    ;;

  set-domain)
    NEW_DOMAIN="${1:-}"
    if [[ -z "$NEW_DOMAIN" ]]; then echo "Usage: set-domain <domain>"; exit 1; fi
    if [[ ! -f "$CORE_DIR/tls.sh" ]]; then
      echo "Missing $CORE_DIR/tls.sh -- re-run the installer (or copy core/tls.sh"
      echo "from the repo into $CORE_DIR/) before changing the domain."
      exit 1
    fi
    echo "$NEW_DOMAIN" > "$DOMAIN_FILE"
    echo ">>> Reissuing TLS cert for '$NEW_DOMAIN' (nginx restarts briefly)..."
    bash "$CORE_DIR/tls.sh" "$NEW_DOMAIN"
    [[ -f "$CORE_DIR/haproxy.sh" ]] && bash "$CORE_DIR/haproxy.sh" regen
    echo "Primary domain updated -> $NEW_DOMAIN."
    ;;

  set-ns-domain)
    NEW_NS="${1:-}"
    if [[ -z "$NEW_NS" ]]; then echo "Usage: set-ns-domain <ns-domain>"; exit 1; fi
    echo "$NEW_NS" > "$NS_DOMAIN_FILE"
    source "$CORE_DIR/lib-slowdns-unit.sh"
    write_slowdns_unit "$NEW_NS" "$(cat "$INSTALL_DIR/ssh-target-port" 2>/dev/null || echo 143)"
    systemctl restart slowdns
    echo "NS domain updated -> $NEW_NS (slowdns restarted)."
    ;;

  get-banner)
    cat "$BANNER_FILE" 2>/dev/null || true
    ;;

  set-banner)
    tmp="$(mktemp)"
    cat > "$tmp"
    mv "$tmp" "$BANNER_FILE"
    if grep -q 'DROPBEAR_BANNER' /etc/default/dropbear 2>/dev/null; then
      sed -i "s|^DROPBEAR_BANNER=.*|DROPBEAR_BANNER=\"$BANNER_FILE\"|" /etc/default/dropbear
    else
      echo "DROPBEAR_BANNER=\"$BANNER_FILE\"" >> /etc/default/dropbear
    fi
    systemctl restart dropbear 2>/dev/null || true
    echo "Banner updated and applied to Dropbear."
    ;;

  autoreboot-status)
    if [[ -f "$AUTOREBOOT_FLAG" ]]; then
      time_val="$(cat "$AUTOREBOOT_TIME_FILE" 2>/dev/null || echo '?')"
      jq -n --arg t "$time_val" '{ok:true, enabled:true, time:$t}'
    else
      jq -n '{ok:true, enabled:false, time:null}'
    fi
    ;;

  autoreboot-enable)
    HHMM="${1:-04:00}"
    if ! [[ "$HHMM" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
      echo "Invalid time, defaulting to 04:00."; HHMM="04:00"
    fi
    hh="${HHMM%%:*}"; mm="${HHMM##*:}"
    echo "$HHMM" > "$AUTOREBOOT_TIME_FILE"
    touch "$AUTOREBOOT_FLAG"
    echo "$((10#$mm)) $((10#$hh)) * * * root /sbin/reboot" > "$AUTOREBOOT_CRON"
    chmod 644 "$AUTOREBOOT_CRON"
    systemctl restart cron >/dev/null 2>&1 || true
    echo "Auto reboot ENABLED -- daily at $HHMM."
    ;;

  autoreboot-disable)
    rm -f "$AUTOREBOOT_FLAG" "$AUTOREBOOT_CRON"
    systemctl restart cron >/dev/null 2>&1 || true
    echo "Auto reboot DISABLED."
    ;;

  port-info)
    domain="$(cat "$DOMAIN_FILE" 2>/dev/null)"; [[ -z "$domain" ]] && domain="(not set)"
    nsdomain="$(cat "$NS_DOMAIN_FILE" 2>/dev/null)"; [[ -z "$nsdomain" ]] && nsdomain="(not set)"
    engine="$(cat "$INSTALL_DIR/ssh-engine" 2>/dev/null || echo both)"
    [[ -f "$INSTALL_DIR/haproxy.enabled" ]] && haproxy_status="ON" || haproxy_status="off"
    [[ -f "$INSTALL_DIR/sslh.enabled" ]]    && sslh_status="ON"    || sslh_status="off"
    [[ -f "$INSTALL_DIR/badvpn.enabled" ]]  && badvpn_status="ON"  || badvpn_status="off"
    [[ -f "$INSTALL_DIR/openvpn.enabled" ]] && ovpn_status="ON"    || ovpn_status="off"
    [[ -f "$INSTALL_DIR/proxy.enabled" ]]   && proxy_status="ON"   || proxy_status="off"
    [[ -f "$INSTALL_DIR/stunnel.enabled" ]] && stunnel_status="ON" || stunnel_status="off"
    [[ -f "$INSTALL_DIR/udpcustom.enabled" ]] && udpcustom_status="ON" || udpcustom_status="off"

    printf '%s\n' "===================================================="
    echo " SERVICE PORTS"
    printf '%s\n' "===================================================="
    printf "  %-26s %s\n" "Xray VLESS (path /vless)" "80, 8080, 443(tls)"
    printf "  %-26s %s\n" "Xray VMess (path /vmess)" "80, 8080, 443(tls)"
    printf "  %-26s %s\n" "SSH-WS (path /)" "80, 8080, 8880, 443(tls)"
    printf "  %-26s %s\n" "SSH-OHP" "8181"
    printf "  %-26s %s\n" "Dropbear (internal)" "127.0.0.1:143"
    printf "  %-26s %s\n" "SlowDNS" "UDP 53 -> 5300"
    printf "  %-26s %s\n" "OpenSSH (admin)" "22"
    printf "  %-26s %s\n" "HAProxy SSH-SSL [$haproxy_status]" "444"
    printf "  %-26s %s\n" "SSLH multiplex [$sslh_status]" "446"
    printf "  %-26s %s\n" "BadVPN UDPGW [$badvpn_status]" "127.0.0.1:7300 (tunnel-only)"
    printf "  %-26s %s\n" "OpenVPN TCP [$ovpn_status]" "1194"
    printf "  %-26s %s\n" "OpenVPN UDP [$ovpn_status]" "1194, 443"
    printf "  %-26s %s\n" "OVPN download portal [$ovpn_status]" "85 (tcp), 81 (udp)"
    printf "  %-26s %s\n" "HTTP Proxy [$proxy_status]" "3128"
    printf "  %-26s %s\n" "SOCKS5 Proxy [$proxy_status]" "1080"
    printf "  %-26s %s\n" "Stunnel SSH-TLS [$stunnel_status]" "110, 587"
    printf "  %-26s %s\n" "SSH UDP Custom [$udpcustom_status]" "UDP 1-65535"
    echo ""
    printf "  TLS/WS domain : %s\n" "$domain"
    printf "  SlowDNS NS    : %s\n" "$nsdomain"
    printf "  SSH engine    : %s\n" "$engine"
    printf '%s\n' "===================================================="
    ;;

  speedtest)
    printf '%s\n' "===================================================="
    echo " SPEEDTEST VPS  (speed.cloudflare.com, no extra packages)"
    printf '%s\n' "===================================================="
    echo ""

    echo -n "Latency      : "
    t="$(curl -o /dev/null -s -w '%{time_connect}' --max-time 10 https://speed.cloudflare.com/ 2>/dev/null)"
    if [[ -n "$t" ]]; then awk -v t="$t" 'BEGIN{printf "%.0f ms\n", t*1000}'; else echo "failed"; fi

    echo -n "Download     : "
    dl="$(curl -o /dev/null -s --max-time 20 -w '%{speed_download}' \
          "https://speed.cloudflare.com/__down?bytes=50000000" 2>/dev/null)"
    if [[ -n "$dl" && "$dl" != "0" ]]; then awk -v s="$dl" 'BEGIN{printf "%.2f Mbps\n", (s*8)/1000000}'; else echo "failed"; fi

    echo -n "Upload       : "
    ul="$(head -c 20000000 /dev/urandom | curl -o /dev/null -s --max-time 20 -w '%{speed_upload}' \
          -X POST --data-binary @- "https://speed.cloudflare.com/__up" 2>/dev/null)"
    if [[ -n "$ul" && "$ul" != "0" ]]; then awk -v s="$ul" 'BEGIN{printf "%.2f Mbps\n", (s*8)/1000000}'; else echo "failed"; fi

    printf '%s\n' "===================================================="
    ;;

  check-running)
    printf '%s\n' "===================================================="
    echo " RUNNING SERVICES"
    printf '%s\n' "===================================================="
    systemctl --no-pager --type=service | grep -E 'xray|nginx|dropbear|ws-proxy|ohp-proxy|slowdns|cron|vpn-haproxy|vpn-sslh|vpn-badvpn|openvpn|squid|danted|vpn-stunnel|vpn-udpcustom'
    ;;

  restart-all)
    echo ">>> Restarting all services..."
    for u in xray nginx dropbear ws-proxy ohp-proxy slowdns; do
      if systemctl restart "$u" 2>/dev/null; then
        echo "  $u restarted"
      else
        echo "  $u could not restart"
      fi
    done
    [[ -f "$INSTALL_DIR/haproxy.enabled" ]] && systemctl restart vpn-haproxy 2>/dev/null \
      && echo "  vpn-haproxy restarted"
    [[ -f "$INSTALL_DIR/sslh.enabled" ]]    && systemctl restart vpn-sslh 2>/dev/null \
      && echo "  vpn-sslh restarted"
    [[ -f "$INSTALL_DIR/badvpn.enabled" ]]  && systemctl restart vpn-badvpn 2>/dev/null \
      && echo "  vpn-badvpn restarted"
    if [[ -f "$INSTALL_DIR/openvpn.enabled" ]]; then
      systemctl restart openvpn@vpn-tcp1194 openvpn@vpn-udp1194 openvpn@vpn-udp443 2>/dev/null \
        && echo "  openvpn (tcp1194/udp1194/udp443) restarted"
    fi
    if [[ -f "$INSTALL_DIR/proxy.enabled" ]]; then
      systemctl restart squid danted 2>/dev/null \
        && echo "  squid + danted restarted"
    fi
    [[ -f "$INSTALL_DIR/stunnel.enabled" ]] && systemctl restart vpn-stunnel 2>/dev/null \
      && echo "  vpn-stunnel restarted"
    [[ -f "$INSTALL_DIR/udpcustom.enabled" ]] && systemctl restart vpn-udpcustom 2>/dev/null \
      && echo "  vpn-udpcustom restarted"
    ;;

  clear-ram-cache)
    if [[ ! -e /proc/sys/vm/drop_caches ]]; then
      echo "This kernel doesn't expose /proc/sys/vm/drop_caches"
      echo "(common on OpenVZ/container-based VPS) -- nothing to clear here."
      exit 1
    fi

    before="$(free -m | awk '/^Mem:/{print $3}')"
    echo ">>> Syncing filesystem buffers..."
    sync
    echo ">>> Dropping page cache, dentries, and inodes..."
    if ! echo 3 > /proc/sys/vm/drop_caches 2>/dev/null; then
      echo "Could not write to /proc/sys/vm/drop_caches (permission denied)."
      exit 1
    fi
    after="$(free -m | awk '/^Mem:/{print $3}')"
    freed=$(( before - after ))
    (( freed < 0 )) && freed=0

    echo ""
    printf '%s\n' "===================================================="
    printf "  RAM used before : %s MB\n" "$before"
    printf "  RAM used after  : %s MB\n" "$after"
    printf "  Freed           : %s MB\n" "$freed"
    printf '%s\n' "===================================================="
    ;;

  *)
    echo "Usage: settings-panel-actions.sh <action> ..."
    exit 1
    ;;
esac

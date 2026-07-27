#!/bin/bash
# VPN-Starter-Kit :: install/uninstall.sh
# Completely removes this project from the server: every service, config,
# cron job, firewall rule, systemd unit, and account it created — nothing
# left behind. Deliberately resilient (no `set -e`, every step guarded
# with `|| true`): a single step failing must not abort the teardown and
# leave the box in a half-removed state. Reuses each optional feature's
# own tested `disable` action wherever one exists, rather than
# re-implementing that cleanup here.
#
# SAFETY: never touches the system's own OpenSSH ('ssh') service or the
# admin's own login account — that's the one thing this project has
# always deliberately left alone (see core/ssh-engine.sh), and an
# uninstaller is exactly the place a mistake there would be worst.
#
# Usage: uninstall.sh   (interactive — prompts for confirmation)
set -uo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."
  exit 1
fi

INSTALL_DIR="/etc/vpn-script"
CORE_DIR="$INSTALL_DIR/core"

echo "===================================================="
echo " UNINSTALL VPN-STARTER-KIT"
echo "===================================================="
echo ""
echo "This will completely remove this VPN panel from the server:"
echo "  - every SSH/VMess/VLESS/Trojan/WireGuard account it created"
echo "  - Xray, nginx, Dropbear, SlowDNS, and every optional service"
echo "    (HAProxy, SSLH, Stunnel, SSH UDP Custom, OpenVPN, BadVPN,"
echo "    HTTP/SOCKS proxy, fail2ban, anti-torrent, DDoS protection)"
echo "  - both Telegram bots and all their stored credentials"
echo "  - every config file, cron job, and firewall rule it added"
echo ""
echo "Your own OpenSSH admin login (port 22) and this SSH session are"
echo "NEVER touched — you will not be locked out."
echo ""
echo "THIS CANNOT BE UNDONE."
echo ""
read -rp "Type CONFIRM to proceed: " ANSWER
if [[ "${ANSWER,,}" != "confirm" ]]; then
  echo "Cancelled — nothing was changed."
  exit 0
fi

echo ""
echo ">>> [1/9] Disabling optional services (own cleanup logic each)..."
for svc in haproxy sslh badvpn openvpn proxy stunnel udp-custom fail2ban anti-torrent ddos-protection clean-expired; do
  if [[ -f "$CORE_DIR/${svc}.sh" ]]; then
    bash "$CORE_DIR/${svc}.sh" disable >/dev/null 2>&1 || true
  fi
done
echo "    done."

echo ">>> [2/9] Disconnecting Telegram bots and the Admin Panel..."
systemctl disable --now vpn-telegram-bot >/dev/null 2>&1 || true
systemctl disable --now vpn-telegram-user-bot >/dev/null 2>&1 || true
systemctl disable --now vpn-admin-panel >/dev/null 2>&1 || true
rm -f /etc/systemd/system/vpn-telegram-bot.service /etc/systemd/system/vpn-telegram-user-bot.service \
      /etc/systemd/system/vpn-admin-panel.service /etc/pam.d/vpn-admin-panel
rm -f "$INSTALL_DIR"/telegram-bot-token "$INSTALL_DIR"/telegram-admin-id "$INSTALL_DIR"/telegram-bot-claim.json \
      "$INSTALL_DIR"/telegram-bot.enabled "$INSTALL_DIR"/telegram-user-bot-token \
      "$INSTALL_DIR"/telegram-user-bot-access.json "$INSTALL_DIR"/telegram-user-bot-cooldown.json \
      "$INSTALL_DIR"/telegram-user-bot.enabled "$INSTALL_DIR"/admin-panel.enabled \
      "$INSTALL_DIR"/admin-panel-login-attempts.json
echo "    done."

echo ">>> [3/9] Removing SSH/SlowDNS accounts created by this panel..."
if [[ -f "$INSTALL_DIR/menu/lib-ssh-users.sh" ]]; then
  # shellcheck disable=SC1091
  source "$INSTALL_DIR/menu/lib-ssh-users.sh"
  while read -r u; do
    [[ -z "$u" ]] && continue
    pkill -u "$u" >/dev/null 2>&1 || true
    userdel "$u" >/dev/null 2>&1 || true
  done < <(ssh_user_list 2>/dev/null)
fi
# the shared trial account, if one exists
systemctl stop trial-expire.timer trial-expire.service >/dev/null 2>&1 || true
pkill -u trial >/dev/null 2>&1 || true
userdel trial >/dev/null 2>&1 || true
echo "    done."

echo ">>> [4/9] Stopping WireGuard (its own PostDown cleans up its firewall rules)..."
systemctl disable --now "wg-quick@wg0" >/dev/null 2>&1 || true
echo "    done."

echo ">>> [5/9] Removing OpenVPN's NAT rules (not handled by its own disable)..."
IFACE="$(ip route show default 2>/dev/null | awk '{print $5; exit}')"
[[ -z "$IFACE" ]] && IFACE="eth0"
for subnet in 10.8.0.0/24 10.9.0.0/24 10.10.0.0/24; do
  iptables -t nat -D POSTROUTING -s "$subnet" -o "$IFACE" -j MASQUERADE >/dev/null 2>&1 || true
done
netfilter-persistent save >/dev/null 2>&1 || true
echo "    done."

echo ">>> [6/9] Stopping core services (OpenSSH is NEVER included here)..."
systemctl disable --now xray >/dev/null 2>&1 || true
systemctl disable --now nginx >/dev/null 2>&1 || true
systemctl disable --now dropbear >/dev/null 2>&1 || true
systemctl disable --now ws-proxy >/dev/null 2>&1 || true
systemctl disable --now ohp-proxy >/dev/null 2>&1 || true
systemctl disable --now slowdns >/dev/null 2>&1 || true
echo "    done."

echo ">>> [7/9] Removing Xray..."
bash -c "$(curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove >/dev/null 2>&1 || true
rm -rf /usr/local/etc/xray /usr/local/share/xray /var/log/xray
echo "    done."

echo ">>> [8/9] Purging installed packages (this can take a minute)..."
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
systemctl disable --now webmin >/dev/null 2>&1 || true
apt-get purge -y nginx nginx-common dropbear sslh haproxy stunnel4 squid squid-common \
  dante-server wireguard wireguard-tools openvpn easy-rsa fail2ban qrencode webmin usermin >/dev/null 2>&1 || true
rm -f /etc/apt/sources.list.d/webmin*.list /etc/apt/sources.list.d/usermin*.list
apt-get autoremove -y >/dev/null 2>&1 || true
echo "    done."

echo ">>> [9/9] Removing config, state, logs, cron jobs, and systemd units..."
rm -f /etc/cron.d/vpn-auto-reboot /etc/cron.d/vpn-autokill /etc/cron.d/vpn-bandwidth-snapshot \
      /etc/cron.d/vpn-clean-expired /etc/cron.d/vpn-ssh-limits

rm -f /etc/systemd/system/vpn-haproxy.service /etc/systemd/system/vpn-sslh.service \
      /etc/systemd/system/vpn-badvpn.service /etc/systemd/system/vpn-stunnel.service \
      /etc/systemd/system/vpn-udpcustom.service /etc/systemd/system/vpn-telegram-bot.service \
      /etc/systemd/system/vpn-telegram-user-bot.service /etc/systemd/system/vpn-admin-panel.service \
      /etc/systemd/system/ws-proxy.service /etc/systemd/system/ohp-proxy.service \
      /etc/systemd/system/slowdns.service /etc/systemd/system/trial-expire.service \
      /etc/systemd/system/trial-expire.timer
rm -f /etc/pam.d/vpn-admin-panel
systemctl daemon-reload >/dev/null 2>&1 || true

rm -f /etc/sysctl.d/99-vpn-bbr.conf /etc/sysctl.d/99-vpn-ddos.conf \
      /etc/sysctl.d/99-vpn-ovpn-forward.conf /etc/sysctl.d/99-vpn-wg-forward.conf
sysctl --system >/dev/null 2>&1 || true

rm -f /etc/fail2ban/jail.d/vpn-script-sshd.conf
rm -rf /etc/openvpn /etc/wireguard /etc/squid /etc/danted.conf /etc/stunnel
rm -rf /etc/nginx
rm -rf /var/log/vpn-script
rm -f /usr/local/bin/menu
rm -rf "$INSTALL_DIR"
echo "    done."

echo ""
echo "===================================================="
echo " UNINSTALL COMPLETE"
echo "===================================================="
echo "This VPN panel and everything it created has been removed."
echo "Your OpenSSH admin login (port 22) is untouched — this session"
echo "is still connected normally."
echo "===================================================="

#!/bin/bash
# VPN-Starter-Kit :: install/setup.sh  (full orchestrator, hardened)
# Run standalone:
#   wget -q https://raw.githubusercontent.com/maruqdeen/vpnscript/main/install/setup.sh && chmod +x setup.sh && sudo bash setup.sh
# Or from a clone:
#   sudo bash install/setup.sh
set -euo pipefail

# ============================================================
# SELF-BOOTSTRAP — if run standalone (no repo next to us),
# pull the whole repo tarball and re-exec from inside it.
# ============================================================
REPO_SLUG="maruqdeen/vpnscript"
REPO_BRANCH="main"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# We know we're "inside the repo" if core/config.json exists one level up.
if [[ ! -f "$SCRIPT_DIR/../core/config.json" ]]; then
  echo ">>> Standalone mode — downloading project files..."
  TMP="$(mktemp -d)"
  wget -qO "$TMP/repo.tar.gz" \
    "https://github.com/${REPO_SLUG}/archive/refs/heads/${REPO_BRANCH}.tar.gz" \
    || { echo "Download failed. Check REPO_SLUG / branch / network."; exit 1; }
  tar -xzf "$TMP/repo.tar.gz" -C "$TMP"
  # GitHub tarballs extract to <repo>-<branch>/
  EXTRACTED="$(find "$TMP" -maxdepth 1 -type d -name '*-'"${REPO_BRANCH}" | head -n1)"
  exec bash "$EXTRACTED/install/setup.sh"
fi

REPO="$(cd "$SCRIPT_DIR/.." && pwd)"

INSTALL_DIR="/etc/vpn-script"

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root:  sudo -i  then re-run."
  exit 1
fi
if ! grep -qE "24.04|22.04|20.04" /etc/os-release; then
  echo "Warning: tested on Ubuntu 20.04 / 22.04 / 24.04. Continuing in 3s..."; sleep 3
fi

export DEBIAN_FRONTEND=noninteractive
# Ubuntu 22.04+ ships needrestart as an apt hook that can pop an
# interactive "which services should be restarted?" TUI mid-install —
# DEBIAN_FRONTEND doesn't cover it (it's a separate dpkg hook, not a
# debconf prompt). Left unset, that dialog can silently block forever
# on a non-interactive `wget | sudo bash` run, looking like the script
# just died. NEEDRESTART_MODE=a auto-restarts services without asking.
export NEEDRESTART_MODE=a

# ============================================================
echo ">>> [1/10] Dependencies"
# ============================================================
apt update -y
apt install -y curl wget jq unzip socat cron nginx dropbear \
  python3 iptables iptables-persistent

# ============================================================
echo ">>> [2/10] Directories + copy project files"
# ============================================================
mkdir -p "$INSTALL_DIR"/{core,menu,slowdns} /var/log/vpn-script
# Xray's official installer runs xray.service as user "nobody" (not root),
# and it needs to CREATE its own log files here on first write — a
# root-only directory would silently crash it at startup.
NOBODY_GROUP="$(id -gn nobody 2>/dev/null || echo nogroup)"
chown -R nobody:"$NOBODY_GROUP" /var/log/vpn-script
cp "$REPO/core/"*.py    "$INSTALL_DIR/core/" 2>/dev/null || true
cp "$REPO/core/"*.sh    "$INSTALL_DIR/core/" 2>/dev/null || true
cp "$REPO/menu/"*.sh    "$INSTALL_DIR/menu/"
chmod +x "$INSTALL_DIR/menu/"*.sh "$INSTALL_DIR/core/"*.py "$INSTALL_DIR/core/"*.sh 2>/dev/null || true

# --- sanity check: critical files must exist AND be non-empty ---
# ([[ ! -s ]] catches both "missing" and "0 bytes" — the failure that
#  produced a broken SSH-WS on earlier installs.)
for f in "$INSTALL_DIR/core/ws.py" \
         "$INSTALL_DIR/core/ohp.py" \
         "$INSTALL_DIR/menu/menu.sh" \
         "$INSTALL_DIR/menu/add-user.sh" \
         "$INSTALL_DIR/menu/add-ssh-user.sh" \
         "$REPO/core/config.json" \
         "$REPO/core/nginx.conf" \
         "$REPO/core/tls.sh" \
         "$REPO/core/dropbear.sh" \
         "$REPO/core/slowdns.sh" \
         "$REPO/core/slowdns.service" \
         "$REPO/core/slowdns-redirect.sh"; do
  if [[ ! -s "$f" ]]; then
    echo ""
    echo "FATAL: '$f' is missing or empty."
    echo "The repo download was incomplete, or that file is empty on GitHub."
    echo "Aborting so you don't get a half-working install."
    exit 1
  fi
done

# ============================================================
echo ">>> [3/10] BBR"
# ============================================================
cat >/etc/sysctl.d/99-vpn-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
sysctl --system >/dev/null 2>&1 || true

# ============================================================
echo ">>> [4/10] Xray-core + config"
# ============================================================
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
install -m 644 "$REPO/core/config.json" /usr/local/etc/xray/config.json

# ============================================================
echo ">>> [5/10] TLS cert + Nginx front door (80 / 8080 / 443)"
# ============================================================
# Cert MUST be created before nginx -t, or the 443 ssl block fails the test.
read -rp "Enter your TLS/WS domain (e.g. vpn.grab2.eu.cc), blank for self-signed: " WS_DOMAIN
echo "${WS_DOMAIN:-}" > "$INSTALL_DIR/domain"
bash "$REPO/core/tls.sh" "${WS_DOMAIN:-}"

install -m 644 "$REPO/core/nginx.conf" /etc/nginx/conf.d/vpn.conf
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
nginx -t
systemctl restart nginx

# ============================================================
echo ">>> [6/10] Dropbear + SSH-WS proxy"
# ============================================================
bash "$REPO/core/dropbear.sh"

# Write the systemd unit INLINE (not copied) so it can never arrive empty
# from an incomplete download — this was the SSH-WS failure on fresh installs.
cat > /etc/systemd/system/ws-proxy.service <<'EOF'
[Unit]
Description=SSH-over-WebSocket Proxy (VPN-Starter-Kit)
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /etc/vpn-script/core/ws.py
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

# SSH-over-HTTP-Proxy (OHP) — same "write inline" reasoning as ws-proxy above.
cat > /etc/systemd/system/ohp-proxy.service <<'EOF'
[Unit]
Description=SSH-over-HTTP-Proxy (OHP) Tunnel (VPN-Starter-Kit)
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /etc/vpn-script/core/ohp.py
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

# ============================================================
echo ">>> [7/10] SlowDNS (needs your NS domain)"
# ============================================================
bash "$REPO/core/slowdns.sh"

read -rp "Enter your SlowDNS NS domain (e.g. slow.creebcloud.net): " NS_DOMAIN
if [[ -z "$NS_DOMAIN" ]]; then
  echo "No NS domain given — SlowDNS service will be installed but left disabled."
  NS_DOMAIN="CHANGE_ME"
fi
# bake the domain into the service unit, and save it for the account card
sed "s|<YOUR_NS_DOMAIN>|${NS_DOMAIN}|g" \
  "$REPO/core/slowdns.service" > /etc/systemd/system/slowdns.service
echo "$NS_DOMAIN" > "$INSTALL_DIR/ns-domain"
bash "$REPO/core/slowdns-redirect.sh"

# --- free UDP 53 from systemd-resolved so DNS can reach us ---
echo ">>> Freeing port 53 from systemd-resolved..."
mkdir -p /etc/systemd/resolved.conf.d
cat >/etc/systemd/resolved.conf.d/vpn.conf <<'EOF'
[Resolve]
DNSStubListener=no
EOF
# keep working resolv.conf (resolved's symlink breaks once stub is off)
ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf 2>/dev/null || true
systemctl restart systemd-resolved || true

# ============================================================
echo ">>> [8/10] Enable + start all services"
# ============================================================
systemctl daemon-reload
# guard against a stale mask from any earlier partial run
systemctl unmask ws-proxy ohp-proxy 2>/dev/null || true
systemctl enable --now xray nginx dropbear ws-proxy ohp-proxy >/dev/null 2>&1 || true
if [[ "$NS_DOMAIN" != "CHANGE_ME" ]]; then
  systemctl enable --now slowdns >/dev/null 2>&1 || true
else
  systemctl enable slowdns >/dev/null 2>&1 || true
  echo "  slowdns installed but NOT started (set NS domain, then: systemctl start slowdns)"
fi

# --- verify SSH-WS / SSH-OHP actually came up (fail loudly if not) ---
sleep 1
if ! systemctl is-active --quiet ws-proxy; then
  echo ""
  echo "WARNING: ws-proxy did not start. Check:  journalctl -u ws-proxy -n 20 --no-pager"
fi
if ! systemctl is-active --quiet ohp-proxy; then
  echo ""
  echo "WARNING: ohp-proxy did not start. Check:  journalctl -u ohp-proxy -n 20 --no-pager"
fi

# ============================================================
echo ">>> [9/10] Optional services (HAProxy, SSLH, OpenVPN, Proxy)"
# ============================================================
# These ship enabled by default. Each is self-contained and non-fatal to
# the base install if one fails — the core VPN service is already up by
# this point, so we warn and move on rather than aborting the whole
# install (OpenVPN especially: first-run PKI + DH generation can take a
# few minutes and is the one step here most likely to hiccup).
bash "$INSTALL_DIR/core/haproxy.sh" enable \
  || echo "WARNING: HAProxy did not enable cleanly — retry via: menu > Settings > Toggle HAProxy"
bash "$INSTALL_DIR/core/sslh.sh" enable \
  || echo "WARNING: SSLH did not enable cleanly — retry via: menu > Settings > Toggle SSLH Multiplex"
echo ">>> Enabling OpenVPN (first run builds a PKI + DH params, can take a few minutes)..."
bash "$INSTALL_DIR/core/openvpn.sh" enable \
  || echo "WARNING: OpenVPN did not enable cleanly — retry via: menu > Settings > Toggle OpenVPN"
bash "$INSTALL_DIR/core/proxy.sh" enable \
  || echo "WARNING: HTTP/SOCKS5 proxy did not enable cleanly — retry via: menu > Settings > Toggle HTTP & SOCKS Proxy"
# Clean Expired User ships enabled by default (unlike fail2ban/anti-
# torrent/DDoS protection under Security Mgt, which stay off until an
# admin opts in); an expired account otherwise just lingers forever.
bash "$INSTALL_DIR/core/clean-expired.sh" enable \
  || echo "WARNING: Clean Expired User did not enable cleanly — retry via: menu > Security Mgt > Clean All Expired User"

# ============================================================
echo ">>> [10/10] Global 'menu' command"
# ============================================================
ln -sf "$INSTALL_DIR/menu/menu.sh" /usr/local/bin/menu
chmod +x /usr/local/bin/menu

echo ""
echo "==================================================="
echo " INSTALL COMPLETE"
echo "==================================================="
echo "  Type  menu  to manage users."
echo "==================================================="

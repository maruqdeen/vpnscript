#!/bin/bash
# VPN-Starter-Kit :: install/update.sh
# Pull the latest core/menu scripts from GitHub and refresh the installed
# copies, WITHOUT re-running the interactive/heavy parts of setup.sh
# (no domain/NS prompts, no apt installs, no xray/dropbear/slowdns/nginx
# reconfiguration). Use this after a `git push` to pick up menu changes.
# Usage (on the VPS, as root):
#   wget -qO- https://raw.githubusercontent.com/maruqdeen/vpnscript/main/install/update.sh | sudo bash
set -euo pipefail

REPO_SLUG="maruqdeen/vpnscript"
REPO_BRANCH="main"
INSTALL_DIR="/etc/vpn-script"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root:  sudo bash update.sh"
  exit 1
fi

echo ">>> Downloading latest ${REPO_SLUG}@${REPO_BRANCH}..."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
wget -qO "$TMP/repo.tar.gz" \
  "https://github.com/${REPO_SLUG}/archive/refs/heads/${REPO_BRANCH}.tar.gz" \
  || { echo "Download failed. Check network."; exit 1; }
tar -xzf "$TMP/repo.tar.gz" -C "$TMP"
EXTRACTED="$(find "$TMP" -maxdepth 1 -type d -name '*-'"${REPO_BRANCH}" | head -n1)"

if [[ -z "$EXTRACTED" ]]; then
  echo "Could not find extracted repo folder. Aborting."
  exit 1
fi

echo ">>> Refreshing core + menu scripts in $INSTALL_DIR ..."
cp "$EXTRACTED/core/"*.py "$INSTALL_DIR/core/" 2>/dev/null || true
cp "$EXTRACTED/core/"*.sh "$INSTALL_DIR/core/" 2>/dev/null || true
cp "$EXTRACTED/menu/"*.sh "$INSTALL_DIR/menu/"
mkdir -p "$INSTALL_DIR/install"
cp "$EXTRACTED/install/uninstall.sh" "$INSTALL_DIR/install/" 2>/dev/null || true
chmod +x "$INSTALL_DIR/menu/"*.sh "$INSTALL_DIR/core/"*.py "$INSTALL_DIR/core/"*.sh \
  "$INSTALL_DIR/install/"*.sh 2>/dev/null || true

NGINX_REFRESHED=0
if [[ -f "$EXTRACTED/core/nginx.conf" && -f /etc/nginx/conf.d/vpn.conf ]]; then
  echo ">>> Refreshing nginx config..."
  cp "$EXTRACTED/core/nginx.conf" "$INSTALL_DIR/core/nginx.conf"
  BACKUP="/etc/nginx/conf.d/vpn.conf.bak-$(date +%s)"
  cp /etc/nginx/conf.d/vpn.conf "$BACKUP"
  install -m 644 "$INSTALL_DIR/core/nginx.conf" /etc/nginx/conf.d/vpn.conf
  if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx
    NGINX_REFRESHED=1
    echo "    nginx config refreshed + reloaded."
  else
    echo "    WARNING: new nginx config failed 'nginx -t' -- restoring your previous config"
    echo "    so nginx never runs (or reloads into) a broken state. Please report this."
    cp "$BACKUP" /etc/nginx/conf.d/vpn.conf
  fi
fi

ADMIN_PANEL_RESTARTED=0
if [[ -f "$INSTALL_DIR/admin-panel.enabled" ]]; then
  # Safe to restart unconditionally, unlike ws-proxy/ohp-proxy/dropbear/etc:
  # it holds no live tunnel connections, just browser sessions that survive
  # a login (session store is only lost, not corrupted, by a restart) --
  # so it's fine for update.sh to do this automatically where the other,
  # traffic-carrying daemons deliberately are not touched.
  echo ">>> Restarting Admin Panel (picks up the just-refreshed code)..."
  systemctl restart vpn-admin-panel >/dev/null 2>&1 && ADMIN_PANEL_RESTARTED=1
fi

echo ""
echo "==================================================="
echo " UPDATE COMPLETE"
echo "==================================================="
echo "  core/ + menu/ scripts refreshed from ${REPO_BRANCH}."
if [[ "$NGINX_REFRESHED" -eq 1 ]]; then
  echo "  nginx config refreshed + reloaded."
else
  echo "  nginx config untouched (nothing new to apply, or vpn.conf not found)."
fi
if [[ "$ADMIN_PANEL_RESTARTED" -eq 1 ]]; then
  echo "  Admin Panel restarted -- new web routes are now live."
fi
echo "  xray / dropbear / slowdns config untouched."
echo "  Other optional services (Telegram bots, HAProxy, SSLH, etc.) are"
echo "  NOT auto-restarted -- if you changed one of those, restart it"
echo "  yourself (Settings -> Restart All Service, or its own toggle)."
echo "  Type  menu  to continue."
echo "==================================================="

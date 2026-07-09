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
chmod +x "$INSTALL_DIR/menu/"*.sh "$INSTALL_DIR/core/"*.py "$INSTALL_DIR/core/"*.sh 2>/dev/null || true

echo ""
echo "==================================================="
echo " UPDATE COMPLETE"
echo "==================================================="
echo "  core/ + menu/ scripts refreshed from ${REPO_BRANCH}."
echo "  nginx / xray / dropbear / slowdns config untouched."
echo "  Type  menu  to continue."
echo "==================================================="

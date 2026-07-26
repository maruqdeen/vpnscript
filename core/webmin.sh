#!/bin/bash
# VPN-Starter-Kit :: core/webmin.sh
# Installs Webmin (the real upstream project, webmin.com) via its official
# repo-setup script, so the panel's "WebGui" option gives the admin a full
# browser-based control panel alongside this text menu. Authentication is
# Webmin's own default: PAM against local Linux accounts -- i.e. this VPS's
# own root login, the same one already used to SSH in. This script never
# stores, generates, or has any way to know that password -- it only
# reports the URL and the (well-known) username.
# Usage: webmin.sh <install|restart|uninstall|status>
set -uo pipefail

if [[ $EUID -ne 0 ]]; then echo "Run as root."; exit 1; fi

INSTALL_DIR="/etc/vpn-script"
FLAG="$INSTALL_DIR/webmin.installed"
ACTION="${1:-}"

case "$ACTION" in
  install|restart|uninstall|status) ;;
  *) echo "Usage: webmin.sh <install|restart|uninstall|status>"; exit 1 ;;
esac

is_installed() {
  command -v webmin >/dev/null 2>&1 || dpkg -s webmin >/dev/null 2>&1
}

access_card() {
  local ip
  ip="$(curl -s --max-time 5 https://api.ipify.org || hostname -I | awk '{print $1}')"
  cat <<CARD

====================================
   WebGui (Webmin) Access
====================================
URL      : https://${ip}:10000/
Username : root
Password : (your VPS root password -- the same one you use to SSH in)
====================================
Webmin serves a self-signed cert by default -- your browser will warn
about it the first time you connect; that's expected, accept/continue.
====================================
CARD
}

case "$ACTION" in
  status)
    if is_installed; then
      echo "WebGui (Webmin): INSTALLED"
      systemctl is-active --quiet webmin && echo "Service: Active" || echo "Service: Inactive"
    else
      echo "WebGui (Webmin): NOT INSTALLED"
    fi
    ;;

  install)
    if is_installed; then
      echo "Webmin is already installed."
      access_card
      exit 0
    fi

    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=a

    echo "[Info] Adding Repository Webmin"
    TMP_SETUP="$(mktemp)"
    if ! curl -fsSL -o "$TMP_SETUP" https://raw.githubusercontent.com/webmin/webmin/master/webmin-setup-repo.sh; then
      echo "Error: could not download Webmin's repo-setup script."
      rm -f "$TMP_SETUP"
      exit 1
    fi
    if ! sh "$TMP_SETUP" --force >/dev/null 2>&1; then
      echo "Error: Webmin repo setup failed."
      rm -f "$TMP_SETUP"
      exit 1
    fi
    rm -f "$TMP_SETUP"

    echo "[Info] Start Install Webmin"
    if ! apt-get install --install-recommends -y webmin >/dev/null 2>&1; then
      echo "Error: Webmin package install failed — check: apt-get install --install-recommends webmin"
      exit 1
    fi

    echo "[Info] Restart Webmin"
    systemctl enable webmin >/dev/null 2>&1 || true
    systemctl restart webmin
    sleep 1
    if ! systemctl is-active --quiet webmin; then
      echo "WARNING: webmin installed but service isn't active — check: journalctl -u webmin -n 30 --no-pager"
    fi

    touch "$FLAG"
    echo "[Info] Webmin Install Successfully !"
    access_card
    ;;

  restart)
    if ! is_installed; then
      echo "Webmin isn't installed yet."
      exit 1
    fi
    systemctl restart webmin
    echo "Webmin restarted."
    ;;

  uninstall)
    if ! is_installed; then
      echo "Webmin isn't installed."
      exit 0
    fi
    systemctl disable --now webmin >/dev/null 2>&1 || true
    apt-get purge -y webmin usermin >/dev/null 2>&1 || true
    apt-get autoremove -y >/dev/null 2>&1 || true
    rm -f /etc/apt/sources.list.d/webmin*.list /etc/apt/sources.list.d/usermin*.list
    rm -f "$FLAG"
    echo "Webmin uninstalled."
    ;;
esac

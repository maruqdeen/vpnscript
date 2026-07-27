#!/bin/bash
# VPN-Starter-Kit :: core/admin-panel-setup.sh
# Enable/disable the browser admin panel (core/admin-panel.py): creates
# its dedicated PAM service, systemd unit, and prints the access card on
# first enable. Same lazy-install/flag-file pattern as every other
# optional service in this project (core/proxy.sh, core/stunnel.sh, etc).
# Usage: admin-panel-setup.sh <enable|disable|status>
set -uo pipefail

if [[ $EUID -ne 0 ]]; then echo "Run as root."; exit 1; fi

INSTALL_DIR="/etc/vpn-script"
FLAG="$INSTALL_DIR/admin-panel.enabled"
UNIT="/etc/systemd/system/vpn-admin-panel.service"
PAM_SERVICE_FILE="/etc/pam.d/vpn-admin-panel"
DOMAIN_FILE="$INSTALL_DIR/domain"
ACTION="${1:-}"

case "$ACTION" in
  enable|disable|status) ;;
  *) echo "Usage: admin-panel-setup.sh <enable|disable|status>"; exit 1 ;;
esac

access_card() {
  local hostname_val
  hostname_val="$(cat "$DOMAIN_FILE" 2>/dev/null)"
  [[ -z "$hostname_val" ]] && hostname_val="$(curl -s --max-time 5 https://api.ipify.org || hostname -I | awk '{print $1}')"
  cat <<CARD

====================================
   Admin Panel Access
====================================
Login URL : https://${hostname_val}/admin-panel
Username  : root
Password  : [Your VPS Root Password]
====================================
* Nginx automatically encrypts and routes this URL to your local dashboard.
====================================

CARD
}

case "$ACTION" in
  status)
    if [[ -f "$FLAG" ]]; then
      echo "Admin Panel: ENABLED"
      systemctl is-active --quiet vpn-admin-panel && echo "Service: Active" || echo "Service: Inactive"
    else
      echo "Admin Panel: DISABLED"
    fi
    ;;

  enable)
    # Dedicated PAM service, not an assumption about what "login"/"sshd"
    # already do on this box -- same reasoning Webmin itself ships
    # /etc/pam.d/webmin rather than reusing an existing service.
    cat > "$PAM_SERVICE_FILE" <<'EOF'
@include common-auth
@include common-account
EOF
    chmod 644 "$PAM_SERVICE_FILE"

    cat > "$UNIT" <<'EOF'
[Unit]
Description=VPN-Starter-Kit Browser Admin Panel
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /etc/vpn-script/core/admin-panel.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable vpn-admin-panel >/dev/null 2>&1 || true
    systemctl restart vpn-admin-panel

    sleep 1
    if ! systemctl is-active --quiet vpn-admin-panel; then
      echo "WARNING: admin panel installed but service isn't active — check: journalctl -u vpn-admin-panel -n 30 --no-pager"
    fi

    touch "$FLAG"
    access_card
    ;;

  disable)
    systemctl disable --now vpn-admin-panel >/dev/null 2>&1 || true
    rm -f "$UNIT" "$PAM_SERVICE_FILE" "$FLAG"
    systemctl daemon-reload
    echo "Admin Panel DISABLED."
    ;;
esac

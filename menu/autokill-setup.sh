#!/bin/bash
# VPN-Starter-Kit :: menu/autokill-setup.sh
# Toggle automatic multilogin enforcement. When enabled, a cron job
# (autokill-check.sh) runs every 2 minutes and disables any SSH/SlowDNS
# account currently logged in from more devices than the configured limit.
set -uo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."; exit 1
fi

STATE_DIR="/etc/vpn-script"
FLAG="$STATE_DIR/autokill.enabled"
LIMIT_FILE="$STATE_DIR/autokill.limit"
CRON_FILE="/etc/cron.d/vpn-autokill"
CHECK_SCRIPT="/etc/vpn-script/menu/autokill-check.sh"

mkdir -p "$STATE_DIR" /var/log/vpn-script

if [[ -f "$FLAG" ]]; then
  echo "Autokill multilogin: ENABLED  (limit: $(cat "$LIMIT_FILE" 2>/dev/null || echo 1) device(s) per account)"
else
  echo "Autokill multilogin: DISABLED"
fi
echo ""
echo "  [1] Enable"
echo "  [2] Disable"
echo "  [0] Back"
read -rp "Choose: " opt

case "$opt" in
  1)
    read -rp "Max devices allowed per account [default 2]: " LIMIT
    LIMIT="${LIMIT:-2}"
    if ! [[ "$LIMIT" =~ ^[0-9]+$ ]] || [[ "$LIMIT" -lt 1 ]]; then
      echo "Invalid number, defaulting to 2."; LIMIT=2
    fi
    echo "$LIMIT" > "$LIMIT_FILE"
    touch "$FLAG"
    cat > "$CRON_FILE" <<EOF
*/2 * * * * root $CHECK_SCRIPT >> /var/log/vpn-script/autokill.log 2>&1
EOF
    chmod 644 "$CRON_FILE"
    systemctl restart cron >/dev/null 2>&1 || true
    echo "Autokill multilogin ENABLED — limit $LIMIT device(s), checked every 2 minutes."
    echo "Log: /var/log/vpn-script/autokill.log"
    ;;
  2)
    rm -f "$FLAG" "$CRON_FILE"
    systemctl restart cron >/dev/null 2>&1 || true
    echo "Autokill multilogin DISABLED."
    ;;
  0) exit 0 ;;
  *) echo "Invalid option." ;;
esac

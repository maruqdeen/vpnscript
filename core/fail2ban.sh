#!/bin/bash
# VPN-Starter-Kit :: core/fail2ban.sh
# Fail2ban brute-force protection for OpenSSH (port 22, the admin login —
# same sshd the dashboard's "SSH: Active" checks). Disabled by default.
# Only overrides `enabled`/thresholds in a jail.d drop-in — port/filter/
# logpath are left to fail2ban's own built-in [sshd] defaults rather than
# hardcoded here, since the exact auth-log path/backend can vary by
# distro version and getting that wrong would silently protect nothing.
# A 1-hour ban (not permanent) is deliberate: if the admin's own IP trips
# the filter, it self-clears instead of needing manual recovery.
# Usage: fail2ban.sh <enable|disable>
set -uo pipefail

if [[ $EUID -ne 0 ]]; then echo "Run as root."; exit 1; fi

ACTION="${1:-}"
INSTALL_DIR="/etc/vpn-script"
FLAG="$INSTALL_DIR/fail2ban.enabled"
JAIL_FILE="/etc/fail2ban/jail.d/vpn-script-sshd.conf"

case "$ACTION" in
  enable|disable) ;;
  *) echo "Usage: fail2ban.sh <enable|disable>"; exit 1 ;;
esac

if [[ "$ACTION" == "disable" ]]; then
  rm -f "$JAIL_FILE"
  systemctl disable --now fail2ban >/dev/null 2>&1 || true
  rm -f "$FLAG"
  echo "Fail2ban DISABLED."
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
command -v fail2ban-client >/dev/null 2>&1 || apt-get install -y fail2ban >/dev/null

mkdir -p /etc/fail2ban/jail.d
cat > "$JAIL_FILE" <<'EOF'
[sshd]
enabled  = true
maxretry = 5
findtime = 10m
bantime  = 1h
EOF

systemctl enable --now fail2ban >/dev/null 2>&1 || true
sleep 1
if systemctl is-active --quiet fail2ban; then
  touch "$FLAG"
  echo "Fail2ban ENABLED — protecting OpenSSH (port 22)."
  echo "  5 failed attempts within 10m -> 1h ban (self-clears, not permanent)"
  echo "  To always allow your own IP, add it to 'ignoreip' in $JAIL_FILE"
  echo "  then:  systemctl restart fail2ban"
else
  echo "ERROR: fail2ban failed to start. Check: journalctl -u fail2ban -n 30 --no-pager"
  exit 1
fi

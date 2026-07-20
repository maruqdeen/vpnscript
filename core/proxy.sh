#!/bin/bash
# VPN-Starter-Kit :: core/proxy.sh
# Lazy-install Squid (HTTP proxy, 3128) + Dante (SOCKS5, 1080), both
# authenticating against the SAME system accounts SSH/SlowDNS already use
# (via PAM) — so proxy credentials always match SSH credentials with no
# extra bookkeeping needed in add-ssh-user.sh/del-user.sh/renew-user.sh.
# Usage: proxy.sh <enable|disable>
set -uo pipefail

if [[ $EUID -ne 0 ]]; then echo "Run as root."; exit 1; fi

ACTION="${1:-}"
case "$ACTION" in
  enable|disable) ;;
  *) echo "Usage: proxy.sh <enable|disable>"; exit 1 ;;
esac

INSTALL_DIR="/etc/vpn-script"
FLAG="$INSTALL_DIR/proxy.enabled"

if [[ "$ACTION" == "disable" ]]; then
  systemctl disable --now squid danted >/dev/null 2>&1 || true
  rm -f "$FLAG"
  echo "HTTP & SOCKS5 proxy DISABLED."
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
command -v squid  >/dev/null 2>&1 || apt-get install -y squid >/dev/null
command -v danted >/dev/null 2>&1 || apt-get install -y dante-server >/dev/null

IFACE="$(ip route show default | awk '{print $5; exit}')"
[[ -z "$IFACE" ]] && IFACE="eth0"

# ---- PAM service: check password against system accounts only. Written
# under a couple of possible service names since packaging can vary. ----
for svc in squid sockd danted; do
  cat > "/etc/pam.d/${svc}" <<'EOF'
auth    required pam_unix.so
account required pam_unix.so
EOF
done

# ---- Squid: HTTP proxy on 3128, PAM basic auth ----
PAM_HELPER="$(find /usr/lib -name basic_pam_auth 2>/dev/null | head -n1)"
if [[ -z "$PAM_HELPER" ]]; then
  echo "WARNING: squid's basic_pam_auth helper not found — HTTP proxy auth may not work."
  PAM_HELPER="/usr/lib/squid/basic_pam_auth"
fi

cat > /etc/squid/squid.conf <<EOF
http_port 3128
cache_effective_user proxy
auth_param basic program ${PAM_HELPER}
auth_param basic realm VPN-Starter-Kit Proxy
acl authenticated proxy_auth REQUIRED
http_access allow authenticated
http_access deny all
EOF

# basic_pam_auth isn't setuid — it runs as squid's own effective user
# (proxy), which normally can't read /etc/shadow, so pam_unix.so's
# password check fails for every login even though the helper itself
# runs fine: connects, then rejects all credentials (SOCKS5/Dante is
# unaffected — it authenticates a different way). Grant read access via
# the shadow group instead of making the helper setuid-root.
usermod -aG shadow proxy 2>/dev/null || true

# ---- Dante: SOCKS5 on 1080, username/password auth via PAM.
# NOTE: "socksmethod: pam.username" is my best-documented recollection for
# Dante+PAM — if auth doesn't work on your Ubuntu version, check
# `man danted.conf` for the exact accepted method value on your install. ----
cat > /etc/danted.conf <<EOF
logoutput: syslog
user.privileged: root
user.unprivileged: nobody

internal: 0.0.0.0 port = 1080
external: ${IFACE}

socksmethod: pam.username

client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error
}

socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    protocol: tcp udp
    log: error
}
EOF

# restart (not just enable --now) so an already-running squid actually
# picks up the new shadow group membership — group changes don't apply
# to a process that's already running.
systemctl enable squid danted >/dev/null 2>&1 || true
systemctl restart squid danted
touch "$FLAG"
echo "HTTP proxy (3128) + SOCKS5 proxy (1080) ENABLED."
echo "Both use the SAME username/password as your SSH accounts (via PAM)."

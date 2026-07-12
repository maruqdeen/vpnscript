#!/bin/bash
# VPN-Starter-Kit :: core/tls.sh
# Provide a TLS cert at a STABLE path for nginx (443).
# Tries Let's Encrypt if a reachable domain is given; always falls back to
# self-signed so nginx can start no matter what.
# Usage: tls.sh <domain|"">
set -uo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."; exit 1
fi

DOMAIN="${1:-}"
CERT_DIR="/etc/vpn-script/tls"
mkdir -p "$CERT_DIR"

make_selfsigned() {
  echo ">>> Generating self-signed certificate..."
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -keyout "$CERT_DIR/privkey.pem" \
    -out    "$CERT_DIR/fullchain.pem" \
    -subj "/CN=${DOMAIN:-vpn.local}" >/dev/null 2>&1
  echo "    self-signed cert ready (fine for SSH-WS SSL/TLS mode)."
}

# No domain -> straight to self-signed.
if [[ -z "$DOMAIN" || "$DOMAIN" == "CHANGE_ME" ]]; then
  make_selfsigned
  exit 0
fi

echo ">>> Attempting Let's Encrypt for $DOMAIN ..."
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
apt-get install -y certbot >/dev/null 2>&1 || true

# Standalone challenge needs port 80 free for a moment.
systemctl stop nginx >/dev/null 2>&1 || true

if certbot certonly --standalone --non-interactive --agree-tos \
     --preferred-challenges http \
     -m "admin@${DOMAIN}" -d "$DOMAIN" 2>/tmp/certbot.err; then
  ln -sf "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" "$CERT_DIR/fullchain.pem"
  ln -sf "/etc/letsencrypt/live/${DOMAIN}/privkey.pem"   "$CERT_DIR/privkey.pem"
  echo "    Let's Encrypt cert installed for $DOMAIN."
  # reload nginx after future auto-renewals
  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  echo -e '#!/bin/bash\nsystemctl reload nginx' \
    > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
  chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
else
  echo "    Let's Encrypt failed — likely the domain isn't pointing straight"
  echo "    at this server (check A record / Cloudflare grey-cloud)."
  echo "    Details: $(tail -1 /tmp/certbot.err 2>/dev/null)"
  make_selfsigned
fi

systemctl start nginx >/dev/null 2>&1 || true


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
  local cn="${DOMAIN:-vpn.local}"
  local san
  if [[ -n "$DOMAIN" ]]; then
    san="subjectAltName=DNS:${DOMAIN}"
  else
    # No domain at all -- HOSTNAME_VAL in the config generators falls back
    # to the server's public IP in this case, so cover that too, not just
    # the DNS:vpn.local placeholder.
    local ip
    ip="$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null)"
    if [[ -n "$ip" ]]; then
      san="subjectAltName=DNS:vpn.local,IP:${ip}"
    else
      san="subjectAltName=DNS:vpn.local"
    fi
  fi
  # -subj alone (CN only, no SAN) produces a cert modern TLS clients
  # reject outright: SAN-based hostname matching has been required since
  # ~2017 (Go's crypto/x509 included -- what Xray-core/v2rayNG use), CN
  # is no longer honored as a fallback. A CN-only cert here fails with
  # "certificate is not valid for any names" even though CN matches --
  # confirmed live, this is exactly what broke VMess/VLESS/Trojan TLS
  # while older/more lenient clients (HTTP Injector etc.) kept working.
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -keyout "$CERT_DIR/privkey.pem" \
    -out    "$CERT_DIR/fullchain.pem" \
    -subj "/CN=${cn}" -addext "$san" >/dev/null 2>&1
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


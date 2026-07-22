#!/bin/bash
# VPN-Starter-Kit :: core/telegram-xray-actions.sh
# Non-interactive Xray (VMess/VLESS/Trojan) account creation for the
# Telegram User Bot to shell out to. Mirrors add-user.sh's actual UUID/
# config/link-building logic, but takes plain CLI args instead of
# `read -rp` prompts, and prints plain text instead of an ANSI card.
# Usage: telegram-xray-actions.sh create <vmess|vless|trojan> <username> <days>
set -uo pipefail

if [[ $EUID -ne 0 ]]; then echo "Run as root."; exit 1; fi

CONFIG="/usr/local/etc/xray/config.json"
DOMAIN_FILE="/etc/vpn-script/domain"

vmess_link() {
  local ps="$1" add="$2" port="$3" id="$4" net="$5" path="$6" tls="$7" json
  json=$(printf '{"v":"2","ps":"%s","add":"%s","port":"%s","id":"%s","aid":"0","scy":"auto","net":"%s","type":"none","host":"%s","path":"%s","tls":"%s","sni":"%s"}' \
    "$ps" "$add" "$port" "$id" "$net" "$add" "$path" "$tls" "$add")
  printf 'vmess://%s' "$(printf '%s' "$json" | base64 | tr -d '\n')"
}

vless_link() {
  local ps="$1" add="$2" port="$3" id="$4" net="$5" path="$6" security="$7" q
  q="encryption=none&security=${security}&type=${net}"
  if [[ "$net" == "grpc" ]]; then
    q="${q}&serviceName=${path}"
  else
    q="${q}&host=${add}&path=$(printf '%s' "$path" | sed 's|/|%2F|g')"
  fi
  [[ "$security" == "tls" ]] && q="${q}&sni=${add}"
  printf 'vless://%s@%s:%s?%s#%s' "$id" "$add" "$port" "$q" "$ps"
}

trojan_link() {
  local ps="$1" add="$2" port="$3" password="$4" net="$5" path="$6" q
  q="security=tls&type=${net}"
  if [[ "$net" == "grpc" ]]; then
    q="${q}&serviceName=${path}"
  else
    q="${q}&host=${add}&path=$(printf '%s' "$path" | sed 's|/|%2F|g')"
  fi
  q="${q}&sni=${add}"
  printf 'trojan://%s@%s:%s?%s#%s' "$password" "$add" "$port" "$q" "$ps"
}

ACTION="${1:-}"
[[ $# -gt 0 ]] && shift

case "$ACTION" in
  create)
    PROTOCOL="${1:-}"; USERNAME="${2:-}"; DAYS="${3:-}"
    case "$PROTOCOL" in
      vless|vmess|trojan) ;;
      *) echo "Usage: create <vless|vmess|trojan> <username> <days>"; exit 1 ;;
    esac
    if [[ -z "$USERNAME" || -z "$DAYS" ]]; then
      echo "Usage: create <vless|vmess|trojan> <username> <days>"; exit 1
    fi
    # no underscore: EMAIL_TAG splits on "_" to recover the username later,
    # so one in the username itself would corrupt that split.
    if ! [[ "$USERNAME" =~ ^[a-zA-Z0-9-]+$ ]]; then
      echo "Invalid username. Use letters, digits, and - only (no underscore)."; exit 1
    fi
    if ! [[ "$DAYS" =~ ^[0-9]+$ ]]; then echo "Expiry must be a number of days."; exit 1; fi
    if [[ ! -f "$CONFIG" ]]; then echo "Error: Xray config not found."; exit 1; fi

    if jq -e --arg proto "$PROTOCOL" --arg name "$USERNAME" '
        .inbounds[] | select(.protocol==$proto) | .settings.clients[]
        | select((.email | split("_")[0]) == $name)
      ' "$CONFIG" >/dev/null 2>&1; then
      echo "Error: user '$USERNAME' already exists on $PROTOCOL."; exit 1
    fi

    UUID=$(cat /proc/sys/kernel/random/uuid)
    EXPIRY=$(date -d "+${DAYS} days" +%Y-%m-%d)
    EMAIL_TAG="${USERNAME}_${EXPIRY}"

    case "$PROTOCOL" in
      vless)  CLIENT=$(jq -n --arg id "$UUID" --arg email "$EMAIL_TAG" '{id:$id, email:$email}') ;;
      vmess)  CLIENT=$(jq -n --arg id "$UUID" --arg email "$EMAIL_TAG" '{id:$id, alterId:0, email:$email}') ;;
      trojan) CLIENT=$(jq -n --arg password "$UUID" --arg email "$EMAIL_TAG" '{password:$password, email:$email}') ;;
    esac

    tmp=$(mktemp)
    jq --arg proto "$PROTOCOL" --argjson client "$CLIENT" '
      (.inbounds[] | select(.protocol==$proto) | .settings.clients) += [$client]
    ' "$CONFIG" > "$tmp" && chmod 644 "$tmp" && mv "$tmp" "$CONFIG"

    systemctl restart xray

    HOSTNAME_VAL="$(cat "$DOMAIN_FILE" 2>/dev/null)"
    [[ -z "$HOSTNAME_VAL" ]] && HOSTNAME_VAL="$(curl -s https://api.ipify.org || hostname -I | awk '{print $1}')"

    case "$PROTOCOL" in
    vmess)
      LINK_TLS="$(vmess_link "$USERNAME" "$HOSTNAME_VAL" "443" "$UUID" "ws" "/vmess" "tls")"
      LINK_PLAIN="$(vmess_link "$USERNAME" "$HOSTNAME_VAL" "80" "$UUID" "ws" "/vmess" "")"
      LINK_GRPC="$(vmess_link "$USERNAME" "$HOSTNAME_VAL" "443" "$UUID" "grpc" "vmess-grpc" "tls")"
      cat <<MSG
Xray/VMess account created
Remarks : ${USERNAME}
Domain  : ${HOSTNAME_VAL}
id      : ${UUID}
Expires : ${EXPIRY}

Link TLS      : ${LINK_TLS}
Link none TLS : ${LINK_PLAIN}
Link GRPC     : ${LINK_GRPC}
MSG
      ;;
    vless)
      LINK_TLS="$(vless_link "$USERNAME" "$HOSTNAME_VAL" "443" "$UUID" "ws" "/vless" "tls")"
      LINK_PLAIN="$(vless_link "$USERNAME" "$HOSTNAME_VAL" "80" "$UUID" "ws" "/vless" "none")"
      LINK_GRPC="$(vless_link "$USERNAME" "$HOSTNAME_VAL" "443" "$UUID" "grpc" "vless-grpc" "tls")"
      cat <<MSG
Xray/VLESS account created
Remarks : ${USERNAME}
Domain  : ${HOSTNAME_VAL}
id      : ${UUID}
Expires : ${EXPIRY}

Link TLS      : ${LINK_TLS}
Link none TLS : ${LINK_PLAIN}
Link GRPC     : ${LINK_GRPC}
MSG
      ;;
    trojan)
      LINK_TLS="$(trojan_link "$USERNAME" "$HOSTNAME_VAL" "443" "$UUID" "ws" "/trojan")"
      LINK_GRPC="$(trojan_link "$USERNAME" "$HOSTNAME_VAL" "443" "$UUID" "grpc" "trojan-grpc")"
      cat <<MSG
Xray/Trojan account created
Remarks  : ${USERNAME}
Domain   : ${HOSTNAME_VAL}
password : ${UUID}
Expires  : ${EXPIRY}

Link TLS  : ${LINK_TLS}
Link GRPC : ${LINK_GRPC}
MSG
      ;;
    esac
    ;;
  *)
    echo "Usage: telegram-xray-actions.sh create <vless|vmess|trojan> <username> <days>"
    exit 1
    ;;
esac

#!/bin/bash
# VPN-Starter-Kit :: core/telegram-xray-actions.sh
# Non-interactive Xray (VMess/VLESS/Trojan/Shadowsocks) account actions
# for the Telegram User Bot and the web admin panel to shell out to.
# Mirrors add-user.sh's actual UUID/config/link-building logic, but takes
# plain CLI args instead of `read -rp` prompts, and prints plain text
# suitable for relaying back as a Telegram message rather than an
# ANSI card (unless PANEL_JSON=1, see the `list` action).
# Usage:
#   telegram-xray-actions.sh create <vless|vmess|trojan|shadowsocks> <username> <days>
#   telegram-xray-actions.sh list <vless|vmess|trojan|shadowsocks>
#   telegram-xray-actions.sh delete <vless|vmess|trojan|shadowsocks> <username>
#   telegram-xray-actions.sh renew <vless|vmess|trojan|shadowsocks> <username> <days>
set -uo pipefail

if [[ $EUID -ne 0 ]]; then echo "Run as root."; exit 1; fi

CONFIG="/usr/local/etc/xray/config.json"
DOMAIN_FILE="/etc/vpn-script/domain"

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$BASE_DIR/xray-links.sh"

ACTION="${1:-}"
[[ $# -gt 0 ]] && shift

case "$ACTION" in
  create)
    PROTOCOL="${1:-}"; USERNAME="${2:-}"; DAYS="${3:-}"
    case "$PROTOCOL" in
      vless|vmess|trojan|shadowsocks) ;;
      *) echo "Usage: create <vless|vmess|trojan|shadowsocks> <username> <days>"; exit 1 ;;
    esac
    if [[ -z "$USERNAME" || -z "$DAYS" ]]; then
      echo "Usage: create <vless|vmess|trojan|shadowsocks> <username> <days>"; exit 1
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
      vless)       CLIENT=$(jq -n --arg id "$UUID" --arg email "$EMAIL_TAG" '{id:$id, email:$email}') ;;
      vmess)       CLIENT=$(jq -n --arg id "$UUID" --arg email "$EMAIL_TAG" '{id:$id, alterId:0, email:$email}') ;;
      trojan)      CLIENT=$(jq -n --arg password "$UUID" --arg email "$EMAIL_TAG" '{password:$password, email:$email}') ;;
      shadowsocks) CLIENT=$(jq -n --arg method "aes-256-gcm" --arg password "$UUID" --arg email "$EMAIL_TAG" '{method:$method, password:$password, email:$email}') ;;
    esac

    tmp=$(mktemp)
    jq --arg proto "$PROTOCOL" --argjson client "$CLIENT" '
      (.inbounds[] | select(.protocol==$proto) | .settings.clients) += [$client]
    ' "$CONFIG" > "$tmp" && chmod 644 "$tmp" && mv "$tmp" "$CONFIG"

    systemctl restart xray

    HOSTNAME_VAL="$(cat "$DOMAIN_FILE" 2>/dev/null)"
    [[ -z "$HOSTNAME_VAL" ]] && HOSTNAME_VAL="$(curl -s https://api.ipify.org || hostname -I | awk '{print $1}')"

    # No domain set -> HOSTNAME_VAL just fell back to the bare IP above, but
    # the TLS/GRPC links still get generated with strict TLS (no client ever
    # sets allowInsecure here) against whatever cert tls.sh actually issued --
    # a self-signed cert whose CN won't match a bare IP, so those links are
    # guaranteed to fail the handshake. Warn clearly instead of leaving that
    # as a silent "why won't this connect" mystery.
    NO_DOMAIN_WARNING=""
    TROJAN_NO_DOMAIN_WARNING=""
    if [[ -z "$(cat "$DOMAIN_FILE" 2>/dev/null)" ]]; then
      NO_DOMAIN_WARNING="
NOTE: No domain is set (Settings > Change Primary Domain) -- this
      server is using a self-signed cert over its bare IP. The TLS
      and GRPC links above will FAIL to connect (cert won't
      validate). Use the 'none TLS' link instead, or set a real
      domain and regenerate this account's config."
      TROJAN_NO_DOMAIN_WARNING="
NOTE: No domain is set (Settings > Change Primary Domain) -- Trojan
      requires a real domain + valid TLS cert to work at all (there
      is no plaintext fallback for this protocol). Set a domain,
      then regenerate this account's config."
    fi

    case "$PROTOCOL" in
    vmess)
      LINK_TLS="$(vmess_link "$USERNAME" "$HOSTNAME_VAL" "443" "$UUID" "ws" "/vmess" "tls")"
      LINK_PLAIN="$(vmess_link "$USERNAME" "$HOSTNAME_VAL" "80" "$UUID" "ws" "/vmess" "")"
      LINK_GRPC="$(vmess_link "$USERNAME" "$HOSTNAME_VAL" "443" "$UUID" "grpc" "vmess-grpc" "tls")"
      cat <<MSG
====================================
   Xray/Vmess Account
====================================
Remarks       : ${USERNAME}
Domain        : ${HOSTNAME_VAL}
Port TLS      : 443
Port none TLS : 80
Port GRPC     : 443
id            : ${UUID}
alterId       : 0
Security      : auto
Network       : ws
Path          : /vmess
ServiceName   : vmess-grpc
====================================
Link TLS      : ${LINK_TLS}
====================================
Link none TLS : ${LINK_PLAIN}
====================================
Link GRPC     : ${LINK_GRPC}
====================================
Expired On    : ${EXPIRY}
====================================${NO_DOMAIN_WARNING}
MSG
      ;;
    vless)
      LINK_TLS="$(vless_link "$USERNAME" "$HOSTNAME_VAL" "443" "$UUID" "ws" "/vless" "tls")"
      LINK_PLAIN="$(vless_link "$USERNAME" "$HOSTNAME_VAL" "80" "$UUID" "ws" "/vless" "none")"
      LINK_GRPC="$(vless_link "$USERNAME" "$HOSTNAME_VAL" "443" "$UUID" "grpc" "vless-grpc" "tls")"
      cat <<MSG
====================================
   Xray/Vless Account
====================================
Remarks       : ${USERNAME}
Domain        : ${HOSTNAME_VAL}
Port TLS      : 443
Port none TLS : 80
Port GRPC     : 443
id            : ${UUID}
Encryption    : none
Network       : ws
Path          : /vless
ServiceName   : vless-grpc
====================================
Link TLS      : ${LINK_TLS}
====================================
Link none TLS : ${LINK_PLAIN}
====================================
Link GRPC     : ${LINK_GRPC}
====================================
Expired On    : ${EXPIRY}
====================================${NO_DOMAIN_WARNING}
MSG
      ;;
    trojan)
      LINK_TLS="$(trojan_link "$USERNAME" "$HOSTNAME_VAL" "443" "$UUID" "ws" "/trojan")"
      LINK_GRPC="$(trojan_link "$USERNAME" "$HOSTNAME_VAL" "443" "$UUID" "grpc" "trojan-grpc")"
      cat <<MSG
====================================
   Xray/Trojan Account
====================================
Remarks       : ${USERNAME}
Domain        : ${HOSTNAME_VAL}
Port TLS      : 443
Port GRPC     : 443
password      : ${UUID}
Network       : ws
Path          : /trojan
ServiceName   : trojan-grpc
====================================
Link TLS      : ${LINK_TLS}
====================================
Link GRPC     : ${LINK_GRPC}
====================================
Expired On    : ${EXPIRY}
====================================${TROJAN_NO_DOMAIN_WARNING}
MSG
      ;;
    shadowsocks)
      LINK="$(ss_link "$USERNAME" "$HOSTNAME_VAL" "8388" "aes-256-gcm" "$UUID")"
      cat <<MSG
====================================
   Xray/Shadowsocks Account
====================================
Remarks       : ${USERNAME}
Domain        : ${HOSTNAME_VAL}
Port          : 8388
Method        : aes-256-gcm
password      : ${UUID}
====================================
Link          : ${LINK}
====================================
Expired On    : ${EXPIRY}
====================================
MSG
      ;;
    esac
    ;;

  list)
    PROTOCOL="${1:-}"
    case "$PROTOCOL" in
      vless|vmess|trojan|shadowsocks) ;;
      *) echo "Usage: list <vless|vmess|trojan|shadowsocks>"; exit 1 ;;
    esac
    if [[ ! -f "$CONFIG" ]]; then echo "Error: Xray config not found."; exit 1; fi

    # vmess/vless/trojan each have a WS + gRPC inbound sharing one client
    # list, so listing raw clients across .inbounds[] double-lists every
    # account; dedupe by email first. Shadowsocks has a single inbound,
    # so unique[] here is a harmless no-op for it.
    mapfile -t USERS < <(jq -r --arg p "$PROTOCOL" '
      [.inbounds[] | select(.protocol==$p) | .settings.clients[].email] | unique[]
    ' "$CONFIG" 2>/dev/null)

    if [[ "${PANEL_JSON:-0}" == "1" ]]; then
      {
        for u in "${USERS[@]}"; do
          [[ -z "$u" ]] && continue
          printf '%s\t%s\n' "${u%%_*}" "${u#*_}"
        done
      } | jq -R -s -c '
        (split("\n") | map(select(length > 0))) as $lines |
        {ok:true, users: [$lines[] | split("\t") | {username: .[0], expiry: .[1]}]}
      '
      exit 0
    fi

    if [[ ${#USERS[@]} -eq 0 ]]; then
      echo "(no $PROTOCOL accounts)"
      exit 0
    fi
    echo "$PROTOCOL accounts:"
    for u in "${USERS[@]}"; do
      [[ -z "$u" ]] && continue
      echo "- ${u%%_*}  (expires ${u#*_})"
    done
    ;;

  delete)
    PROTOCOL="${1:-}"; USERNAME="${2:-}"
    case "$PROTOCOL" in
      vless|vmess|trojan|shadowsocks) ;;
      *) echo "Usage: delete <vless|vmess|trojan|shadowsocks> <username>"; exit 1 ;;
    esac
    if [[ -z "$USERNAME" ]]; then echo "Usage: delete <vless|vmess|trojan|shadowsocks> <username>"; exit 1; fi
    if [[ ! -f "$CONFIG" ]]; then echo "Error: Xray config not found."; exit 1; fi

    MATCH="$(jq -r --arg p "$PROTOCOL" --arg name "$USERNAME" '
      [.inbounds[] | select(.protocol==$p) | .settings.clients[].email]
      | unique[] | select(split("_")[0] == $name)
    ' "$CONFIG" 2>/dev/null | head -n1)"
    if [[ -z "$MATCH" ]]; then
      echo "No $PROTOCOL user named '$USERNAME'."; exit 1
    fi

    tmp=$(mktemp)
    jq --arg p "$PROTOCOL" --arg email "$MATCH" '
      (.inbounds[] | select(.protocol==$p) | .settings.clients) |= map(select(.email != $email))
    ' "$CONFIG" > "$tmp" && chmod 644 "$tmp" && mv "$tmp" "$CONFIG"

    systemctl restart xray
    echo "Deleted $PROTOCOL user '${USERNAME}'."
    ;;

  renew)
    PROTOCOL="${1:-}"; USERNAME="${2:-}"; DAYS="${3:-}"
    case "$PROTOCOL" in
      vless|vmess|trojan|shadowsocks) ;;
      *) echo "Usage: renew <vless|vmess|trojan|shadowsocks> <username> <days>"; exit 1 ;;
    esac
    if [[ -z "$USERNAME" || -z "$DAYS" ]]; then
      echo "Usage: renew <vless|vmess|trojan|shadowsocks> <username> <days>"; exit 1
    fi
    if ! [[ "$DAYS" =~ ^[0-9]+$ ]]; then echo "Days must be a number."; exit 1; fi
    if [[ ! -f "$CONFIG" ]]; then echo "Error: Xray config not found."; exit 1; fi

    MATCH="$(jq -r --arg p "$PROTOCOL" --arg name "$USERNAME" '
      [.inbounds[] | select(.protocol==$p) | .settings.clients[].email]
      | unique[] | select(split("_")[0] == $name)
    ' "$CONFIG" 2>/dev/null | head -n1)"
    if [[ -z "$MATCH" ]]; then
      echo "No $PROTOCOL user named '$USERNAME'."; exit 1
    fi

    NEW_EXP=$(date -d "+${DAYS} days" +%Y-%m-%d)
    NEW_EMAIL="${USERNAME}_${NEW_EXP}"

    tmp=$(mktemp)
    jq --arg p "$PROTOCOL" --arg old "$MATCH" --arg new "$NEW_EMAIL" '
      (.inbounds[] | select(.protocol==$p) | .settings.clients[]
       | select(.email==$old) | .email) = $new
    ' "$CONFIG" > "$tmp" && chmod 644 "$tmp" && mv "$tmp" "$CONFIG"

    # No restart here, unlike create/delete: .email is a display/expiry-
    # tracking label only (parsed back out as "username_expirydate" by
    # list/renew/delete), never used for auth or routing -- the live
    # process doesn't need to know it changed, so restarting here would
    # only drop every connected Xray client for nothing.
    echo "Renewed $PROTOCOL user '${USERNAME}' -> expires ${NEW_EXP}."
    ;;

  *)
    echo "Usage: telegram-xray-actions.sh <create|list|delete|renew> <vless|vmess|trojan|shadowsocks> ..."
    exit 1
    ;;
esac

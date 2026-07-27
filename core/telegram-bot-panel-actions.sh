#!/bin/bash
# VPN-Starter-Kit :: core/telegram-bot-panel-actions.sh
# Non-interactive connect/disconnect/status for both Telegram bots, and
# the User Bot's Control Access toggles, for the web admin panel to
# shell out to. Logic is extracted verbatim from menu/telegram-bot-setup.sh
# and menu/telegram-user-bot-setup.sh -- those two files are untouched
# and still the bash menu's own call path; this is a second, panel-only
# caller of the same underlying mechanics (systemd unit, claim code,
# access.json), not a replacement.
# Usage:
#   telegram-bot-panel-actions.sh admin-status
#   telegram-bot-panel-actions.sh admin-connect <token>
#   telegram-bot-panel-actions.sh admin-disconnect
#   telegram-bot-panel-actions.sh user-status
#   telegram-bot-panel-actions.sh user-connect <token>
#   telegram-bot-panel-actions.sh user-disconnect
#   telegram-bot-panel-actions.sh user-access-get
#   telegram-bot-panel-actions.sh user-access-toggle <key>
set -uo pipefail

if [[ $EUID -ne 0 ]]; then echo "Run as root."; exit 1; fi

INSTALL_DIR="/etc/vpn-script"

ADMIN_TOKEN_FILE="$INSTALL_DIR/telegram-bot-token"
ADMIN_ID_FILE="$INSTALL_DIR/telegram-admin-id"
ADMIN_CLAIM_FILE="$INSTALL_DIR/telegram-bot-claim.json"
ADMIN_FLAG="$INSTALL_DIR/telegram-bot.enabled"
ADMIN_UNIT="/etc/systemd/system/vpn-telegram-bot.service"
CLAIM_TTL_SECONDS=300

USER_TOKEN_FILE="$INSTALL_DIR/telegram-user-bot-token"
USER_FLAG="$INSTALL_DIR/telegram-user-bot.enabled"
USER_UNIT="/etc/systemd/system/vpn-telegram-user-bot.service"
ACCESS_FILE="$INSTALL_DIR/telegram-user-bot-access.json"
ACCESS_KEYS=(ssh vmess vless trojan wireguard)

access_ensure_file() {
  [[ -f "$ACCESS_FILE" ]] || echo '{"ssh":true,"vmess":true,"vless":true,"trojan":true,"wireguard":true}' > "$ACCESS_FILE"
}

access_get() {
  access_ensure_file
  jq -r --arg k "$1" '(.[$k]) as $v | if $v == null then true else $v end' "$ACCESS_FILE" 2>/dev/null
}

ACTION="${1:-}"
[[ $# -gt 0 ]] && shift

case "$ACTION" in
  admin-status)
    if [[ ! -f "$ADMIN_FLAG" ]]; then
      jq -n '{ok:true, status:"not_connected"}'
      exit 0
    fi
    bot_username="$(curl -s "https://api.telegram.org/bot$(cat "$ADMIN_TOKEN_FILE" 2>/dev/null)/getMe" 2>/dev/null \
      | jq -r '.result.username // "unknown"' 2>/dev/null)"
    if [[ -f "$ADMIN_ID_FILE" ]]; then
      jq -n --arg u "$bot_username" '{ok:true, status:"connected", bot_username:$u}'
    elif [[ -f "$ADMIN_CLAIM_FILE" ]] && (( $(jq -r '.expires' "$ADMIN_CLAIM_FILE" 2>/dev/null || echo 0) > $(date +%s) )); then
      remaining=$(( $(jq -r '.expires' "$ADMIN_CLAIM_FILE") - $(date +%s) ))
      code="$(jq -r '.code' "$ADMIN_CLAIM_FILE")"
      jq -n --arg u "$bot_username" --arg c "$code" --argjson r "$remaining" \
        '{ok:true, status:"waiting_claim", bot_username:$u, code:$c, remaining_seconds:$r}'
    else
      jq -n --arg u "$bot_username" '{ok:true, status:"unclaimed", bot_username:$u}'
    fi
    ;;

  admin-connect)
    BOT_TOKEN="${1:-}"
    if [[ -z "$BOT_TOKEN" ]]; then echo "Bot token cannot be empty."; exit 1; fi

    echo ">>> Verifying bot token..."
    ME_RESP="$(curl -s "https://api.telegram.org/bot${BOT_TOKEN}/getMe")"
    if ! echo "$ME_RESP" | jq -e '.ok == true' >/dev/null 2>&1; then
      echo "ERROR: Telegram rejected this bot token."
      echo "$ME_RESP"
      exit 1
    fi
    BOT_USERNAME="$(echo "$ME_RESP" | jq -r '.result.username')"
    echo "    Token OK -- bot is @${BOT_USERNAME}"

    echo "$BOT_TOKEN" > "$ADMIN_TOKEN_FILE"; chmod 600 "$ADMIN_TOKEN_FILE"
    rm -f "$ADMIN_ID_FILE"

    CODE="$(LC_ALL=C tr -dc 'A-HJ-NP-Z2-9' < /dev/urandom 2>/dev/null | head -c 8)"
    if [[ -z "$CODE" ]]; then
      echo "ERROR: could not generate a claim code (no /dev/urandom?)."
      exit 1
    fi
    EXPIRES=$(( $(date +%s) + CLAIM_TTL_SECONDS ))
    jq -n --arg code "$CODE" --argjson exp "$EXPIRES" '{code: $code, expires: $exp}' > "$ADMIN_CLAIM_FILE"
    chmod 600 "$ADMIN_CLAIM_FILE"

    cat > "$ADMIN_UNIT" <<'EOF'
[Unit]
Description=Telegram Bot Remote Control (VPN-Starter-Kit)
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /etc/vpn-script/core/telegram-bot.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable vpn-telegram-bot >/dev/null 2>&1 || true
    systemctl restart vpn-telegram-bot

    sleep 1
    if systemctl is-active --quiet vpn-telegram-bot; then
      touch "$ADMIN_FLAG"
      echo ""
      echo "Bot is running. To finish connecting:"
      echo "  1. Open https://t.me/${BOT_USERNAME}"
      echo "  2. Send this message to the bot:  ${CODE}"
      echo "  (expires in $(( CLAIM_TTL_SECONDS / 60 )) minutes -- whoever sends it becomes the admin)"
    else
      echo "ERROR: vpn-telegram-bot failed to start. Check: journalctl -u vpn-telegram-bot -n 30 --no-pager"
      exit 1
    fi
    ;;

  admin-disconnect)
    systemctl disable --now vpn-telegram-bot >/dev/null 2>&1 || true
    rm -f "$ADMIN_UNIT" "$ADMIN_TOKEN_FILE" "$ADMIN_ID_FILE" "$ADMIN_CLAIM_FILE" "$ADMIN_FLAG"
    systemctl daemon-reload
    echo "Telegram Admin Bot disconnected and credentials removed."
    ;;

  user-status)
    if [[ ! -f "$USER_FLAG" ]]; then
      jq -n '{ok:true, status:"not_connected"}'
      exit 0
    fi
    bot_username="$(curl -s "https://api.telegram.org/bot$(cat "$USER_TOKEN_FILE" 2>/dev/null)/getMe" 2>/dev/null \
      | jq -r '.result.username // "unknown"' 2>/dev/null)"
    jq -n --arg u "$bot_username" '{ok:true, status:"connected", bot_username:$u}'
    ;;

  user-connect)
    BOT_TOKEN="${1:-}"
    if [[ -z "$BOT_TOKEN" ]]; then echo "Bot token cannot be empty."; exit 1; fi

    echo ">>> Verifying bot token..."
    ME_RESP="$(curl -s "https://api.telegram.org/bot${BOT_TOKEN}/getMe")"
    if ! echo "$ME_RESP" | jq -e '.ok == true' >/dev/null 2>&1; then
      echo "ERROR: Telegram rejected this bot token."
      echo "$ME_RESP"
      exit 1
    fi
    BOT_USERNAME="$(echo "$ME_RESP" | jq -r '.result.username')"
    echo "    Token OK -- bot is @${BOT_USERNAME}"

    if [[ -f "$ADMIN_TOKEN_FILE" ]] && [[ "$(cat "$ADMIN_TOKEN_FILE" 2>/dev/null)" == "$BOT_TOKEN" ]]; then
      echo "ERROR: this is the same token as your Admin Bot. Create a separate"
      echo "bot with @BotFather for the User Bot -- they must be different bots."
      exit 1
    fi

    echo "$BOT_TOKEN" > "$USER_TOKEN_FILE"; chmod 600 "$USER_TOKEN_FILE"

    cat > "$USER_UNIT" <<'EOF'
[Unit]
Description=Telegram User Bot - Self-Service Accounts (VPN-Starter-Kit)
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /etc/vpn-script/core/telegram-user-bot.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable vpn-telegram-user-bot >/dev/null 2>&1 || true
    systemctl restart vpn-telegram-user-bot

    sleep 1
    if systemctl is-active --quiet vpn-telegram-user-bot; then
      touch "$USER_FLAG"
      echo ""
      echo "User Bot connected and running."
      echo "Share this with your customers: https://t.me/${BOT_USERNAME}"
    else
      echo "ERROR: vpn-telegram-user-bot failed to start. Check: journalctl -u vpn-telegram-user-bot -n 30 --no-pager"
      exit 1
    fi
    ;;

  user-disconnect)
    systemctl disable --now vpn-telegram-user-bot >/dev/null 2>&1 || true
    rm -f "$USER_UNIT" "$USER_TOKEN_FILE" "$USER_FLAG"
    systemctl daemon-reload
    echo "User Bot disconnected and credentials removed."
    ;;

  user-access-get)
    access_ensure_file
    {
      for k in "${ACCESS_KEYS[@]}"; do
        printf '%s\t%s\n' "$k" "$(access_get "$k")"
      done
    } | jq -R -s -c '
      (split("\n") | map(select(length > 0))) as $lines |
      {ok:true, access: ([$lines[] | split("\t") | {(.[0]): (.[1]=="true")}] | add)}
    '
    ;;

  user-access-toggle)
    KEY="${1:-}"
    if [[ -z "$KEY" ]]; then echo "Usage: user-access-toggle <key>"; exit 1; fi
    valid=false
    for k in "${ACCESS_KEYS[@]}"; do [[ "$k" == "$KEY" ]] && valid=true; done
    if [[ "$valid" != "true" ]]; then echo "Unknown access key '$KEY'."; exit 1; fi

    access_ensure_file
    current="$(access_get "$KEY")"
    tmp=$(mktemp)
    jq --arg k "$KEY" --argjson v "$( [[ "$current" == "true" ]] && echo false || echo true )" \
      '.[$k] = $v' "$ACCESS_FILE" > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$ACCESS_FILE"
    new_state="$(access_get "$KEY")"
    if [[ "$new_state" == "true" ]]; then
      echo "$KEY is now Allowed."
    else
      echo "$KEY is now Disallowed."
    fi
    ;;

  *)
    echo "Usage: telegram-bot-panel-actions.sh <admin-status|admin-connect|admin-disconnect|user-status|user-connect|user-disconnect|user-access-get|user-access-toggle> ..."
    exit 1
    ;;
esac

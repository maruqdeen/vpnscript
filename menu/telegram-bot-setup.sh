#!/bin/bash
# VPN-Starter-Kit :: menu/telegram-bot-setup.sh
# Connect/disconnect the Telegram remote-control bot (core/telegram-bot.py).
# Admin identity is established via a short-lived claim code rather than a
# manually-entered numeric ID (which needed a third-party bot to look up):
# whoever sends the exact code to the bot within the time window becomes
# the permanent admin. See core/telegram-bot.py's module docstring for why
# this is safer than a plain "first message wins" scheme.
set -uo pipefail

if [[ $EUID -ne 0 ]]; then echo "Run as root."; exit 1; fi

INSTALL_DIR="/etc/vpn-script"
TOKEN_FILE="$INSTALL_DIR/telegram-bot-token"
ADMIN_ID_FILE="$INSTALL_DIR/telegram-admin-id"
CLAIM_FILE="$INSTALL_DIR/telegram-bot-claim.json"
FLAG="$INSTALL_DIR/telegram-bot.enabled"
UNIT="/etc/systemd/system/vpn-telegram-bot.service"
CLAIM_TTL_SECONDS=300

connect() {
  echo "This connects a Telegram bot so you can manage SSH accounts remotely."
  echo "You'll need a bot token from @BotFather (create a bot, it gives you a token)."
  echo ""
  read -rp "Bot Token: " BOT_TOKEN

  if [[ -z "$BOT_TOKEN" ]]; then echo "Bot token cannot be empty."; return 1; fi

  echo ""
  echo ">>> Verifying bot token..."
  ME_RESP="$(curl -s "https://api.telegram.org/bot${BOT_TOKEN}/getMe")"
  if ! echo "$ME_RESP" | jq -e '.ok == true' >/dev/null 2>&1; then
    echo "ERROR: Telegram rejected this bot token."
    echo "$ME_RESP"
    return 1
  fi
  BOT_USERNAME="$(echo "$ME_RESP" | jq -r '.result.username')"
  echo "    Token OK -- bot is @${BOT_USERNAME}"

  echo "$BOT_TOKEN" > "$TOKEN_FILE"; chmod 600 "$TOKEN_FILE"
  # a fresh connect always starts a new claim -- if someone was already
  # claimed, this intentionally requires re-claiming with the new code.
  rm -f "$ADMIN_ID_FILE"

  # unambiguous alphabet (no 0/O/1/I) -- easier to read and type correctly.
  # LC_ALL=C is required: under a UTF-8 locale (the Ubuntu default), tr
  # tries to interpret raw /dev/urandom bytes as UTF-8 text, hits an
  # invalid byte sequence, errors out, and silently produces NO output at
  # all -- an empty claim code that could never be matched by anyone.
  CODE="$(LC_ALL=C tr -dc 'A-HJ-NP-Z2-9' < /dev/urandom 2>/dev/null | head -c 8)"
  if [[ -z "$CODE" ]]; then
    echo "ERROR: could not generate a claim code (no /dev/urandom?)."
    return 1
  fi
  EXPIRES=$(( $(date +%s) + CLAIM_TTL_SECONDS ))
  jq -n --arg code "$CODE" --argjson exp "$EXPIRES" '{code: $code, expires: $exp}' > "$CLAIM_FILE"
  chmod 600 "$CLAIM_FILE"

  cat > "$UNIT" <<'EOF'
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
    touch "$FLAG"
    echo ""
    echo "Bot is running. To finish connecting:"
    echo "  1. Open https://t.me/${BOT_USERNAME}"
    echo "  2. Send this message to the bot:  ${CODE}"
    echo "  (expires in $(( CLAIM_TTL_SECONDS / 60 )) minutes -- whoever sends it becomes the admin)"
  else
    echo "ERROR: vpn-telegram-bot failed to start. Check: journalctl -u vpn-telegram-bot -n 30 --no-pager"
    return 1
  fi
}

disconnect() {
  systemctl disable --now vpn-telegram-bot >/dev/null 2>&1 || true
  rm -f "$UNIT" "$TOKEN_FILE" "$ADMIN_ID_FILE" "$CLAIM_FILE" "$FLAG"
  systemctl daemon-reload
  echo "Telegram bot disconnected and credentials removed."
}

if [[ -f "$FLAG" ]]; then
  BOT_USERNAME="$(curl -s "https://api.telegram.org/bot$(cat "$TOKEN_FILE" 2>/dev/null)/getMe" 2>/dev/null \
    | jq -r '.result.username // "unknown"' 2>/dev/null)"
  if [[ -f "$ADMIN_ID_FILE" ]]; then
    echo "Telegram Bot: CONNECTED (https://t.me/${BOT_USERNAME})"
  elif [[ -f "$CLAIM_FILE" ]] && (( $(jq -r '.expires' "$CLAIM_FILE" 2>/dev/null || echo 0) > $(date +%s) )); then
    REMAINING=$(( $(jq -r '.expires' "$CLAIM_FILE") - $(date +%s) ))
    CODE="$(jq -r '.code' "$CLAIM_FILE")"
    echo "Telegram Bot: WAITING FOR CLAIM (https://t.me/${BOT_USERNAME})"
    echo "  Send this code within ${REMAINING}s to become admin: ${CODE}"
  else
    echo "Telegram Bot: RUNNING BUT UNCLAIMED (https://t.me/${BOT_USERNAME}) -- claim code expired, reconnect to generate a new one"
  fi
else
  echo "Telegram Bot: NOT CONNECTED"
fi
echo ""
echo "  [1] Connect / Reconnect"
echo "  [2] Disconnect"
echo "  [0] Back"
read -rp "Choose: " opt
case "$opt" in
  1) connect ;;
  2) disconnect ;;
  0) exit 0 ;;
  *) echo "Invalid option." ;;
esac

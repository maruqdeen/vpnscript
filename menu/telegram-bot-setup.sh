#!/bin/bash
# VPN-Starter-Kit :: menu/telegram-bot-setup.sh
# Connect/disconnect the Telegram remote-control bot (core/telegram-bot.py).
set -uo pipefail

if [[ $EUID -ne 0 ]]; then echo "Run as root."; exit 1; fi

INSTALL_DIR="/etc/vpn-script"
TOKEN_FILE="$INSTALL_DIR/telegram-bot-token"
ADMIN_ID_FILE="$INSTALL_DIR/telegram-admin-id"
FLAG="$INSTALL_DIR/telegram-bot.enabled"
UNIT="/etc/systemd/system/vpn-telegram-bot.service"

connect() {
  echo "This connects a Telegram bot so you can manage SSH accounts remotely."
  echo "You'll need:"
  echo "  1. A bot token from @BotFather (create a bot, it gives you a token)"
  echo "  2. Your own numeric Telegram user ID (message @userinfobot to get it)"
  echo "  3. You must message YOUR bot at least once first -- Telegram bots"
  echo "     can't send the first message to a user who has never messaged them."
  echo ""
  read -rp "Bot Token: " BOT_TOKEN
  read -rp "Your Telegram ID (numeric): " ADMIN_ID

  if [[ -z "$BOT_TOKEN" ]]; then echo "Bot token cannot be empty."; return 1; fi
  if ! [[ "$ADMIN_ID" =~ ^[0-9]+$ ]]; then echo "Telegram ID must be numeric."; return 1; fi

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

  echo ">>> Sending a test message to your Telegram ID..."
  SEND_RESP="$(curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${ADMIN_ID}" \
    --data-urlencode "text=VPN-Starter-Kit bot connected. Send /help to see available commands.")"
  if ! echo "$SEND_RESP" | jq -e '.ok == true' >/dev/null 2>&1; then
    echo "ERROR: could not send a message to that Telegram ID."
    echo "$SEND_RESP"
    echo "Make sure you've started a chat with @${BOT_USERNAME} first."
    return 1
  fi
  echo "    Test message sent -- check your Telegram."

  echo "$BOT_TOKEN" > "$TOKEN_FILE"; chmod 600 "$TOKEN_FILE"
  echo "$ADMIN_ID" > "$ADMIN_ID_FILE"; chmod 600 "$ADMIN_ID_FILE"

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
  systemctl enable --now vpn-telegram-bot >/dev/null 2>&1 || true

  sleep 1
  if systemctl is-active --quiet vpn-telegram-bot; then
    touch "$FLAG"
    echo ""
    echo "Telegram bot connected and running."
    echo "Send /help to @${BOT_USERNAME} to get started."
  else
    echo "ERROR: vpn-telegram-bot failed to start. Check: journalctl -u vpn-telegram-bot -n 30 --no-pager"
    return 1
  fi
}

disconnect() {
  systemctl disable --now vpn-telegram-bot >/dev/null 2>&1 || true
  rm -f "$UNIT" "$TOKEN_FILE" "$ADMIN_ID_FILE" "$FLAG"
  systemctl daemon-reload
  echo "Telegram bot disconnected and credentials removed."
}

if [[ -f "$FLAG" ]]; then
  BOT_USERNAME="$(curl -s "https://api.telegram.org/bot$(cat "$TOKEN_FILE" 2>/dev/null)/getMe" 2>/dev/null \
    | jq -r '.result.username // "unknown"' 2>/dev/null)"
  echo "Telegram Bot: CONNECTED (@${BOT_USERNAME})"
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

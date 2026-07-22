#!/bin/bash
# VPN-Starter-Kit :: menu/telegram-user-bot-setup.sh
# Connect/disconnect the Telegram self-service User Bot
# (core/telegram-user-bot.py) -- a separate bot/token from the Admin Bot.
# No claim code here: this bot is deliberately open to anyone who messages
# it (that's the point -- customers self-serve their own account), so
# there's no admin identity to establish.
set -uo pipefail

if [[ $EUID -ne 0 ]]; then echo "Run as root."; exit 1; fi

INSTALL_DIR="/etc/vpn-script"
TOKEN_FILE="$INSTALL_DIR/telegram-user-bot-token"
FLAG="$INSTALL_DIR/telegram-user-bot.enabled"
UNIT="/etc/systemd/system/vpn-telegram-user-bot.service"

connect() {
  echo "This connects a SEPARATE Telegram bot for self-service account"
  echo "creation -- anyone who messages it can create themselves a free"
  echo "account (7-day expiry, SSH/VMess/VLESS/Trojan/WireGuard). It is"
  echo "NOT the same bot as your Admin Bot, and has no admin/claim step."
  echo ""
  read -rp "User Bot Token (from @BotFather, a DIFFERENT bot than your admin one): " BOT_TOKEN

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

  ADMIN_TOKEN_FILE="$INSTALL_DIR/telegram-bot-token"
  if [[ -f "$ADMIN_TOKEN_FILE" ]] && [[ "$(cat "$ADMIN_TOKEN_FILE" 2>/dev/null)" == "$BOT_TOKEN" ]]; then
    echo "ERROR: this is the same token as your Admin Bot. Create a separate"
    echo "bot with @BotFather for the User Bot -- they must be different bots."
    return 1
  fi

  echo "$BOT_TOKEN" > "$TOKEN_FILE"; chmod 600 "$TOKEN_FILE"

  cat > "$UNIT" <<'EOF'
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
    touch "$FLAG"
    echo ""
    echo "User Bot connected and running."
    echo "Share this with your customers: https://t.me/${BOT_USERNAME}"
  else
    echo "ERROR: vpn-telegram-user-bot failed to start. Check: journalctl -u vpn-telegram-user-bot -n 30 --no-pager"
    return 1
  fi
}

disconnect() {
  systemctl disable --now vpn-telegram-user-bot >/dev/null 2>&1 || true
  rm -f "$UNIT" "$TOKEN_FILE" "$FLAG"
  systemctl daemon-reload
  echo "User Bot disconnected and credentials removed."
}

if [[ -f "$FLAG" ]]; then
  BOT_USERNAME="$(curl -s "https://api.telegram.org/bot$(cat "$TOKEN_FILE" 2>/dev/null)/getMe" 2>/dev/null \
    | jq -r '.result.username // "unknown"' 2>/dev/null)"
  echo "User Bot: CONNECTED (https://t.me/${BOT_USERNAME})"
else
  echo "User Bot: NOT CONNECTED"
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

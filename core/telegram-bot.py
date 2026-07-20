#!/usr/bin/env python3
# VPN-Starter-Kit :: core/telegram-bot.py
# Long-polls the Telegram Bot API and executes account-management
# commands sent by the configured admin ONLY -- every other chat ID is
# silently ignored, since this bot can create/delete real VPN accounts.
# stdlib only (urllib), matching ws.py/ohp.py's no-pip-dependency style.
#
# Admin identity is established via a claim code, not a manually-entered
# numeric ID: menu/telegram-bot-setup.sh generates a short-lived random
# code and shows it to whoever has shell access to the server; the first
# chat to send that exact code becomes the permanent admin, and the code
# is deleted immediately after a successful claim (single-use). This is
# deliberately NOT "whoever messages first wins" -- that would let anyone
# who discovers the bot's username race the real owner to claim it. The
# code is the actual credential; only someone with server access ever
# sees it.

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

INSTALL_DIR = "/etc/vpn-script"
TOKEN_FILE = f"{INSTALL_DIR}/telegram-bot-token"
ADMIN_ID_FILE = f"{INSTALL_DIR}/telegram-admin-id"
CLAIM_FILE = f"{INSTALL_DIR}/telegram-bot-claim.json"
SSH_ACTIONS = f"{INSTALL_DIR}/core/telegram-ssh-actions.sh"

POLL_TIMEOUT = 30       # seconds, Telegram long-poll wait
MAX_REPLY_LEN = 4000    # stay under Telegram's 4096-char message limit


def _read(path):
    with open(path) as f:
        return f.read().strip()


def _read_admin_id():
    try:
        return _read(ADMIN_ID_FILE)
    except OSError:
        return None


def _read_claim():
    try:
        with open(CLAIM_FILE) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return None


def try_claim(token, chat_id, text):
    """If awaiting a claim and this message carries the correct, still-valid
    code, register chat_id as the permanent admin and confirm. Returns the
    newly-claimed admin_id, or None if this message didn't claim anything."""
    claim = _read_claim()
    if not claim:
        return None
    if time.time() > claim.get("expires", 0):
        return None
    if text.strip() != claim.get("code"):
        return None

    with open(ADMIN_ID_FILE, "w") as f:
        f.write(chat_id)
    os.chmod(ADMIN_ID_FILE, 0o600)
    try:
        os.remove(CLAIM_FILE)
    except OSError:
        pass

    send_message(token, chat_id,
                 "You're now the admin of this bot. Send /help to see available commands.")
    return chat_id


def api_call(token, method, params=None, timeout=35):
    url = f"https://api.telegram.org/bot{token}/{method}"
    data = urllib.parse.urlencode(params).encode() if params is not None else None
    req = urllib.request.Request(url, data=data)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode())


def send_message(token, chat_id, text):
    text = text[:MAX_REPLY_LEN]
    try:
        api_call(token, "sendMessage", {"chat_id": chat_id, "text": text})
    except Exception as e:
        sys.stderr.write(f"sendMessage failed: {e}\n")


def run_action(*args):
    try:
        proc = subprocess.run(
            ["bash", SSH_ACTIONS, *args],
            capture_output=True, text=True, timeout=60,
        )
        out = (proc.stdout or "") + (proc.stderr or "")
        return out.strip() or "(no output)"
    except subprocess.TimeoutExpired:
        return "Command timed out."
    except Exception as e:
        return f"Error running command: {e}"


def run_status():
    try:
        proc = subprocess.run(
            ["bash", "-c",
             "uptime -p; echo ---; "
             "systemctl is-active ssh nginx dropbear xray ws-proxy ohp-proxy 2>/dev/null"],
            capture_output=True, text=True, timeout=15,
        )
        return (proc.stdout or "").strip() or "(no output)"
    except Exception as e:
        return f"Error: {e}"


HELP_TEXT = """VPN-Starter-Kit bot -- available commands:

/status - server status summary
/createssh <username> <password> <days> [conn_limit] [bw_limit_gb]
/listssh - list SSH accounts
/deletessh <username>
/renewssh <username> <days>
/help - show this message
"""


def handle_command(token, chat_id, text):
    parts = text.strip().split()
    if not parts:
        return
    cmd = parts[0].split("@")[0].lower()  # strip "/cmd@botname" (group chats)
    args = parts[1:]

    if cmd in ("/start", "/help"):
        send_message(token, chat_id, HELP_TEXT)
    elif cmd == "/status":
        send_message(token, chat_id, run_status())
    elif cmd == "/createssh":
        send_message(token, chat_id, run_action("create", *args))
    elif cmd == "/listssh":
        send_message(token, chat_id, run_action("list"))
    elif cmd == "/deletessh":
        send_message(token, chat_id, run_action("delete", *args))
    elif cmd == "/renewssh":
        send_message(token, chat_id, run_action("renew", *args))
    else:
        send_message(token, chat_id, f"Unknown command: {cmd}\n\n{HELP_TEXT}")


def flush_backlog(token):
    """Discard any updates queued while the bot was offline, so a restart
    doesn't suddenly execute a pile of backlogged commands at once."""
    try:
        resp = api_call(token, "getUpdates", {"timeout": 0}, timeout=10)
        results = resp.get("result", [])
        if results:
            last_id = results[-1]["update_id"]
            api_call(token, "getUpdates", {"offset": last_id + 1, "timeout": 0}, timeout=10)
            return last_id + 1
    except Exception as e:
        sys.stderr.write(f"flush_backlog failed: {e}\n")
    return 0


def main():
    token = _read(TOKEN_FILE)
    admin_id = _read_admin_id()  # None until someone successfully claims

    me = api_call(token, "getMe", timeout=15)
    if not me.get("ok"):
        sys.stderr.write(f"getMe failed: {me}\n")
        sys.exit(1)
    state = f"admin_id={admin_id}" if admin_id else "awaiting claim"
    sys.stdout.write(f"Telegram bot @{me['result']['username']} starting, {state}\n")
    sys.stdout.flush()

    offset = flush_backlog(token)

    while True:
        try:
            resp = api_call(
                token, "getUpdates",
                {"offset": offset, "timeout": POLL_TIMEOUT},
                timeout=POLL_TIMEOUT + 10,
            )
        except Exception as e:
            sys.stderr.write(f"poll error: {e}\n")
            time.sleep(5)
            continue

        if not resp.get("ok"):
            sys.stderr.write(f"getUpdates not ok: {resp}\n")
            time.sleep(5)
            continue

        for update in resp.get("result", []):
            offset = update["update_id"] + 1
            msg = update.get("message") or update.get("edited_message")
            if not msg:
                continue
            chat_id = str(msg.get("chat", {}).get("id", ""))
            text = msg.get("text", "")
            if not text:
                continue

            if admin_id is None:
                claimed = try_claim(token, chat_id, text)
                if claimed:
                    admin_id = claimed
                continue  # not yet an admin -- every message is claim-only

            if chat_id != admin_id:
                continue  # not the configured admin -- ignore silently
            try:
                handle_command(token, chat_id, text)
            except Exception as e:
                sys.stderr.write(f"handle_command error: {e}\n")
                send_message(token, chat_id, f"Internal error: {e}")


if __name__ == "__main__":
    main()

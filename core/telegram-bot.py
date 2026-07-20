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
#
# UI: /menu shows an inline-keyboard button menu. Actions that need input
# (create/delete/renew) walk the admin through a step-by-step conversation
# instead of a single-line command with positional args -- send one field,
# get the next prompt, repeat, then get the full result at the end.

import json
import os
import re
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

# chat_id -> {"flow": <name>, "step": <index>, "data": {...}}
# in-memory only -- a bot restart mid-conversation just drops the partial
# flow, same as any other interrupted chat; acceptable for a single-admin
# control bot.
CONVERSATIONS = {}


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
                 "You're now the admin of this bot. Send /menu to get started.")
    return chat_id


def api_call(token, method, params=None, timeout=35):
    url = f"https://api.telegram.org/bot{token}/{method}"
    data = urllib.parse.urlencode(params).encode() if params is not None else None
    req = urllib.request.Request(url, data=data)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode())


def send_message(token, chat_id, text, keyboard=None):
    text = text[:MAX_REPLY_LEN]
    params = {"chat_id": chat_id, "text": text}
    if keyboard is not None:
        params["reply_markup"] = json.dumps(keyboard)
    try:
        api_call(token, "sendMessage", params)
    except Exception as e:
        sys.stderr.write(f"sendMessage failed: {e}\n")


def answer_callback(token, callback_query_id, text=None):
    params = {"callback_query_id": callback_query_id}
    if text:
        params["text"] = text
    try:
        api_call(token, "answerCallbackQuery", params)
    except Exception as e:
        sys.stderr.write(f"answerCallbackQuery failed: {e}\n")


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


MAIN_MENU = {
    "inline_keyboard": [
        [{"text": "➕ Create SSH", "callback_data": "create_ssh"},
         {"text": "\U0001F4CB List SSH", "callback_data": "list_ssh"}],
        [{"text": "\U0001F5D1 Delete SSH", "callback_data": "delete_ssh"},
         {"text": "\U0001F504 Renew SSH", "callback_data": "renew_ssh"}],
        [{"text": "\U0001F4CA Status", "callback_data": "status"}],
    ]
}

MENU_TEXT = "VPN-Starter-Kit -- choose an action:"


def username_exists(username):
    try:
        return subprocess.run(["id", username], capture_output=True, timeout=5).returncode == 0
    except Exception:
        return False


# ---- step-by-step conversation flows -------------------------------------

def _v_username(v):
    if not re.match(r"^[a-z_][a-z0-9_-]*$", v):
        return "Invalid username. Use lowercase letters, digits, - and _ only. Try again:"
    if username_exists(v):
        return f"A system user named '{v}' already exists. Try a different username:"
    return None


def _v_nonempty(v):
    return None if v else "Cannot be empty. Try again:"


def _v_digits(v):
    return None if v.isdigit() else "Must be a whole number. Try again:"


FLOWS = {
    "create_ssh": {
        "steps": ["username", "password", "days", "conn_limit", "bw_limit_gb"],
        "prompts": {
            "username": "Create SSH account\n\nEnter username:",
            "password": "Enter password:",
            "days": "Enter expiry (days):",
            "conn_limit": "Enter connection limit (0 = unlimited):",
            "bw_limit_gb": "Enter bandwidth limit in GB (0 = unlimited):",
        },
        "validators": {
            "username": _v_username, "password": _v_nonempty,
            "days": _v_digits, "conn_limit": _v_digits, "bw_limit_gb": _v_digits,
        },
        "finish": lambda d: run_action(
            "create", d["username"], d["password"], d["days"], d["conn_limit"], d["bw_limit_gb"]
        ),
    },
    "delete_ssh": {
        "steps": ["username"],
        "prompts": {"username": "Delete SSH account\n\nEnter username to delete:"},
        "validators": {"username": _v_nonempty},
        "finish": lambda d: run_action("delete", d["username"]),
    },
    "renew_ssh": {
        "steps": ["username", "days"],
        "prompts": {
            "username": "Renew SSH account\n\nEnter username to renew:",
            "days": "Add how many days:",
        },
        "validators": {"username": _v_nonempty, "days": _v_digits},
        "finish": lambda d: run_action("renew", d["username"], d["days"]),
    },
}


def start_flow(token, chat_id, flow_name):
    flow = FLOWS[flow_name]
    CONVERSATIONS[chat_id] = {"flow": flow_name, "step": 0, "data": {}}
    first_field = flow["steps"][0]
    send_message(token, chat_id, flow["prompts"][first_field])


def advance_flow(token, chat_id, text):
    """Feed the next answer into an in-progress flow. Returns True if a flow
    consumed this message (whether it advanced, re-prompted, or finished)."""
    convo = CONVERSATIONS.get(chat_id)
    if not convo:
        return False

    flow = FLOWS[convo["flow"]]
    field = flow["steps"][convo["step"]]
    value = text.strip()

    error = flow["validators"].get(field, lambda v: None)(value)
    if error:
        send_message(token, chat_id, error)
        return True

    convo["data"][field] = value
    convo["step"] += 1

    if convo["step"] < len(flow["steps"]):
        next_field = flow["steps"][convo["step"]]
        send_message(token, chat_id, flow["prompts"][next_field])
        return True

    # all fields collected -- run it
    result = flow["finish"](convo["data"])
    del CONVERSATIONS[chat_id]
    send_message(token, chat_id, result)
    send_message(token, chat_id, MENU_TEXT, keyboard=MAIN_MENU)
    return True


def route(token, chat_id, action):
    """Dispatch a plain action name -- shared by typed commands and button
    taps, since both mean the same thing once you strip the leading slash."""
    if action in ("start", "menu"):
        CONVERSATIONS.pop(chat_id, None)
        send_message(token, chat_id, MENU_TEXT, keyboard=MAIN_MENU)
    elif action == "cancel":
        if CONVERSATIONS.pop(chat_id, None):
            send_message(token, chat_id, "Cancelled.")
        send_message(token, chat_id, MENU_TEXT, keyboard=MAIN_MENU)
    elif action == "status":
        send_message(token, chat_id, run_status())
    elif action == "create_ssh":
        start_flow(token, chat_id, "create_ssh")
    elif action == "list_ssh":
        send_message(token, chat_id, run_action("list"))
    elif action == "delete_ssh":
        start_flow(token, chat_id, "delete_ssh")
    elif action == "renew_ssh":
        start_flow(token, chat_id, "renew_ssh")
    else:
        send_message(token, chat_id, "Unknown action.", keyboard=MAIN_MENU)


COMMAND_TO_ACTION = {
    "/start": "start", "/menu": "menu", "/cancel": "cancel", "/status": "status",
    "/createssh": "create_ssh", "/listssh": "list_ssh",
    "/deletessh": "delete_ssh", "/renewssh": "renew_ssh",
}


def handle_message(token, chat_id, text):
    text = text.strip()
    if not text:
        return

    is_command = text.startswith("/")
    if is_command:
        cmd = text.split()[0].split("@")[0].lower()  # strip "/cmd@botname" + any args
        # a command always interrupts an in-progress flow rather than being
        # swallowed as that step's answer -- otherwise there's no way to
        # back out of a flow you started by mistake.
        if chat_id in CONVERSATIONS and cmd not in ("/cancel",):
            CONVERSATIONS.pop(chat_id, None)
        action = COMMAND_TO_ACTION.get(cmd)
        if action:
            route(token, chat_id, action)
        else:
            send_message(token, chat_id, "Unknown command.", keyboard=MAIN_MENU)
        return

    if advance_flow(token, chat_id, text):
        return

    send_message(token, chat_id, MENU_TEXT, keyboard=MAIN_MENU)


def handle_callback(token, callback_query):
    cq_id = callback_query["id"]
    chat_id = str(callback_query.get("message", {}).get("chat", {}).get("id", ""))
    data = callback_query.get("data", "")
    answer_callback(token, cq_id)
    return chat_id, data


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

            if "callback_query" in update:
                chat_id, data = handle_callback(token, update["callback_query"])
                if admin_id is None or chat_id != admin_id or not data:
                    continue
                try:
                    route(token, chat_id, data)
                except Exception as e:
                    sys.stderr.write(f"route error: {e}\n")
                    send_message(token, chat_id, f"Internal error: {e}")
                continue

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
                handle_message(token, chat_id, text)
            except Exception as e:
                sys.stderr.write(f"handle_message error: {e}\n")
                send_message(token, chat_id, f"Internal error: {e}")


if __name__ == "__main__":
    main()

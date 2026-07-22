#!/usr/bin/env python3
# VPN-Starter-Kit :: core/telegram-user-bot.py
# Self-service account-creation bot -- a SEPARATE bot/token from
# core/telegram-bot.py (the admin control bot). Deliberately has NO
# authorization gate: anyone who messages this bot can create themselves
# an account, since the whole point is letting customers self-serve
# without needing admin access. That's why every account created here is
# capped: fixed 7-day expiry, unlimited connection/bandwidth (SSH only --
# Xray/WireGuard have no such limit concept in this project), and there is
# no delete/renew/list/status capability at all -- create-only, by design.
# stdlib only (urllib), matching ws.py/ohp.py/telegram-bot.py's style.

import json
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

INSTALL_DIR = "/etc/vpn-script"
TOKEN_FILE = f"{INSTALL_DIR}/telegram-user-bot-token"
ACCESS_FILE = f"{INSTALL_DIR}/telegram-user-bot-access.json"
SSH_ACTIONS = f"{INSTALL_DIR}/core/telegram-ssh-actions.sh"
XRAY_ACTIONS = f"{INSTALL_DIR}/core/telegram-xray-actions.sh"
WG_ACTIONS = f"{INSTALL_DIR}/core/telegram-wireguard-actions.sh"

# create_X action -> Control Access key (menu/telegram-user-bot-setup.sh
# writes/toggles this same file). Missing file or missing key both mean
# "allowed" -- an admin who never touched Control Access gets the same
# behavior as before this feature existed.
FLOW_ACCESS_KEY = {
    "create_ssh": "ssh", "create_vmess": "vmess", "create_vless": "vless",
    "create_trojan": "trojan", "create_wireguard": "wireguard",
}


def is_allowed(key):
    try:
        with open(ACCESS_FILE) as f:
            data = json.load(f)
        return bool(data.get(key, True))
    except (OSError, json.JSONDecodeError):
        return True

FIXED_EXPIRY_DAYS = "7"
POLL_TIMEOUT = 30
MAX_REPLY_LEN = 4000

CONVERSATIONS = {}  # chat_id -> {"flow": <name>, "step": <index>, "data": {...}}


def _read(path):
    with open(path) as f:
        return f.read().strip()


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


def answer_callback(token, callback_query_id):
    try:
        api_call(token, "answerCallbackQuery", {"callback_query_id": callback_query_id})
    except Exception as e:
        sys.stderr.write(f"answerCallbackQuery failed: {e}\n")


def run_script(script, *args):
    try:
        proc = subprocess.run(
            ["bash", script, *args],
            capture_output=True, text=True, timeout=60,
        )
        out = (proc.stdout or "") + (proc.stderr or "")
        return out.strip() or "(no output)"
    except subprocess.TimeoutExpired:
        return "Command timed out."
    except Exception as e:
        return f"Error running command: {e}"


def ssh_username_exists(username):
    try:
        return subprocess.run(["id", username], capture_output=True, timeout=5).returncode == 0
    except Exception:
        return False


def _btn(text, action):
    key = FLOW_ACCESS_KEY[action]
    label = text if is_allowed(key) else f"{text} (Off)"
    return {"text": label, "callback_data": action}


def build_main_menu():
    # rebuilt on every call, not a module-level constant -- Control Access
    # can toggle at any time and the menu needs to reflect that immediately.
    return {
        "inline_keyboard": [
            [_btn("SSH", "create_ssh"), _btn("VMess", "create_vmess")],
            [_btn("VLESS", "create_vless"), _btn("Trojan", "create_trojan")],
            [_btn("WireGuard", "create_wireguard")],
        ]
    }


MENU_TEXT = "Create a free account -- choose a type:"


def _v_ssh_username(v):
    if not re.match(r"^[a-z_][a-z0-9_-]*$", v):
        return "Invalid username. Use lowercase letters, digits, - and _ only. Try again:"
    if ssh_username_exists(v):
        return f"'{v}' is already taken. Try a different username:"
    return None


def _v_xray_username(v):
    if not re.match(r"^[a-zA-Z0-9-]+$", v):
        return "Invalid username. Use letters, digits, and - only (no underscore). Try again:"
    return None


def _v_wg_username(v):
    if not re.match(r"^[a-zA-Z0-9_-]+$", v):
        return "Invalid username. Use letters, digits, - and _ only. Try again:"
    return None


def _v_nonempty(v):
    return None if v else "Cannot be empty. Try again:"


FLOWS = {
    "create_ssh": {
        "steps": ["username", "password"],
        "prompts": {
            "username": "Create SSH account (7 days, unlimited connections/bandwidth)\n\nEnter username:",
            "password": "Enter password:",
        },
        "validators": {"username": _v_ssh_username, "password": _v_nonempty},
        "finish": lambda d: run_script(
            SSH_ACTIONS, "create", d["username"], d["password"], FIXED_EXPIRY_DAYS, "0", "0"
        ),
    },
    "create_vmess": {
        "steps": ["username"],
        "prompts": {"username": "Create VMess account (7 days)\n\nEnter username:"},
        "validators": {"username": _v_xray_username},
        "finish": lambda d: run_script(XRAY_ACTIONS, "create", "vmess", d["username"], FIXED_EXPIRY_DAYS),
    },
    "create_vless": {
        "steps": ["username"],
        "prompts": {"username": "Create VLESS account (7 days)\n\nEnter username:"},
        "validators": {"username": _v_xray_username},
        "finish": lambda d: run_script(XRAY_ACTIONS, "create", "vless", d["username"], FIXED_EXPIRY_DAYS),
    },
    "create_trojan": {
        "steps": ["username"],
        "prompts": {"username": "Create Trojan account (7 days)\n\nEnter username:"},
        "validators": {"username": _v_xray_username},
        "finish": lambda d: run_script(XRAY_ACTIONS, "create", "trojan", d["username"], FIXED_EXPIRY_DAYS),
    },
    "create_wireguard": {
        "steps": ["username"],
        "prompts": {"username": "Create WireGuard account (7 days)\n\nEnter username:"},
        "validators": {"username": _v_wg_username},
        "finish": lambda d: run_script(WG_ACTIONS, "create", d["username"], FIXED_EXPIRY_DAYS),
    },
}


def start_flow(token, chat_id, flow_name):
    flow = FLOWS[flow_name]
    CONVERSATIONS[chat_id] = {"flow": flow_name, "step": 0, "data": {}}
    first_field = flow["steps"][0]
    send_message(token, chat_id, flow["prompts"][first_field])


def advance_flow(token, chat_id, text):
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

    result = flow["finish"](convo["data"])
    del CONVERSATIONS[chat_id]
    send_message(token, chat_id, result)
    send_message(token, chat_id, MENU_TEXT, keyboard=build_main_menu())
    return True


def route(token, chat_id, action):
    if action in ("start", "menu"):
        CONVERSATIONS.pop(chat_id, None)
        send_message(token, chat_id, MENU_TEXT, keyboard=build_main_menu())
    elif action == "cancel":
        if CONVERSATIONS.pop(chat_id, None):
            send_message(token, chat_id, "Cancelled.")
        send_message(token, chat_id, MENU_TEXT, keyboard=build_main_menu())
    elif action in FLOWS:
        if not is_allowed(FLOW_ACCESS_KEY[action]):
            send_message(token, chat_id,
                         "This account type is currently unavailable. Please choose another type:",
                         keyboard=build_main_menu())
            return
        start_flow(token, chat_id, action)
    else:
        send_message(token, chat_id, "Unknown action.", keyboard=build_main_menu())


COMMAND_TO_ACTION = {
    "/start": "start", "/menu": "menu", "/cancel": "cancel",
    "/createssh": "create_ssh", "/createvmess": "create_vmess",
    "/createvless": "create_vless", "/createtrojan": "create_trojan",
    "/createwireguard": "create_wireguard",
}


def handle_message(token, chat_id, text):
    text = text.strip()
    if not text:
        return

    if text.startswith("/"):
        cmd = text.split()[0].split("@")[0].lower()
        if chat_id in CONVERSATIONS and cmd != "/cancel":
            CONVERSATIONS.pop(chat_id, None)
        action = COMMAND_TO_ACTION.get(cmd)
        if action:
            route(token, chat_id, action)
        else:
            send_message(token, chat_id, "Unknown command.", keyboard=build_main_menu())
        return

    if advance_flow(token, chat_id, text):
        return

    send_message(token, chat_id, MENU_TEXT, keyboard=build_main_menu())


def flush_backlog(token):
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

    me = api_call(token, "getMe", timeout=15)
    if not me.get("ok"):
        sys.stderr.write(f"getMe failed: {me}\n")
        sys.exit(1)
    sys.stdout.write(f"Telegram user bot @{me['result']['username']} starting (open, no auth gate)\n")
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
                cq = update["callback_query"]
                chat_id = str(cq.get("message", {}).get("chat", {}).get("id", ""))
                data = cq.get("data", "")
                answer_callback(token, cq["id"])
                if not chat_id or not data:
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
            try:
                handle_message(token, chat_id, text)
            except Exception as e:
                sys.stderr.write(f"handle_message error: {e}\n")
                send_message(token, chat_id, f"Internal error: {e}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
# VPN-Starter-Kit :: core/admin-panel.py
# Browser control panel -- stdlib only (http.server), matching ws.py/
# ohp.py/both Telegram bots. Binds 127.0.0.1 only; nginx is the only
# public-facing edge (see core/nginx.conf's /admin-panel/ location),
# same pattern every other daemon in this project already uses.
#
# Phase 0: login/session + a read-only dashboard. Every other section of
# the bash menu gets a placeholder page in the nav shell for now (see
# NAV_SECTIONS) -- filled in phase by phase. Uninstall is deliberately
# never exposed here at all, by design (too destructive for a single
# password behind a browser click, no matter how it's confirmed).
#
# Auth: real PAM (core/pam_auth.py), checked against the VPS's own root
# account via a dedicated PAM service (/etc/pam.d/vpn-admin-panel,
# created by menu/menu-webgui.sh's "Setup Admin Panel" action) -- not a
# username+password scheme of this project's own invention.
#
# Session: a random token (secrets.token_urlsafe) in an HttpOnly/Secure/
# SameSite=Strict cookie, mapped server-side to an expiry in memory (lost
# on a service restart -- acceptable, just re-login). SameSite=Strict
# also means every authenticated POST route added in later phases gets
# baseline CSRF protection for free, with no separate token scheme needed.
#
# Brute-force protection: failed logins are counted per source IP in a
# small JSON file (survives a service restart, unlike an in-memory
# counter would) -- 5 failures locks that IP out for 15 minutes. nginx
# also rate-limits the login route itself (limit_req zone=admin_panel_login)
# as defense in depth at a different layer.

import html
import http.server
import json
import os
import secrets
import subprocess
import sys
import threading
import time
import urllib.parse
from http import cookies

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pam_auth  # noqa: E402

BIND_HOST = "127.0.0.1"
BIND_PORT = 8991
INSTALL_DIR = "/etc/vpn-script"
DASHBOARD_STATS_SCRIPT = os.path.join(INSTALL_DIR, "core", "dashboard-stats.sh")
ATTEMPTS_FILE = os.path.join(INSTALL_DIR, "admin-panel-login-attempts.json")

SSH_ACTIONS_SCRIPT = os.path.join(INSTALL_DIR, "core", "telegram-ssh-actions.sh")
SSH_PANEL_ACTIONS_SCRIPT = os.path.join(INSTALL_DIR, "core", "ssh-panel-actions.sh")
TRIAL_SSH_SCRIPT = os.path.join(INSTALL_DIR, "menu", "trial-ssh-user.sh")
GENERATE_SSH_CONFIG_SCRIPT = os.path.join(INSTALL_DIR, "menu", "generate-ssh-config.sh")
GENERATE_XRAY_CONFIG_SCRIPT = os.path.join(INSTALL_DIR, "menu", "generate-xray-config.sh")

XRAY_ACTIONS_SCRIPT = os.path.join(INSTALL_DIR, "core", "telegram-xray-actions.sh")
XRAY_PROTOCOLS = {
    "vmess": {"label": "VMess", "trial_script": "trial-vmess-user.sh"},
    "vless": {"label": "VLESS", "trial_script": "trial-vless-user.sh"},
    "trojan": {"label": "Trojan", "trial_script": "trial-trojan-user.sh"},
    "shadowsocks": {"label": "Shadowsocks", "trial_script": "trial-ss-user.sh"},
}

SESSION_COOKIE = "admin_panel_session"
SESSION_IDLE_SECONDS = 30 * 60
MAX_FAILED_ATTEMPTS = 5
LOCKOUT_SECONDS = 15 * 60
PAM_SERVICE = "vpn-admin-panel"

# ---- in-memory session store ----
_sessions = {}
_sessions_lock = threading.Lock()


def create_session():
    token = secrets.token_urlsafe(32)
    with _sessions_lock:
        _sessions[token] = time.time() + SESSION_IDLE_SECONDS
    return token


def touch_session(token):
    """True + refreshes the idle timeout if the session is still valid."""
    with _sessions_lock:
        exp = _sessions.get(token)
        if exp is None or exp < time.time():
            _sessions.pop(token, None)
            return False
        _sessions[token] = time.time() + SESSION_IDLE_SECONDS
        return True


def destroy_session(token):
    with _sessions_lock:
        _sessions.pop(token, None)


# ---- persisted failed-login lockout, keyed by source IP ----
_attempts_lock = threading.Lock()


def _load_attempts():
    try:
        with open(ATTEMPTS_FILE) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}


def _save_attempts(data):
    tmp = ATTEMPTS_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f)
    os.chmod(tmp, 0o600)
    os.replace(tmp, ATTEMPTS_FILE)


def is_locked_out(ip):
    with _attempts_lock:
        data = _load_attempts()
        entry = data.get(ip)
        if not entry or entry.get("count", 0) < MAX_FAILED_ATTEMPTS:
            return False
        if time.time() >= entry.get("locked_until", 0):
            data.pop(ip, None)
            _save_attempts(data)
            return False
        return True


def record_failed_attempt(ip):
    with _attempts_lock:
        data = _load_attempts()
        entry = data.get(ip, {"count": 0, "locked_until": 0})
        entry["count"] = entry.get("count", 0) + 1
        if entry["count"] >= MAX_FAILED_ATTEMPTS:
            entry["locked_until"] = time.time() + LOCKOUT_SECONDS
        data[ip] = entry
        _save_attempts(data)


def record_successful_login(ip):
    with _attempts_lock:
        data = _load_attempts()
        if ip in data:
            del data[ip]
            _save_attempts(data)


# ---- dashboard data ----
def get_dashboard_stats():
    try:
        result = subprocess.run(
            ["bash", DASHBOARD_STATS_SCRIPT], capture_output=True, text=True, timeout=15
        )
        return json.loads(result.stdout)
    except Exception as exc:
        print(f"admin-panel: failed to load dashboard stats: {exc}", flush=True)
        return None


def run_json(cmd, extra_env=None):
    """Run a backend script expected to print one JSON object; always
    returns a dict with at least an "ok" key, even on failure -- callers
    never need to handle a raised exception or malformed output."""
    env = dict(os.environ)
    if extra_env:
        env.update(extra_env)
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30, env=env)
        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError:
            msg = result.stdout.strip() or result.stderr.strip() or "no output"
            return {"ok": False, "error": "bad_output", "message": msg}
    except Exception as exc:
        return {"ok": False, "error": "exec_failed", "message": str(exc)}


def run_text(cmd):
    """Run a backend script expected to print a human-readable card/message
    (the existing Telegram-bot-facing text mode) -- used for one-shot
    create/delete/renew actions, displayed verbatim in a <pre> block."""
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        return (result.stdout.strip() or result.stderr.strip() or "(no output)")
    except Exception as exc:
        return f"Error: {exc}"


# ---- HTML shell ----
NAV_SECTIONS = [
    ("/admin-panel/", "Dashboard"),
    ("/admin-panel/ssh", "SSH / DNS"),
    ("/admin-panel/vmess", "VMess"),
    ("/admin-panel/vless", "VLESS"),
    ("/admin-panel/trojan", "Trojan"),
    ("/admin-panel/shadowsocks", "Shadowsocks"),
    ("/admin-panel/wireguard", "WireGuard"),
    ("/admin-panel/settings", "Settings"),
    ("/admin-panel/security", "Security Mgt"),
    ("/admin-panel/bot-api", "Bot & Api Setup"),
    ("/admin-panel/webgui", "WebGui"),
    ("/admin-panel/backup", "Backup"),
]

BASE_CSS = """
* { box-sizing: border-box; }
body { margin: 0; font-family: -apple-system, Segoe UI, Roboto, sans-serif;
       background: #0f1420; color: #e4e8f1; }
a { color: #6fb3ff; text-decoration: none; }
a:hover { text-decoration: underline; }
.shell { display: flex; min-height: 100vh; }
nav { width: 220px; background: #131a2b; padding: 20px 0; flex-shrink: 0; }
nav h1 { font-size: 15px; padding: 0 20px 16px; margin: 0; color: #9fb3d9; }
nav ul { list-style: none; margin: 0; padding: 0; }
nav li a { display: block; padding: 10px 20px; color: #cdd6e6; }
nav li.active a { background: #1e2a45; color: #fff; border-left: 3px solid #6fb3ff; }
nav .logout { display: block; margin: 20px 20px 0; padding: 8px 0; color: #ff8080; }
main { flex: 1; padding: 32px; }
h2 { margin-top: 0; }
.muted { color: #8a93a6; }
.card { background: #131a2b; border-radius: 8px; padding: 20px; margin-bottom: 20px; }
.card h3 { margin-top: 0; font-size: 14px; text-transform: uppercase; color: #9fb3d9; }
.grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 12px; }
.stat { background: #0f1420; border-radius: 6px; padding: 12px; }
.stat .label { font-size: 12px; color: #8a93a6; }
.stat .value { font-size: 20px; margin-top: 4px; }
.ok { color: #4ade80; }
.bad { color: #f87171; }
.login-wrap { display: flex; align-items: center; justify-content: center; min-height: 100vh; }
.login-box { background: #131a2b; padding: 32px; border-radius: 10px; width: 320px; }
.login-box h1 { font-size: 16px; margin-top: 0; color: #9fb3d9; }
.login-box input { width: 100%; padding: 10px; margin: 8px 0 16px; border-radius: 6px;
                    border: 1px solid #2a3550; background: #0f1420; color: #e4e8f1; }
.login-box button { width: 100%; padding: 10px; border-radius: 6px; border: none;
                     background: #3b82f6; color: #fff; font-weight: 600; cursor: pointer; }
.login-box button:hover { background: #2563eb; }
.error { background: #3a1620; color: #f87171; padding: 10px; border-radius: 6px; margin-bottom: 12px; }
code { background: #0f1420; padding: 2px 6px; border-radius: 4px; }
table { width: 100%; border-collapse: collapse; margin-top: 8px; }
th, td { text-align: left; padding: 8px; border-bottom: 1px solid #1e2a45; font-size: 14px; }
th { color: #8a93a6; font-weight: 600; }
.stack-form label { display: block; margin-top: 10px; font-size: 12px; color: #8a93a6; }
.stack-form input { width: 100%; padding: 8px; margin-top: 4px; border-radius: 6px;
                     border: 1px solid #2a3550; background: #0f1420; color: #e4e8f1; }
.stack-form button, form button { margin-top: 16px; padding: 8px 16px; border-radius: 6px; border: none;
                                   background: #3b82f6; color: #fff; cursor: pointer; }
.inline-form { display: inline-block; margin-right: 6px; }
.inline-form input { width: 80px; padding: 4px; border-radius: 4px; border: 1px solid #2a3550;
                      background: #0f1420; color: #e4e8f1; }
.inline-form button { margin-top: 0; padding: 6px 10px; font-size: 13px; }
button.danger, .inline-form button.danger { background: #dc2626; }
.output { background: #0f1420; padding: 16px; border-radius: 8px; white-space: pre-wrap; font-size: 13px; }
.links a { margin-right: 16px; }
"""


def render_login_page(error=None):
    error_html = f'<div class="error">{html.escape(error)}</div>' if error else ""
    return f"""<!doctype html>
<html><head><meta charset="utf-8">
<title>Login -- VPN-Starter-Kit Admin Panel</title>
<style>{BASE_CSS}</style></head>
<body><div class="login-wrap"><div class="login-box">
<h1>VPN-Starter-Kit Admin Panel</h1>
{error_html}
<form method="post" action="/admin-panel/login">
<label>Username</label>
<input type="text" value="root" disabled>
<label>Password (your VPS root password)</label>
<input type="password" name="password" autofocus>
<button type="submit">Login</button>
</form>
</div></div></body></html>"""


def render_shell_page(title, body_html, current_path):
    nav_items = ""
    for path, label in NAV_SECTIONS:
        active = ' class="active"' if path == current_path else ""
        nav_items += f'<li{active}><a href="{html.escape(path)}">{html.escape(label)}</a></li>\n'
    return f"""<!doctype html>
<html><head><meta charset="utf-8">
<title>{html.escape(title)} -- VPN-Starter-Kit Admin Panel</title>
<style>{BASE_CSS}</style></head>
<body><div class="shell">
<nav><h1>VPN-Starter-Kit</h1><ul>{nav_items}</ul>
<a class="logout" href="/admin-panel/logout">Logout</a></nav>
<main>{body_html}</main>
</div></body></html>"""


def _svc_badge(active):
    return '<span class="ok">Active</span>' if active else '<span class="bad">Inactive</span>'


def render_dashboard_body(stats):
    if stats is None:
        return '<h2>Dashboard</h2><p class="error">Could not load dashboard stats -- check: journalctl -u vpn-admin-panel -n 30 --no-pager</p>'

    server = stats.get("server", {})
    services = stats.get("services", {})
    accounts = stats.get("accounts", {})
    bandwidth = stats.get("bandwidth", {})

    svc_rows = "".join(
        f'<div class="stat"><div class="label">{html.escape(name)}</div><div class="value">{_svc_badge(active)}</div></div>'
        for name, active in services.items()
    )
    acc_rows = "".join(
        f'<div class="stat"><div class="label">{html.escape(name.capitalize())}</div><div class="value">{int(count)}</div></div>'
        for name, count in accounts.items()
    )

    return f"""<h2>Dashboard</h2>
<div class="card">
<h3>Server Info</h3>
<div class="grid">
<div class="stat"><div class="label">Uptime</div><div class="value">{html.escape(str(server.get('uptime', 'n/a')))}</div></div>
<div class="stat"><div class="label">Server IP</div><div class="value">{html.escape(str(server.get('ip', 'n/a')))}</div></div>
<div class="stat"><div class="label">OS</div><div class="value">{html.escape(str(server.get('os', 'n/a')))}</div></div>
<div class="stat"><div class="label">RAM</div><div class="value">{html.escape(str(server.get('ram_used_mb', 0)))} / {html.escape(str(server.get('ram_total_mb', 0)))} MB</div></div>
<div class="stat"><div class="label">CPU</div><div class="value">{html.escape(str(server.get('cpu_pct', 0)))}%</div></div>
<div class="stat"><div class="label">Domain</div><div class="value">{html.escape(str(server.get('domain', 'n/a')))}</div></div>
<div class="stat"><div class="label">NS Domain</div><div class="value">{html.escape(str(server.get('ns_domain', 'n/a')))}</div></div>
<div class="stat"><div class="label">Auto Reboot</div><div class="value">{html.escape(str(server.get('reboot_status', 'n/a')))}</div></div>
</div></div>

<div class="card"><h3>Active Service</h3><div class="grid">{svc_rows}</div></div>

<div class="card"><h3>Active Account</h3><div class="grid">{acc_rows}</div></div>

<div class="card"><h3>Bandwidth Usage</h3><div class="grid">
<div class="stat"><div class="label">Today</div><div class="value">{html.escape(str(bandwidth.get('today_human', '0B')))}</div></div>
<div class="stat"><div class="label">Yesterday</div><div class="value">{html.escape(str(bandwidth.get('yesterday_human', '0B')))}</div></div>
<div class="stat"><div class="label">This Month</div><div class="value">{html.escape(str(bandwidth.get('month_human', '0B')))}</div></div>
</div></div>"""


def render_action_result(title, output_text, back_path, back_label="Back"):
    return f"""<h2>{html.escape(title)}</h2>
<div class="card"><pre class="output">{html.escape(output_text)}</pre></div>
<p><a href="{html.escape(back_path)}">&larr; {html.escape(back_label)}</a></p>"""


def render_ssh_page():
    result = run_json(["bash", SSH_ACTIONS_SCRIPT, "list"], extra_env={"PANEL_JSON": "1"})
    rows = ""
    if result.get("ok"):
        for u in result.get("users", []):
            uname = html.escape(u.get("username", ""))
            lock_badge = '<span class="bad">Locked</span>' if u.get("locked") else '<span class="ok">Unlocked</span>'
            rows += f"""<tr>
<td>{uname}</td>
<td>{html.escape(u.get('expiry', ''))}</td>
<td>{html.escape(u.get('limits', '-'))}</td>
<td>{lock_badge}</td>
<td>
<form method="post" action="/admin-panel/ssh/generate-config" class="inline-form">
<input type="hidden" name="username" value="{uname}">
<button type="submit">View Config</button>
</form>
<form method="post" action="/admin-panel/ssh/renew" class="inline-form">
<input type="hidden" name="username" value="{uname}">
<input type="number" name="days" placeholder="days" min="1" required>
<button type="submit">Renew</button>
</form>
<form method="post" action="/admin-panel/ssh/delete" class="inline-form" onsubmit="return confirm('Delete {uname}?')">
<input type="hidden" name="username" value="{uname}">
<button type="submit" class="danger">Delete</button>
</form>
</td>
</tr>"""
    if not rows:
        msg = html.escape(result.get("message", "No accounts yet.")) if not result.get("ok") else "No accounts yet."
        rows = f'<tr><td colspan="5">{msg}</td></tr>'

    return f"""<h2>SSH / DNS</h2>

<div class="card">
<h3>Create Account</h3>
<form method="post" action="/admin-panel/ssh/create" class="stack-form">
<label>Username</label><input type="text" name="username" required>
<label>Password</label><input type="text" name="password" required>
<label>Expiry (days)</label><input type="number" name="days" value="30" required>
<label>Connection limit (0 = unlimited)</label><input type="number" name="conn_limit" value="0">
<label>Bandwidth limit GB (0 = unlimited)</label><input type="number" name="bw_limit_gb" value="0">
<button type="submit">Create</button>
</form>
<form method="post" action="/admin-panel/ssh/trial" style="margin-top:12px">
<button type="submit">Create Trial Account (24h)</button>
</form>
</div>

<div class="card">
<h3>Accounts</h3>
<table>
<tr><th>Username</th><th>Expiry</th><th>Limits</th><th>Status</th><th>Actions</th></tr>
{rows}
</table>
</div>

<div class="card links">
<a href="/admin-panel/ssh/active">Check Active Users</a>
<a href="/admin-panel/ssh/locked">Check Locked Users</a>
<a href="/admin-panel/ssh/autokill">Autokill Multi Login Setup</a>
</div>"""


def render_ssh_active_page():
    result = run_json(["bash", SSH_PANEL_ACTIONS_SCRIPT, "login-counts"])
    rows = ""
    if result.get("ok"):
        for u in result.get("users", []):
            rows += f"<tr><td>{html.escape(u.get('username', ''))}</td><td>{int(u.get('logins', 0))}</td></tr>"
    if not rows:
        rows = '<tr><td colspan="2">No accounts yet.</td></tr>'
    return f"""<h2>Check Active Users</h2>
<div class="card"><table><tr><th>Username</th><th>Active Logins</th></tr>{rows}</table></div>
<p><a href="/admin-panel/ssh">&larr; Back to SSH / DNS</a></p>"""


def render_ssh_locked_page():
    result = run_json(["bash", SSH_PANEL_ACTIONS_SCRIPT, "locked-list"])
    rows = ""
    if result.get("ok"):
        for u in result.get("users", []):
            uname = html.escape(u.get("username", ""))
            reason = u.get("reason", "")
            reason_label = html.escape(u.get("reason_label", ""))
            if reason == "bandwidth":
                action_form = f"""<form method="post" action="/admin-panel/ssh/locked/unlock" class="inline-form">
<input type="hidden" name="username" value="{uname}">
<input type="hidden" name="action" value="bandwidth">
<input type="number" name="value" placeholder="extend GB" min="1" required>
<button type="submit">Extend + Unlock</button>
</form>"""
            elif reason == "connection":
                action_form = f"""<form method="post" action="/admin-panel/ssh/locked/unlock" class="inline-form">
<input type="hidden" name="username" value="{uname}">
<input type="hidden" name="action" value="connlimit">
<input type="number" name="value" placeholder="new limit" min="1" required>
<button type="submit">Set + Unlock</button>
</form>"""
            else:
                action_form = f"""<form method="post" action="/admin-panel/ssh/locked/unlock" class="inline-form">
<input type="hidden" name="username" value="{uname}">
<input type="hidden" name="action" value="plain">
<button type="submit">Unlock</button>
</form>"""
            delete_form = f"""<form method="post" action="/admin-panel/ssh/delete" class="inline-form" onsubmit="return confirm('Delete {uname}?')">
<input type="hidden" name="username" value="{uname}">
<button type="submit" class="danger">Delete</button>
</form>"""
            rows += f"<tr><td>{uname}</td><td>{reason_label}</td><td>{action_form}{delete_form}</td></tr>"
    if not rows:
        rows = '<tr><td colspan="3">No locked accounts.</td></tr>'
    return f"""<h2>Check Locked Users</h2>
<div class="card"><table><tr><th>Username</th><th>Reason</th><th>Actions</th></tr>{rows}</table></div>
<p><a href="/admin-panel/ssh">&larr; Back to SSH / DNS</a></p>"""


def render_ssh_autokill_page():
    result = run_json(["bash", SSH_PANEL_ACTIONS_SCRIPT, "autokill-status"])
    if result.get("enabled"):
        limit = result.get("limit")
        body_extra = f"""<p>Status: <span class="ok">Enabled</span> (limit: {int(limit)} device(s) per account)</p>
<form method="post" action="/admin-panel/ssh/autokill/disable">
<button type="submit" class="danger">Disable</button>
</form>"""
    else:
        body_extra = """<p>Status: <span class="bad">Disabled</span></p>
<form method="post" action="/admin-panel/ssh/autokill/enable" class="stack-form">
<label>Max devices allowed per account</label>
<input type="number" name="limit" value="2" min="1" required>
<button type="submit">Enable</button>
</form>"""
    return f"""<h2>Autokill Multi Login Setup</h2>
<div class="card">{body_extra}</div>
<p><a href="/admin-panel/ssh">&larr; Back to SSH / DNS</a></p>"""


def render_xray_page(proto):
    label = XRAY_PROTOCOLS[proto]["label"]
    result = run_json(["bash", XRAY_ACTIONS_SCRIPT, "list", proto], extra_env={"PANEL_JSON": "1"})
    rows = ""
    if result.get("ok"):
        for u in result.get("users", []):
            uname = html.escape(u.get("username", ""))
            rows += f"""<tr>
<td>{uname}</td>
<td>{html.escape(u.get('expiry', ''))}</td>
<td>
<form method="post" action="/admin-panel/{proto}/generate-config" class="inline-form">
<input type="hidden" name="username" value="{uname}">
<button type="submit">View Config</button>
</form>
<form method="post" action="/admin-panel/{proto}/renew" class="inline-form">
<input type="hidden" name="username" value="{uname}">
<input type="number" name="days" placeholder="days" min="1" required>
<button type="submit">Renew</button>
</form>
<form method="post" action="/admin-panel/{proto}/delete" class="inline-form" onsubmit="return confirm('Delete {uname}?')">
<input type="hidden" name="username" value="{uname}">
<button type="submit" class="danger">Delete</button>
</form>
</td>
</tr>"""
    if not rows:
        msg = html.escape(result.get("message", "No accounts yet.")) if not result.get("ok") else "No accounts yet."
        rows = f'<tr><td colspan="3">{msg}</td></tr>'

    return f"""<h2>{html.escape(label)}</h2>

<div class="card">
<h3>Create Account</h3>
<form method="post" action="/admin-panel/{proto}/create" class="stack-form">
<label>Username</label>
<input type="text" name="username" required pattern="[a-zA-Z0-9-]+" title="Letters, digits, and - only (no underscore)">
<label>Expiry (days)</label><input type="number" name="days" value="30" required>
<button type="submit">Create</button>
</form>
<form method="post" action="/admin-panel/{proto}/trial" style="margin-top:12px">
<button type="submit">Create Trial Account</button>
</form>
</div>

<div class="card">
<h3>Accounts</h3>
<table>
<tr><th>Username</th><th>Expiry</th><th>Actions</th></tr>
{rows}
</table>
</div>"""


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "VPNStarterKitAdminPanel/1.0"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - - [%s] %s\n" % (self.address_string(), self.log_date_time_string(), fmt % args))

    def _client_ip(self):
        return self.client_address[0]

    def _get_cookie(self, name):
        header = self.headers.get("Cookie")
        if not header:
            return None
        jar = cookies.SimpleCookie()
        jar.load(header)
        morsel = jar.get(name)
        return morsel.value if morsel else None

    def _current_session(self):
        token = self._get_cookie(SESSION_COOKIE)
        if token and touch_session(token):
            return token
        return None

    def _send_html(self, body, status=200, set_cookie=None, clear_cookie=False):
        encoded = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self._maybe_set_cookie(set_cookie, clear_cookie)
        self.end_headers()
        self.wfile.write(encoded)

    def _redirect(self, location, set_cookie=None, clear_cookie=False):
        self.send_response(302)
        self.send_header("Location", location)
        self._maybe_set_cookie(set_cookie, clear_cookie)
        self.end_headers()

    def _maybe_set_cookie(self, set_cookie, clear_cookie):
        if set_cookie:
            self.send_header(
                "Set-Cookie",
                f"{SESSION_COOKIE}={set_cookie}; Path=/admin-panel; HttpOnly; Secure; SameSite=Strict; Max-Age={SESSION_IDLE_SECONDS}",
            )
        if clear_cookie:
            self.send_header(
                "Set-Cookie",
                f"{SESSION_COOKIE}=; Path=/admin-panel; HttpOnly; Secure; SameSite=Strict; Max-Age=0",
            )

    def _read_form_body(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        raw = self.rfile.read(length) if length else b""
        return urllib.parse.parse_qs(raw.decode("utf-8"))

    def do_GET(self):
        path = urllib.parse.urlsplit(self.path).path
        if path == "/admin-panel/login":
            return self._handle_login_get()
        if path == "/admin-panel/logout":
            return self._handle_logout()
        if path in ("/admin-panel/", "/admin-panel"):
            return self._handle_dashboard()
        if path == "/admin-panel/ssh":
            return self._handle_ssh_page()
        if path == "/admin-panel/ssh/active":
            return self._handle_ssh_active()
        if path == "/admin-panel/ssh/locked":
            return self._handle_ssh_locked()
        if path == "/admin-panel/ssh/autokill":
            return self._handle_ssh_autokill()
        for proto in XRAY_PROTOCOLS:
            if path == f"/admin-panel/{proto}":
                return self._handle_xray_page(proto)
        if path.startswith("/admin-panel/"):
            return self._handle_placeholder(path)
        self._send_html("<h1>404 Not Found</h1>", status=404)

    def do_POST(self):
        path = urllib.parse.urlsplit(self.path).path
        if path == "/admin-panel/login":
            return self._handle_login_post()
        if path == "/admin-panel/logout":
            return self._handle_logout()
        if path == "/admin-panel/ssh/create":
            return self._handle_ssh_create()
        if path == "/admin-panel/ssh/trial":
            return self._handle_ssh_trial()
        if path == "/admin-panel/ssh/delete":
            return self._handle_ssh_delete()
        if path == "/admin-panel/ssh/renew":
            return self._handle_ssh_renew()
        if path == "/admin-panel/ssh/generate-config":
            return self._handle_ssh_generate_config()
        if path == "/admin-panel/ssh/locked/unlock":
            return self._handle_ssh_locked_unlock()
        if path == "/admin-panel/ssh/autokill/enable":
            return self._handle_ssh_autokill_enable()
        if path == "/admin-panel/ssh/autokill/disable":
            return self._handle_ssh_autokill_disable()
        for proto in XRAY_PROTOCOLS:
            if path == f"/admin-panel/{proto}/create":
                return self._handle_xray_create(proto)
            if path == f"/admin-panel/{proto}/trial":
                return self._handle_xray_trial(proto)
            if path == f"/admin-panel/{proto}/delete":
                return self._handle_xray_delete(proto)
            if path == f"/admin-panel/{proto}/renew":
                return self._handle_xray_renew(proto)
            if path == f"/admin-panel/{proto}/generate-config":
                return self._handle_xray_generate_config(proto)
        self._send_html("<h1>404 Not Found</h1>", status=404)

    def _handle_login_get(self):
        if self._current_session():
            return self._redirect("/admin-panel/")
        self._send_html(render_login_page())

    def _handle_login_post(self):
        ip = self._client_ip()
        if is_locked_out(ip):
            return self._send_html(
                render_login_page(error="Too many failed attempts. Try again in a few minutes."),
                status=429,
            )

        form = self._read_form_body()
        password = (form.get("password") or [""])[0]
        if not password:
            return self._send_html(render_login_page(error="Password required."), status=400)

        ok = pam_auth.authenticate("root", password, service=PAM_SERVICE)
        if not ok:
            record_failed_attempt(ip)
            return self._send_html(render_login_page(error="Invalid password."), status=401)

        record_successful_login(ip)
        token = create_session()
        self._redirect("/admin-panel/", set_cookie=token)

    def _handle_logout(self):
        token = self._get_cookie(SESSION_COOKIE)
        if token:
            destroy_session(token)
        self._redirect("/admin-panel/login", clear_cookie=True)

    def _handle_dashboard(self):
        if not self._current_session():
            return self._redirect("/admin-panel/login")
        stats = get_dashboard_stats()
        body = render_dashboard_body(stats)
        self._send_html(render_shell_page("Dashboard", body, "/admin-panel/"))

    def _handle_placeholder(self, path):
        if not self._current_session():
            return self._redirect("/admin-panel/login")
        label = next((lbl for p, lbl in NAV_SECTIONS if p == path), None)
        if label is None:
            return self._send_html("<h1>404 Not Found</h1>", status=404)
        body = (
            f"<h2>{html.escape(label)}</h2>"
            '<p class="muted">Coming soon in a future update -- for now, use the bash menu '
            "(<code>menu</code> over SSH) for this section.</p>"
        )
        self._send_html(render_shell_page(label, body, path))

    # ---- SSH / DNS (Phase 1) ----
    def _form_value(self, form, name, default=""):
        return (form.get(name) or [default])[0]

    def _handle_ssh_page(self):
        if not self._current_session():
            return self._redirect("/admin-panel/login")
        self._send_html(render_shell_page("SSH / DNS", render_ssh_page(), "/admin-panel/ssh"))

    def _handle_ssh_create(self):
        if not self._current_session():
            return self._redirect("/admin-panel/login")
        form = self._read_form_body()
        username = self._form_value(form, "username")
        password = self._form_value(form, "password")
        days = self._form_value(form, "days")
        conn_limit = self._form_value(form, "conn_limit", "0")
        bw_limit_gb = self._form_value(form, "bw_limit_gb", "0")
        output = run_text(
            ["bash", SSH_ACTIONS_SCRIPT, "create", username, password, days, conn_limit, bw_limit_gb]
        )
        body = render_action_result("Create SSH Account", output, "/admin-panel/ssh")
        self._send_html(render_shell_page("SSH / DNS", body, "/admin-panel/ssh"))

    def _handle_ssh_trial(self):
        if not self._current_session():
            return self._redirect("/admin-panel/login")
        output = run_text(["bash", TRIAL_SSH_SCRIPT])
        body = render_action_result("Create Trial SSH Account", output, "/admin-panel/ssh")
        self._send_html(render_shell_page("SSH / DNS", body, "/admin-panel/ssh"))

    def _handle_ssh_delete(self):
        if not self._current_session():
            return self._redirect("/admin-panel/login")
        form = self._read_form_body()
        username = self._form_value(form, "username")
        output = run_text(["bash", SSH_ACTIONS_SCRIPT, "delete", username])
        body = render_action_result("Delete SSH Account", output, "/admin-panel/ssh")
        self._send_html(render_shell_page("SSH / DNS", body, "/admin-panel/ssh"))

    def _handle_ssh_renew(self):
        if not self._current_session():
            return self._redirect("/admin-panel/login")
        form = self._read_form_body()
        username = self._form_value(form, "username")
        days = self._form_value(form, "days")
        output = run_text(["bash", SSH_ACTIONS_SCRIPT, "renew", username, days])
        body = render_action_result("Renew SSH Account", output, "/admin-panel/ssh")
        self._send_html(render_shell_page("SSH / DNS", body, "/admin-panel/ssh"))

    def _handle_ssh_generate_config(self):
        if not self._current_session():
            return self._redirect("/admin-panel/login")
        form = self._read_form_body()
        username = self._form_value(form, "username")
        output = run_text(["bash", GENERATE_SSH_CONFIG_SCRIPT, username])
        body = render_action_result("SSH Account Config", output, "/admin-panel/ssh")
        self._send_html(render_shell_page("SSH / DNS", body, "/admin-panel/ssh"))

    def _handle_ssh_active(self):
        if not self._current_session():
            return self._redirect("/admin-panel/login")
        self._send_html(render_shell_page("Check Active Users", render_ssh_active_page(), "/admin-panel/ssh"))

    def _handle_ssh_locked(self):
        if not self._current_session():
            return self._redirect("/admin-panel/login")
        self._send_html(render_shell_page("Check Locked Users", render_ssh_locked_page(), "/admin-panel/ssh"))

    def _handle_ssh_locked_unlock(self):
        if not self._current_session():
            return self._redirect("/admin-panel/login")
        form = self._read_form_body()
        username = self._form_value(form, "username")
        action = self._form_value(form, "action")
        value = self._form_value(form, "value")
        if action == "bandwidth":
            result = run_json(["bash", SSH_PANEL_ACTIONS_SCRIPT, "unlock-bandwidth", username, value])
        elif action == "connlimit":
            result = run_json(["bash", SSH_PANEL_ACTIONS_SCRIPT, "unlock-connlimit", username, value])
        else:
            result = run_json(["bash", SSH_PANEL_ACTIONS_SCRIPT, "unlock-plain", username])
        msg = result.get("message", "Done." if result.get("ok") else "Failed.")
        body = render_action_result("Unlock Account", msg, "/admin-panel/ssh/locked", "Back to Locked Users")
        self._send_html(render_shell_page("Locked Users", body, "/admin-panel/ssh"))

    def _handle_ssh_autokill(self):
        if not self._current_session():
            return self._redirect("/admin-panel/login")
        self._send_html(render_shell_page("Autokill Setup", render_ssh_autokill_page(), "/admin-panel/ssh"))

    def _handle_ssh_autokill_enable(self):
        if not self._current_session():
            return self._redirect("/admin-panel/login")
        form = self._read_form_body()
        limit = self._form_value(form, "limit", "2")
        run_json(["bash", SSH_PANEL_ACTIONS_SCRIPT, "autokill-enable", limit])
        self._redirect("/admin-panel/ssh/autokill")

    def _handle_ssh_autokill_disable(self):
        if not self._current_session():
            return self._redirect("/admin-panel/login")
        run_json(["bash", SSH_PANEL_ACTIONS_SCRIPT, "autokill-disable"])
        self._redirect("/admin-panel/ssh/autokill")

    # ---- Xray protocols: VMess/VLESS/Trojan/Shadowsocks (Phase 2) ----
    def _handle_xray_page(self, proto):
        if not self._current_session():
            return self._redirect("/admin-panel/login")
        label = XRAY_PROTOCOLS[proto]["label"]
        self._send_html(render_shell_page(label, render_xray_page(proto), f"/admin-panel/{proto}"))

    def _handle_xray_create(self, proto):
        if not self._current_session():
            return self._redirect("/admin-panel/login")
        form = self._read_form_body()
        username = self._form_value(form, "username")
        days = self._form_value(form, "days")
        output = run_text(["bash", XRAY_ACTIONS_SCRIPT, "create", proto, username, days])
        label = XRAY_PROTOCOLS[proto]["label"]
        body = render_action_result(f"Create {label} Account", output, f"/admin-panel/{proto}")
        self._send_html(render_shell_page(label, body, f"/admin-panel/{proto}"))

    def _handle_xray_trial(self, proto):
        if not self._current_session():
            return self._redirect("/admin-panel/login")
        script = os.path.join(INSTALL_DIR, "menu", XRAY_PROTOCOLS[proto]["trial_script"])
        output = run_text(["bash", script])
        label = XRAY_PROTOCOLS[proto]["label"]
        body = render_action_result(f"Create Trial {label} Account", output, f"/admin-panel/{proto}")
        self._send_html(render_shell_page(label, body, f"/admin-panel/{proto}"))

    def _handle_xray_delete(self, proto):
        if not self._current_session():
            return self._redirect("/admin-panel/login")
        form = self._read_form_body()
        username = self._form_value(form, "username")
        output = run_text(["bash", XRAY_ACTIONS_SCRIPT, "delete", proto, username])
        label = XRAY_PROTOCOLS[proto]["label"]
        body = render_action_result(f"Delete {label} Account", output, f"/admin-panel/{proto}")
        self._send_html(render_shell_page(label, body, f"/admin-panel/{proto}"))

    def _handle_xray_renew(self, proto):
        if not self._current_session():
            return self._redirect("/admin-panel/login")
        form = self._read_form_body()
        username = self._form_value(form, "username")
        days = self._form_value(form, "days")
        output = run_text(["bash", XRAY_ACTIONS_SCRIPT, "renew", proto, username, days])
        label = XRAY_PROTOCOLS[proto]["label"]
        body = render_action_result(f"Renew {label} Account", output, f"/admin-panel/{proto}")
        self._send_html(render_shell_page(label, body, f"/admin-panel/{proto}"))

    def _handle_xray_generate_config(self, proto):
        if not self._current_session():
            return self._redirect("/admin-panel/login")
        form = self._read_form_body()
        username = self._form_value(form, "username")
        output = run_text(["bash", GENERATE_XRAY_CONFIG_SCRIPT, proto, username])
        label = XRAY_PROTOCOLS[proto]["label"]
        body = render_action_result(f"{label} Account Config", output, f"/admin-panel/{proto}")
        self._send_html(render_shell_page(label, body, f"/admin-panel/{proto}"))


def main():
    if os.geteuid() != 0:
        print("Run as root.", file=sys.stderr)
        sys.exit(1)
    server = http.server.ThreadingHTTPServer((BIND_HOST, BIND_PORT), Handler)
    print(f"admin-panel: listening on {BIND_HOST}:{BIND_PORT}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()

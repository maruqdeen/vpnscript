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
        if path.startswith("/admin-panel/"):
            return self._handle_placeholder(path)
        self._send_html("<h1>404 Not Found</h1>", status=404)

    def do_POST(self):
        path = urllib.parse.urlsplit(self.path).path
        if path == "/admin-panel/login":
            return self._handle_login_post()
        if path == "/admin-panel/logout":
            return self._handle_logout()
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

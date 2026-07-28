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

WG_ACTIONS_SCRIPT = os.path.join(INSTALL_DIR, "core", "telegram-wireguard-actions.sh")
CHECK_WIREGUARD_SCRIPT = os.path.join(INSTALL_DIR, "menu", "check-wireguard-user.sh")
GENERATE_WIREGUARD_CONFIG_SCRIPT = os.path.join(INSTALL_DIR, "menu", "generate-wireguard-config.sh")

SETTINGS_ACTIONS_SCRIPT = os.path.join(INSTALL_DIR, "core", "settings-panel-actions.sh")
SETTINGS_SIMPLE_ACTIONS = {
    "/admin-panel/settings/port-info": ("port-info", "Service Port Info"),
    "/admin-panel/settings/speedtest": ("speedtest", "Speedtest VPS"),
    "/admin-panel/settings/check-running": ("check-running", "Running Services"),
    "/admin-panel/settings/restart-all": ("restart-all", "Restart All Services"),
    "/admin-panel/settings/clear-ram-cache": ("clear-ram-cache", "Clear RAM Cache"),
}
SETTINGS_TOGGLES = {
    "haproxy": {"label": "HAProxy (SSH-SSL)", "flag": "haproxy.enabled", "script": "haproxy.sh"},
    "sslh": {"label": "SSLH Multiplex", "flag": "sslh.enabled", "script": "sslh.sh"},
    "badvpn": {"label": "BadVPN (UDPGW)", "flag": "badvpn.enabled", "script": "badvpn.sh"},
    "openvpn": {"label": "OpenVPN (TCP/UDP)", "flag": "openvpn.enabled", "script": "openvpn.sh"},
    "proxy": {"label": "HTTP & SOCKS Proxy", "flag": "proxy.enabled", "script": "proxy.sh"},
    "stunnel": {"label": "Stunnel (SSH-over-TLS)", "flag": "stunnel.enabled", "script": "stunnel.sh"},
    "udpcustom": {"label": "SSH UDP Custom", "flag": "udpcustom.enabled", "script": "udp-custom.sh"},
}

SECURITY_TOGGLES = {
    "fail2ban": {"label": "Fail2ban", "flag": "fail2ban.enabled", "script": "fail2ban.sh"},
    "anti-torrent": {"label": "Anti-Torrent", "flag": "anti-torrent.enabled", "script": "anti-torrent.sh"},
    "ddos-protection": {"label": "DDoS Protection", "flag": "ddos-protection.enabled", "script": "ddos-protection.sh"},
    "clean-expired": {"label": "Clean All Expired User", "flag": "clean-expired.enabled", "script": "clean-expired.sh"},
}

TELEGRAM_BOT_ACTIONS_SCRIPT = os.path.join(INSTALL_DIR, "core", "telegram-bot-panel-actions.sh")
ACCESS_LABELS = {
    "ssh": "SSH/DNS",
    "vmess": "Xray Vmess",
    "vless": "Xray Vless",
    "trojan": "Xray Trojan",
    "wireguard": "Wireguard",
}


def _flag_enabled(flag_name):
    return os.path.exists(os.path.join(INSTALL_DIR, flag_name))

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


def run_text(cmd, input_text=None):
    """Run a backend script expected to print a human-readable card/message
    (the existing Telegram-bot-facing text mode) -- used for one-shot
    create/delete/renew actions, displayed verbatim in a <pre> block.
    input_text, if given, is piped to the script's stdin (e.g. the banner
    editor, which reads its new text that way rather than as an argv)."""
    try:
        result = subprocess.run(cmd, input=input_text, capture_output=True, text=True, timeout=30)
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
    ("/admin-panel/backup", "Backup"),
]

# ---- icons: shared outline set (Feather-style, 24x24, stroke=currentColor) ----
ICONS = {
    "grid": '<rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/>'
            '<rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/>',
    "terminal": '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M7 9l3 3-3 3M12 15h5"/>',
    "shield": '<path d="M12 3l7 3v6c0 4.5-3 7.5-7 9-4-1.5-7-4.5-7-9V6l7-3z"/>',
    "shield-check": '<path d="M12 3l7 3v6c0 4.5-3 7.5-7 9-4-1.5-7-4.5-7-9V6l7-3z"/><path d="M9 12l2 2 4-4"/>',
    "zap": '<path d="M13 2L4 14h6l-1 8 9-12h-6l1-8z"/>',
    "lock": '<rect x="5" y="11" width="14" height="9" rx="2"/><path d="M8 11V7a4 4 0 018 0v4"/>',
    "eye-off": '<path d="M3 3l18 18M10.6 5.1A9.7 9.7 0 0112 5c5 0 9 4 10 7-.5 1.4-1.4 3-2.8 4.4M6.6 6.6C4.5 8 3 9.9 2 12c1 3 5 7 10 7 1.2 0 2.3-.2 3.4-.6M9.9 9.9a3 3 0 004.2 4.2"/>',
    "layers": '<path d="M12 3l9 5-9 5-9-5 9-5z"/><path d="M3 12l9 5 9-5"/>',
    "sliders": '<line x1="4" y1="6" x2="20" y2="6"/><circle cx="9" cy="6" r="2"/><line x1="4" y1="12" x2="20" y2="12"/>'
               '<circle cx="15" cy="12" r="2"/><line x1="4" y1="18" x2="20" y2="18"/><circle cx="9" cy="18" r="2"/>',
    "bot": '<rect x="3" y="5" width="18" height="12" rx="2"/><path d="M8 21l4-4 4 4"/><circle cx="8.5" cy="11" r="1"/><circle cx="15.5" cy="11" r="1"/>',
    "cloud": '<path d="M7 18a4 4 0 01-1-7.9A5 5 0 0116 8a4.5 4.5 0 011 8.9"/><path d="M12 12v6M9 15l3-3 3 3"/>',
    "logout": '<path d="M9 21H5a2 2 0 01-2-2V5a2 2 0 012-2h4"/><path d="M16 17l5-5-5-5"/><path d="M21 12H9"/>',
    "clock": '<circle cx="12" cy="12" r="9"/><path d="M12 8v4l3 2"/>',
    "globe": '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3a15 15 0 010 18M12 3a15 15 0 000 18"/>',
    "cpu": '<rect x="6" y="6" width="12" height="12" rx="1"/><path d="M9 2v3M15 2v3M9 19v3M15 19v3M2 9h3M2 15h3M19 9h3M19 15h3"/>',
    "activity": '<path d="M3 12h4l2-7 4 14 2-7h6"/>',
    "refresh": '<path d="M21 12a9 9 0 10-3.2 6.9"/><path d="M21 7v5h-5"/>',
    "users": '<circle cx="9" cy="8" r="3"/><path d="M2 20c0-3.3 3.1-6 7-6s7 2.7 7 6"/><circle cx="17" cy="9" r="2.5"/><path d="M22 20c0-2.6-1.9-4.8-4.5-5.6"/>',
    "download": '<path d="M12 3v12M7 10l5 5 5-5"/><path d="M4 19h16"/>',
    "server": '<rect x="3" y="4" width="18" height="6" rx="1"/><rect x="3" y="14" width="18" height="6" rx="1"/><path d="M7 7h.01M7 17h.01"/>',
    "wifi": '<path d="M2 8.5a16 16 0 0120 0M5.5 12a11 11 0 0113 0M9 15.5a6 6 0 016 0"/><circle cx="12" cy="19" r="1"/>',
    "power": '<path d="M12 2v9"/><path d="M18.4 6.6a9 9 0 11-12.8 0"/>',
    "dot": '<circle cx="12" cy="12" r="3"/>',
}

NAV_ICONS = {
    "/admin-panel/": "grid",
    "/admin-panel/ssh": "terminal",
    "/admin-panel/vmess": "shield",
    "/admin-panel/vless": "zap",
    "/admin-panel/trojan": "lock",
    "/admin-panel/shadowsocks": "eye-off",
    "/admin-panel/wireguard": "layers",
    "/admin-panel/settings": "sliders",
    "/admin-panel/security": "shield-check",
    "/admin-panel/bot-api": "bot",
    "/admin-panel/backup": "cloud",
}


def icon(name, css_class="icon"):
    body = ICONS.get(name, ICONS["dot"])
    return (
        f'<svg class="{css_class}" viewBox="0 0 24 24" fill="none" stroke="currentColor" '
        f'stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">{body}</svg>'
    )


BASE_CSS = """
/* ---- tokens: light (default) ---- */
:root {
  --hue: 255;
  --bg: oklch(97.8% 0.004 var(--hue));
  --surface: oklch(100% 0 0);
  --surface-2: oklch(96.5% 0.005 var(--hue));
  --sidebar-bg: oklch(95.5% 0.007 var(--hue));
  --border: oklch(89% 0.006 var(--hue));
  --border-strong: oklch(82% 0.009 var(--hue));
  --text: oklch(23% 0.014 var(--hue));
  --text-muted: oklch(45% 0.014 var(--hue));
  --text-on-accent: oklch(99% 0 0);

  --accent: oklch(55% 0.19 258);
  --accent-hover: oklch(48% 0.19 258);
  --accent-tint: oklch(93% 0.03 258);

  --success: oklch(48% 0.13 152);
  --success-tint: oklch(93% 0.05 152);
  --danger: oklch(53% 0.21 25);
  --danger-hover: oklch(46% 0.21 25);
  --danger-tint: oklch(94% 0.06 25);

  --shadow-sm: 0 1px 2px oklch(25% 0.02 var(--hue) / 0.06);
  --shadow-md: 0 2px 8px oklch(25% 0.02 var(--hue) / 0.08), 0 1px 2px oklch(25% 0.02 var(--hue) / 0.06);

  --radius-sm: 6px;
  --radius-md: 10px;

  --text-xs: 0.75rem;
  --text-sm: 0.8125rem;
  --text-base: 0.875rem;
  --text-md: 1rem;
  --text-lg: 1.25rem;
  --text-xl: 1.5rem;

  color-scheme: light;
}

/* ---- tokens: dark (opt-in via [data-theme]) ---- */
:root[data-theme="dark"] {
  --bg: oklch(18% 0.010 var(--hue));
  --surface: oklch(22% 0.010 var(--hue));
  --surface-2: oklch(26% 0.012 var(--hue));
  --sidebar-bg: oklch(15% 0.012 var(--hue));
  --border: oklch(32% 0.014 var(--hue));
  --border-strong: oklch(40% 0.016 var(--hue));
  --text: oklch(93% 0.006 var(--hue));
  --text-muted: oklch(70% 0.012 var(--hue));
  --text-on-accent: oklch(99% 0 0);

  --accent: oklch(64% 0.18 258);
  --accent-hover: oklch(70% 0.18 258);
  --accent-tint: oklch(30% 0.06 258);

  --success: oklch(72% 0.15 152);
  --success-tint: oklch(30% 0.07 152);
  --danger: oklch(68% 0.19 25);
  --danger-hover: oklch(74% 0.19 25);
  --danger-tint: oklch(32% 0.09 25);

  --shadow-sm: 0 1px 2px oklch(0% 0 0 / 0.24);
  --shadow-md: 0 4px 12px oklch(0% 0 0 / 0.32), 0 1px 3px oklch(0% 0 0 / 0.24);

  color-scheme: dark;
}

/* ---- base ---- */
* { box-sizing: border-box; }
body {
  margin: 0;
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
  background: var(--bg);
  color: var(--text);
  font-size: var(--text-base);
  line-height: 1.5;
  -webkit-font-smoothing: antialiased;
}
@media (prefers-reduced-motion: no-preference) {
  body, .card, .stat, button, a, nav li a, input, textarea, select, .theme-toggle svg {
    transition: background-color 180ms ease, border-color 180ms ease, color 180ms ease,
                box-shadow 180ms ease, transform 150ms ease;
  }
}

a { color: var(--accent); text-decoration: none; }
a:hover { text-decoration: underline; }
a:focus-visible, button:focus-visible, input:focus-visible, textarea:focus-visible,
select:focus-visible, [tabindex]:focus-visible {
  outline: 2px solid var(--accent);
  outline-offset: 2px;
}

h2 { margin: 0 0 20px; font-size: var(--text-xl); font-weight: 600; letter-spacing: -0.01em; text-wrap: balance; }
h3 { margin: 0 0 12px; font-size: var(--text-sm); font-weight: 600; text-transform: uppercase;
     letter-spacing: 0.04em; color: var(--text-muted); text-wrap: balance; }
.muted { color: var(--text-muted); font-size: var(--text-sm); }
code {
  background: var(--surface-2); border: 1px solid var(--border);
  padding: 2px 6px; border-radius: 4px; font-size: 0.85em;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
}
::placeholder { color: var(--text-muted); opacity: 1; }

/* ---- shell / sidebar ---- */
.shell { display: flex; min-height: 100vh; }
nav {
  width: 240px; flex-shrink: 0; display: flex; flex-direction: column;
  background: var(--sidebar-bg); border-right: 1px solid var(--border); padding: 16px 0;
}
.nav-head {
  display: flex; align-items: center; justify-content: space-between;
  padding: 0 16px 16px; margin-bottom: 4px; border-bottom: 1px solid var(--border);
}
nav h1 { font-size: var(--text-sm); font-weight: 700; margin: 0; color: var(--text); }
nav ul { list-style: none; margin: 8px 0; padding: 0 8px; flex: 1; }
nav li a {
  display: flex; align-items: center; gap: 10px; padding: 9px 12px; margin: 2px 0;
  border-radius: var(--radius-sm); color: var(--text-muted); font-size: var(--text-sm); font-weight: 500;
}
nav li a:hover { background: var(--surface-2); color: var(--text); text-decoration: none; }
nav li.active a { background: var(--accent-tint); color: var(--accent); font-weight: 600; }
nav .logout {
  display: flex; align-items: center; gap: 10px; margin: 8px 16px 0; padding: 12px 12px 0;
  border-top: 1px solid var(--border); color: var(--danger); font-size: var(--text-sm); font-weight: 500;
}
nav .logout:hover { text-decoration: none; color: var(--danger-hover); }

/* ---- icons ---- */
.icon { width: 14px; height: 14px; flex-shrink: 0; }
.nav-icon { width: 17px; height: 17px; flex-shrink: 0; }
.stat-icon { width: 15px; height: 15px; flex-shrink: 0; color: var(--accent); }

.theme-toggle {
  display: inline-flex; align-items: center; justify-content: center;
  width: 30px; height: 30px; padding: 0; flex-shrink: 0;
  border-radius: var(--radius-sm); border: 1px solid var(--border);
  background: var(--surface); color: var(--text-muted); cursor: pointer;
}
.theme-toggle:hover { background: var(--surface-2); color: var(--text); }
.theme-toggle svg { width: 16px; height: 16px; display: block; }
.theme-toggle .icon-moon { display: none; }
:root[data-theme="dark"] .theme-toggle .icon-sun { display: none; }
:root[data-theme="dark"] .theme-toggle .icon-moon { display: block; }
.login-wrap .theme-toggle { position: fixed; top: 20px; right: 20px; }

main { flex: 1; padding: 32px; max-width: 1120px; }

/* ---- page header ---- */
.page-head { display: flex; align-items: center; justify-content: space-between; gap: 16px; flex-wrap: wrap; margin-bottom: 20px; }
.page-head h2 { margin: 0; }
.page-head-meta { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
.bw-pill {
  display: inline-flex; align-items: center; gap: 6px; padding: 6px 12px; border-radius: 999px;
  background: var(--success-tint); color: var(--success); font-size: var(--text-xs); font-weight: 600;
  font-variant-numeric: tabular-nums; white-space: nowrap;
}
.btn-ghost {
  display: inline-flex; align-items: center; gap: 6px; padding: 6px 12px; border-radius: var(--radius-sm);
  border: 1px solid var(--border); background: var(--surface); color: var(--text);
  font-size: var(--text-xs); font-weight: 600;
}
.btn-ghost:hover { background: var(--surface-2); text-decoration: none; }

/* ---- cards / stats ---- */
.card {
  background: var(--surface); border: 1px solid var(--border); border-radius: var(--radius-md);
  padding: 20px 24px; margin-bottom: 20px; box-shadow: var(--shadow-sm);
}
.card-feature { position: relative; z-index: 0; overflow: hidden; }
.card-icon-bg {
  position: absolute; top: 10px; right: 10px; z-index: -1;
  width: 72px; height: 72px; color: var(--text-muted); opacity: 0.07; pointer-events: none;
}
.grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 12px; }
.stat {
  background: var(--surface-2); border: 1px solid var(--border); border-top: 3px solid var(--accent);
  border-radius: var(--radius-sm); padding: 14px 14px 12px; min-width: 0;
}
.stat .label {
  display: flex; align-items: center; gap: 6px; font-size: var(--text-xs); color: var(--text-muted);
  font-weight: 500; text-transform: uppercase; letter-spacing: 0.03em;
}
.stat .value {
  font-size: var(--text-lg); margin-top: 4px; font-weight: 600; font-variant-numeric: tabular-nums;
  overflow-wrap: anywhere; word-break: break-word;
}

/* ---- status badges ---- */
.ok, .bad {
  display: inline-flex; align-items: center; gap: 5px; padding: 2px 9px;
  border-radius: 999px; font-size: var(--text-xs); font-weight: 600;
}
.ok { background: var(--success-tint); color: var(--success); }
.bad { background: var(--danger-tint); color: var(--danger); }
.ok::before, .bad::before { content: ""; width: 6px; height: 6px; border-radius: 50%; background: currentColor; }

/* ---- login ---- */
.login-wrap { display: flex; align-items: center; justify-content: center; min-height: 100vh; padding: 20px; }
.login-box {
  background: var(--surface); border: 1px solid var(--border); box-shadow: var(--shadow-md);
  padding: 36px 32px; border-radius: var(--radius-md); width: 100%; max-width: 340px;
}
.login-box h1 { font-size: var(--text-lg); font-weight: 700; margin: 0 0 24px; color: var(--text); }
.login-box label { display: block; font-size: var(--text-sm); font-weight: 500; color: var(--text-muted); margin-bottom: 6px; }
.login-box input {
  width: 100%; padding: 10px 12px; margin: 0 0 18px; border-radius: var(--radius-sm);
  border: 1px solid var(--border-strong); background: var(--surface); color: var(--text);
  font-size: var(--text-base); font-family: inherit;
}
.login-box button { width: 100%; margin-top: 4px; }
.error {
  background: var(--danger-tint); color: var(--danger); padding: 10px 12px;
  border-radius: var(--radius-sm); margin-bottom: 16px; font-size: var(--text-sm); font-weight: 500;
}

/* ---- tables ---- */
table { width: 100%; border-collapse: collapse; margin-top: 4px; font-size: var(--text-sm); }
th, td { text-align: left; padding: 10px 8px; border-bottom: 1px solid var(--border); }
th { color: var(--text-muted); font-weight: 600; font-size: var(--text-xs); text-transform: uppercase; letter-spacing: 0.03em; }
tr:last-child td { border-bottom: none; }
tr:hover td { background: var(--surface-2); }

/* ---- forms / buttons ---- */
.stack-form label {
  display: block; margin-top: 12px; margin-bottom: 4px; font-size: var(--text-xs);
  font-weight: 500; color: var(--text-muted); text-transform: uppercase; letter-spacing: 0.03em;
}
.stack-form input, .stack-form textarea, .stack-form select {
  width: 100%; padding: 9px 10px; border-radius: var(--radius-sm);
  border: 1px solid var(--border-strong); background: var(--surface); color: var(--text);
  font-size: var(--text-base); font-family: inherit;
}
.stack-form textarea { resize: vertical; min-height: 100px; }

input:disabled, textarea:disabled, select:disabled {
  background: var(--surface-2); color: var(--text-muted); cursor: not-allowed;
}

button {
  margin-top: 16px; padding: 9px 16px; border-radius: var(--radius-sm); border: 1px solid transparent;
  background: var(--accent); color: var(--text-on-accent); font-size: var(--text-sm); font-weight: 600;
  font-family: inherit; cursor: pointer;
}
button:hover { background: var(--accent-hover); }
button:active { transform: translateY(1px); }
button:disabled { background: var(--border-strong); color: var(--text-muted); cursor: not-allowed; transform: none; }
button.danger { background: var(--danger); }
button.danger:hover { background: var(--danger-hover); }

.inline-form { display: inline-block; margin-right: 8px; margin-bottom: 6px; vertical-align: middle; }
.inline-form button { margin-top: 0; padding: 7px 12px; font-size: var(--text-xs); }
.inline-form input {
  width: 92px; padding: 6px 8px; margin: 0; vertical-align: middle;
  border-radius: var(--radius-sm); border: 1px solid var(--border-strong);
  background: var(--surface); color: var(--text); font-size: var(--text-sm); font-family: inherit;
}

.output {
  background: var(--surface-2); border: 1px solid var(--border); padding: 16px; border-radius: var(--radius-sm);
  white-space: pre-wrap; word-break: break-word; line-height: 1.6; color: var(--text);
  font-size: var(--text-sm); font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
}
.links a { margin-right: 20px; font-weight: 500; font-size: var(--text-sm); }

/* ---- structural responsiveness ---- */
@media (max-width: 720px) {
  .shell { flex-direction: column; }
  nav { width: 100%; flex-direction: row; align-items: center; padding: 10px 12px; flex-wrap: wrap; }
  .nav-head { border-bottom: none; padding: 0; margin: 0; flex: 1; }
  nav ul { display: flex; flex-wrap: wrap; flex: 1 1 100%; margin: 10px 0 0; padding: 0; gap: 4px; }
  nav li a { padding: 6px 10px; }
  nav .logout { margin: 10px 0 0; padding-top: 10px; border-top: 1px solid var(--border); flex: 1 1 100%; }
  main { padding: 20px 16px; }
  table { display: block; overflow-x: auto; white-space: nowrap; }
}
"""

THEME_INIT_SCRIPT = """(function(){
  var t = localStorage.getItem('admin-panel-theme');
  if (!t) t = window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
  document.documentElement.setAttribute('data-theme', t);
})();
function toggleTheme(){
  var next = document.documentElement.getAttribute('data-theme') === 'dark' ? 'light' : 'dark';
  document.documentElement.setAttribute('data-theme', next);
  localStorage.setItem('admin-panel-theme', next);
}"""

THEME_TOGGLE_BUTTON = """<button type="button" class="theme-toggle" onclick="toggleTheme()" aria-label="Toggle dark mode" title="Toggle dark mode">
<svg class="icon-sun" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.93 4.93l1.41 1.41M17.66 17.66l1.41 1.41M2 12h2M20 12h2M6.34 17.66l-1.41 1.41M19.07 4.93l-1.41 1.41"/></svg>
<svg class="icon-moon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"/></svg>
</button>"""


def render_login_page(error=None):
    error_html = f'<div class="error">{html.escape(error)}</div>' if error else ""
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Login -- VPN-Starter-Kit Admin Panel</title>
<script>{THEME_INIT_SCRIPT}</script>
<style>{BASE_CSS}</style></head>
<body><div class="login-wrap">
{THEME_TOGGLE_BUTTON}
<div class="login-box">
<h1>VPN-Starter-Kit Admin Panel</h1>
{error_html}
<form method="post" action="/admin-panel/login">
<label for="login-username">Username</label>
<input id="login-username" type="text" value="root" disabled>
<label for="login-password">Password (your VPS root password)</label>
<input id="login-password" type="password" name="password" autofocus>
<button type="submit">Login</button>
</form>
</div></div></body></html>"""


def render_shell_page(title, body_html, current_path):
    nav_items = ""
    for path, label in NAV_SECTIONS:
        active = ' class="active"' if path == current_path else ""
        nav_icon = icon(NAV_ICONS.get(path, "dot"), "nav-icon")
        nav_items += f'<li{active}><a href="{html.escape(path)}">{nav_icon}<span>{html.escape(label)}</span></a></li>\n'
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(title)} -- VPN-Starter-Kit Admin Panel</title>
<script>{THEME_INIT_SCRIPT}</script>
<style>{BASE_CSS}</style></head>
<body><div class="shell">
<nav><div class="nav-head"><h1>VPN-Starter-Kit</h1>{THEME_TOGGLE_BUTTON}</div><ul>{nav_items}</ul>
<a class="logout" href="/admin-panel/logout">{icon("logout", "nav-icon")}<span>Logout</span></a></nav>
<main>{body_html}</main>
</div></body></html>"""


def _svc_badge(active):
    return '<span class="ok">Active</span>' if active else '<span class="bad">Inactive</span>'


def _stat(icon_name, label, value_html):
    return (
        f'<div class="stat"><div class="label">{icon(icon_name, "stat-icon")}<span>{html.escape(label)}</span></div>'
        f'<div class="value">{value_html}</div></div>'
    )


def _feature_card(icon_name, title, inner_html):
    return (
        f'<div class="card card-feature">{icon(icon_name, "card-icon-bg")}'
        f'<h3>{html.escape(title)}</h3>{inner_html}</div>'
    )


def render_dashboard_body(stats):
    if stats is None:
        return '<h2>Dashboard</h2><p class="error">Could not load dashboard stats -- check: journalctl -u vpn-admin-panel -n 30 --no-pager</p>'

    server = stats.get("server", {})
    services = stats.get("services", {})
    accounts = stats.get("accounts", {})
    bandwidth = stats.get("bandwidth", {})

    server_rows = (
        _stat("clock", "Uptime", html.escape(str(server.get('uptime', 'n/a'))))
        + _stat("globe", "Server IP", html.escape(str(server.get('ip', 'n/a'))))
        + _stat("cpu", "OS", html.escape(str(server.get('os', 'n/a'))))
        + _stat("cpu", "RAM", f"{html.escape(str(server.get('ram_used_mb', 0)))} / {html.escape(str(server.get('ram_total_mb', 0)))} MB")
        + _stat("activity", "CPU", f"{html.escape(str(server.get('cpu_pct', 0)))}%")
        + _stat("globe", "Domain", html.escape(str(server.get('domain', 'n/a'))))
        + _stat("wifi", "NS Domain", html.escape(str(server.get('ns_domain', 'n/a'))))
        + _stat("power", "Auto Reboot", html.escape(str(server.get('reboot_status', 'n/a'))))
    )
    svc_rows = "".join(
        _stat("server", name, _svc_badge(active)) for name, active in services.items()
    )
    acc_rows = "".join(
        _stat("users", name.capitalize(), str(int(count))) for name, count in accounts.items()
    )
    bw_rows = (
        _stat("download", "Today", html.escape(str(bandwidth.get('today_human', '0B'))))
        + _stat("download", "Yesterday", html.escape(str(bandwidth.get('yesterday_human', '0B'))))
        + _stat("download", "This Month", html.escape(str(bandwidth.get('month_human', '0B'))))
    )

    header = f"""<div class="page-head">
<h2>Dashboard</h2>
<div class="page-head-meta">
<span class="bw-pill">{icon('download', 'icon')}Today {html.escape(str(bandwidth.get('today_human', '0B')))} &middot; Month {html.escape(str(bandwidth.get('month_human', '0B')))}</span>
<a class="btn-ghost" href="/admin-panel/">{icon('refresh', 'icon')}Refresh</a>
</div></div>"""

    return (
        header
        + _feature_card("cpu", "Server Info", f'<div class="grid">{server_rows}</div>')
        + _feature_card("server", "Active Service", f'<div class="grid">{svc_rows}</div>')
        + _feature_card("users", "Active Account", f'<div class="grid">{acc_rows}</div>')
        + _feature_card("download", "Bandwidth Usage", f'<div class="grid">{bw_rows}</div>')
    )


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
<form method="post" action="/admin-panel/ssh/trial">
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
<form method="post" action="/admin-panel/{proto}/trial">
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


def render_wireguard_page():
    result = run_json(["bash", WG_ACTIONS_SCRIPT, "list"], extra_env={"PANEL_JSON": "1"})
    rows = ""
    if result.get("ok"):
        for u in result.get("users", []):
            uname = html.escape(u.get("username", ""))
            rows += f"""<tr>
<td>{uname}</td>
<td>{html.escape(u.get('address', ''))}</td>
<td>{html.escape(u.get('expiry', ''))}</td>
<td>
<form method="post" action="/admin-panel/wireguard/generate-config" class="inline-form">
<input type="hidden" name="username" value="{uname}">
<button type="submit">View Config</button>
</form>
<form method="post" action="/admin-panel/wireguard/renew" class="inline-form">
<input type="hidden" name="username" value="{uname}">
<input type="number" name="days" placeholder="days" min="1" required>
<button type="submit">Renew</button>
</form>
<form method="post" action="/admin-panel/wireguard/delete" class="inline-form" onsubmit="return confirm('Delete {uname}?')">
<input type="hidden" name="username" value="{uname}">
<button type="submit" class="danger">Delete</button>
</form>
</td>
</tr>"""
    if not rows:
        msg = html.escape(result.get("message", "No accounts yet.")) if not result.get("ok") else "No accounts yet."
        rows = f'<tr><td colspan="4">{msg}</td></tr>'

    return f"""<h2>WireGuard</h2>

<div class="card">
<h3>Create Account</h3>
<form method="post" action="/admin-panel/wireguard/create" class="stack-form">
<label>Username</label>
<input type="text" name="username" required pattern="[a-zA-Z0-9_-]+" title="Letters, digits, - and _ only">
<label>Expiry (days)</label><input type="number" name="days" value="30" required>
<button type="submit">Create</button>
</form>
</div>

<div class="card">
<h3>Accounts</h3>
<table>
<tr><th>Username</th><th>Address</th><th>Expiry</th><th>Actions</th></tr>
{rows}
</table>
</div>

<div class="card links">
<a href="/admin-panel/wireguard/active">Check Active Users</a>
</div>"""


def render_wireguard_active_page():
    output = run_text(["bash", CHECK_WIREGUARD_SCRIPT])
    return f"""<h2>Check Active WireGuard Users</h2>
<div class="card"><pre class="output">{html.escape(output)}</pre></div>
<p><a href="/admin-panel/wireguard">&larr; Back to WireGuard</a></p>"""


def render_settings_page():
    domains = run_json(["bash", SETTINGS_ACTIONS_SCRIPT, "get-domains"])
    domain = domains.get("domain") or "(not set)"
    ns_domain = domains.get("ns_domain") or "(not set)"

    banner_text = run_text(["bash", SETTINGS_ACTIONS_SCRIPT, "get-banner"])
    if banner_text == "(no output)":
        banner_text = ""

    autoreboot = run_json(["bash", SETTINGS_ACTIONS_SCRIPT, "autoreboot-status"])
    ar_enabled = autoreboot.get("enabled", False)
    ar_time = autoreboot.get("time") or "04:00"
    ar_status_html = (
        f'<span class="ok">Enabled</span> (daily at {html.escape(ar_time)})'
        if ar_enabled
        else '<span class="bad">Disabled</span>'
    )

    ssh_engine = "both"
    try:
        with open(os.path.join(INSTALL_DIR, "ssh-engine")) as f:
            ssh_engine = f.read().strip() or "both"
    except OSError:
        pass

    toggles_html = ""
    for key, info in SETTINGS_TOGGLES.items():
        enabled = _flag_enabled(info["flag"])
        badge = '<span class="ok">Enabled</span>' if enabled else '<span class="bad">Disabled</span>'
        toggles_html += f"""<div class="stat">
<div class="label">{html.escape(info['label'])} -- {badge}</div>
<div class="value">
<form method="post" action="/admin-panel/settings/{key}/enable" class="inline-form"><button type="submit">Enable</button></form>
<form method="post" action="/admin-panel/settings/{key}/disable" class="inline-form"><button type="submit" class="danger">Disable</button></form>
</div>
</div>"""

    return f"""<h2>Settings</h2>

<div class="card">
<h3>Change Primary Domain &amp; NS Domain</h3>
<p class="muted">Current primary domain: {html.escape(domain)} &middot; Current NS domain: {html.escape(ns_domain)}</p>
<form method="post" action="/admin-panel/settings/domains" class="stack-form">
<label>New primary (TLS/WS) domain (blank = keep current)</label>
<input type="text" name="domain" placeholder="{html.escape(domain)}">
<label>New SlowDNS NS domain (blank = keep current)</label>
<input type="text" name="ns_domain" placeholder="{html.escape(ns_domain)}">
<button type="submit">Save</button>
</form>
</div>

<div class="card">
<h3>All Service Port Info</h3>
<form method="post" action="/admin-panel/settings/port-info"><button type="submit">View Port Info</button></form>
</div>

<div class="card">
<h3>Change Service Port</h3>
<p class="muted">Not built yet -- reworking nginx/ws.py ports safely on a live server is its own task.</p>
</div>

<div class="card">
<h3>Speedtest VPS</h3>
<form method="post" action="/admin-panel/settings/speedtest"><button type="submit">Run Speedtest</button></form>
</div>

<div class="card">
<h3>Auto Reboot</h3>
<p>Status: {ar_status_html}</p>
<form method="post" action="/admin-panel/settings/autoreboot/enable" class="inline-form">
<input type="text" name="time" value="{html.escape(ar_time)}" placeholder="HH:MM">
<button type="submit">Enable</button>
</form>
<form method="post" action="/admin-panel/settings/autoreboot/disable" class="inline-form">
<button type="submit" class="danger">Disable</button>
</form>
</div>

<div class="card">
<h3>Check Running Service</h3>
<form method="post" action="/admin-panel/settings/check-running"><button type="submit">Check Running Services</button></form>
</div>

<div class="card">
<h3>Restart All Service</h3>
<form method="post" action="/admin-panel/settings/restart-all"><button type="submit">Restart All Services</button></form>
</div>

<div class="card">
<h3>Change Banner</h3>
<form method="post" action="/admin-panel/settings/banner" class="stack-form">
<label>SSH login banner text</label>
<textarea name="banner_text" rows="5">{html.escape(banner_text)}</textarea>
<button type="submit">Save Banner</button>
</form>
</div>

<div class="card">
<h3>Optional Services</h3>
<div class="grid">
{toggles_html}
</div>
</div>

<div class="card">
<h3>SSH Tunnel Engine</h3>
<p class="muted">Current: {html.escape(ssh_engine)} -- controls what ws.py/SlowDNS/HAProxy/SSLH forward tunnel traffic to; OpenSSH's own admin service on :22 is never stopped by this.</p>
<form method="post" action="/admin-panel/settings/ssh-engine" class="inline-form">
<input type="hidden" name="mode" value="dropbear"><button type="submit">Dropbear only</button>
</form>
<form method="post" action="/admin-panel/settings/ssh-engine" class="inline-form">
<input type="hidden" name="mode" value="openssh"><button type="submit">OpenSSH only</button>
</form>
<form method="post" action="/admin-panel/settings/ssh-engine" class="inline-form">
<input type="hidden" name="mode" value="both"><button type="submit">Both (default)</button>
</form>
</div>

<div class="card">
<h3>Clear RAM Cache</h3>
<form method="post" action="/admin-panel/settings/clear-ram-cache"><button type="submit">Clear RAM Cache</button></form>
</div>"""


SECURITY_DESCRIPTIONS = {
    "fail2ban": "OpenSSH brute-force protection. Disabled by default.",
    "anti-torrent": "Heuristic string-match on the FORWARD chain -- VPN client traffic only. Disabled by default.",
    "ddos-protection": "SYN cookies + generous rate limiting, tuned for this box's normal bursty multi-protocol traffic, not a hard per-IP connection cap. Disabled by default.",
    "clean-expired": "Deletes SSH/Xray/WireGuard accounts past their expiry date, daily at 00:30. Enabled by default.",
}


def render_security_page():
    cards = ""
    for key, info in SECURITY_TOGGLES.items():
        enabled = _flag_enabled(info["flag"])
        badge = '<span class="ok">Enabled</span>' if enabled else '<span class="bad">Disabled</span>'
        run_now_button = ""
        if key == "clean-expired":
            run_now_button = f'<form method="post" action="/admin-panel/security/{key}/run" class="inline-form"><button type="submit">Run Now</button></form>'
        cards += f"""<div class="card">
<h3>{html.escape(info['label'])} -- {badge}</h3>
<p class="muted">{html.escape(SECURITY_DESCRIPTIONS.get(key, ''))}</p>
<form method="post" action="/admin-panel/security/{key}/enable" class="inline-form"><button type="submit">Enable</button></form>
<form method="post" action="/admin-panel/security/{key}/disable" class="inline-form"><button type="submit" class="danger">Disable</button></form>
{run_now_button}
</div>"""

    return f"""<h2>Security Mgt</h2>
{cards}"""


def render_bot_api_page():
    admin = run_json(["bash", TELEGRAM_BOT_ACTIONS_SCRIPT, "admin-status"])
    admin_status = admin.get("status", "not_connected")
    admin_bot_username = admin.get("bot_username") or ""

    if admin_status == "connected":
        admin_status_html = (
            f'<span class="ok">CONNECTED</span> '
            f'(<a href="https://t.me/{html.escape(admin_bot_username)}" target="_blank">@{html.escape(admin_bot_username)}</a>)'
        )
    elif admin_status == "waiting_claim":
        code = admin.get("code", "")
        remaining = admin.get("remaining_seconds", 0)
        admin_status_html = (
            f'<span class="bad">WAITING FOR CLAIM</span> '
            f'(<a href="https://t.me/{html.escape(admin_bot_username)}" target="_blank">@{html.escape(admin_bot_username)}</a>)'
            f'<br>Send this code within {int(remaining)}s to become admin: <code>{html.escape(code)}</code>'
        )
    elif admin_status == "unclaimed":
        admin_status_html = (
            f'<span class="bad">RUNNING BUT UNCLAIMED</span> (@{html.escape(admin_bot_username)}) '
            "-- claim code expired, reconnect to generate a new one"
        )
    else:
        admin_status_html = '<span class="bad">NOT CONNECTED</span>'

    user = run_json(["bash", TELEGRAM_BOT_ACTIONS_SCRIPT, "user-status"])
    user_status = user.get("status", "not_connected")
    user_bot_username = user.get("bot_username") or ""
    if user_status == "connected":
        user_status_html = (
            f'<span class="ok">CONNECTED</span> '
            f'(<a href="https://t.me/{html.escape(user_bot_username)}" target="_blank">@{html.escape(user_bot_username)}</a>)'
        )
    else:
        user_status_html = '<span class="bad">NOT CONNECTED</span>'

    access = run_json(["bash", TELEGRAM_BOT_ACTIONS_SCRIPT, "user-access-get"])
    access_map = access.get("access", {})
    access_html = ""
    for key, label in ACCESS_LABELS.items():
        allowed = access_map.get(key, True)
        badge = '<span class="ok">Allow</span>' if allowed else '<span class="bad">Disallow</span>'
        access_html += f"""<div class="stat">
<div class="label">{html.escape(label)} -- {badge}</div>
<div class="value">
<form method="post" action="/admin-panel/bot-api/user-bot/access/toggle" class="inline-form">
<input type="hidden" name="key" value="{key}">
<button type="submit">Toggle</button>
</form>
</div>
</div>"""

    return f"""<h2>Bot &amp; Api Setup</h2>

<div class="card">
<h3>Connect Admin Bot (Telegram)</h3>
<p class="muted">Full remote control -- SSH account management via a claim-code-gated bot.</p>
<p>Status: {admin_status_html}</p>
<form method="post" action="/admin-panel/bot-api/admin-bot/connect" class="stack-form">
<label>Bot Token (from @BotFather)</label>
<input type="password" name="token" placeholder="123456:ABC-DEF...">
<button type="submit">Connect / Reconnect</button>
</form>
<form method="post" action="/admin-panel/bot-api/admin-bot/disconnect">
<button type="submit" class="danger">Disconnect</button>
</form>
</div>

<div class="card">
<h3>Connect User Bot (Telegram)</h3>
<p class="muted">Open self-service bot -- anyone who messages it can create a capped 7-day trial account. Must be a DIFFERENT bot token than the Admin Bot.</p>
<p>Status: {user_status_html}</p>
<form method="post" action="/admin-panel/bot-api/user-bot/connect" class="stack-form">
<label>User Bot Token (a DIFFERENT bot than your Admin Bot)</label>
<input type="password" name="token" placeholder="123456:ABC-DEF...">
<button type="submit">Connect / Reconnect</button>
</form>
<form method="post" action="/admin-panel/bot-api/user-bot/disconnect">
<button type="submit" class="danger">Disconnect</button>
</form>
</div>

<div class="card">
<h3>Control Access (User Bot)</h3>
<p class="muted">Which account types customers can self-create via the User Bot.</p>
<div class="grid">
{access_html}
</div>
</div>

<div class="card">
<h3>Setup Web Api</h3>
<p class="muted">Not built yet -- a separate reseller API project, still to be decided.</p>
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
        if path == "/admin-panel/wireguard":
            return self._handle_wireguard_page()
        if path == "/admin-panel/wireguard/active":
            return self._handle_wireguard_active()
        if path == "/admin-panel/settings":
            return self._handle_settings_page()
        if path == "/admin-panel/security":
            return self._handle_security_page()
        if path == "/admin-panel/bot-api":
            return self._handle_bot_api_page()
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
        if path == "/admin-panel/wireguard/create":
            return self._handle_wireguard_create()
        if path == "/admin-panel/wireguard/delete":
            return self._handle_wireguard_delete()
        if path == "/admin-panel/wireguard/renew":
            return self._handle_wireguard_renew()
        if path == "/admin-panel/wireguard/generate-config":
            return self._handle_wireguard_generate_config()
        if path == "/admin-panel/settings/domains":
            return self._handle_settings_domains()
        if path == "/admin-panel/settings/banner":
            return self._handle_settings_banner()
        if path == "/admin-panel/settings/autoreboot/enable":
            return self._handle_settings_autoreboot_enable()
        if path == "/admin-panel/settings/autoreboot/disable":
            return self._handle_settings_autoreboot_disable()
        if path == "/admin-panel/settings/ssh-engine":
            return self._handle_settings_ssh_engine()
        if path in SETTINGS_SIMPLE_ACTIONS:
            action, title = SETTINGS_SIMPLE_ACTIONS[path]
            return self._handle_settings_simple_action(action, title)
        for key in SETTINGS_TOGGLES:
            if path == f"/admin-panel/settings/{key}/enable":
                return self._handle_settings_toggle(key, "enable")
            if path == f"/admin-panel/settings/{key}/disable":
                return self._handle_settings_toggle(key, "disable")
        for key in SECURITY_TOGGLES:
            if path == f"/admin-panel/security/{key}/enable":
                return self._handle_security_toggle(key, "enable")
            if path == f"/admin-panel/security/{key}/disable":
                return self._handle_security_toggle(key, "disable")
            if key == "clean-expired" and path == f"/admin-panel/security/{key}/run":
                return self._handle_security_toggle(key, "run")
        if path == "/admin-panel/bot-api/admin-bot/connect":
            return self._handle_bot_api_admin_connect()
        if path == "/admin-panel/bot-api/admin-bot/disconnect":
            return self._handle_bot_api_admin_disconnect()
        if path == "/admin-panel/bot-api/user-bot/connect":
            return self._handle_bot_api_user_connect()
        if path == "/admin-panel/bot-api/user-bot/disconnect":
            return self._handle_bot_api_user_disconnect()
        if path == "/admin-panel/bot-api/user-bot/access/toggle":
            return self._handle_bot_api_access_toggle()
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

    # ---- WireGuard (Phase 3) ----
    def _handle_wireguard_page(self):
        if not self._current_session():
            return self._redirect("/admin-panel/login")
        self._send_html(render_shell_page("WireGuard", render_wireguard_page(), "/admin-panel/wireguard"))

    def _handle_wireguard_create(self):
        if not self._current_session():
            return self._redirect("/admin-panel/login")
        form = self._read_form_body()
        username = self._form_value(form, "username")
        days = self._form_value(form, "days")
        output = run_text(["bash", WG_ACTIONS_SCRIPT, "create", username, days])
        body = render_action_result("Create WireGuard Account", output, "/admin-panel/wireguard")
        self._send_html(render_shell_page("WireGuard", body, "/admin-panel/wireguard"))

    def _handle_wireguard_delete(self):
        if not self._current_session():
            return self._redirect("/admin-panel/login")
        form = self._read_form_body()
        username = self._form_value(form, "username")
        output = run_text(["bash", WG_ACTIONS_SCRIPT, "delete", username])
        body = render_action_result("Delete WireGuard Account", output, "/admin-panel/wireguard")
        self._send_html(render_shell_page("WireGuard", body, "/admin-panel/wireguard"))

    def _handle_wireguard_renew(self):
        if not self._current_session():
            return self._redirect("/admin-panel/login")
        form = self._read_form_body()
        username = self._form_value(form, "username")
        days = self._form_value(form, "days")
        output = run_text(["bash", WG_ACTIONS_SCRIPT, "renew", username, days])
        body = render_action_result("Renew WireGuard Account", output, "/admin-panel/wireguard")
        self._send_html(render_shell_page("WireGuard", body, "/admin-panel/wireguard"))

    def _handle_wireguard_generate_config(self):
        if not self._current_session():
            return self._redirect("/admin-panel/login")
        form = self._read_form_body()
        username = self._form_value(form, "username")
        output = run_text(["bash", GENERATE_WIREGUARD_CONFIG_SCRIPT, username])
        body = render_action_result("WireGuard Account Config", output, "/admin-panel/wireguard")
        self._send_html(render_shell_page("WireGuard", body, "/admin-panel/wireguard"))

    def _handle_wireguard_active(self):
        if not self._current_session():
            return self._redirect("/admin-panel/login")
        body = render_wireguard_active_page()
        self._send_html(render_shell_page("Check Active WireGuard Users", body, "/admin-panel/wireguard"))

    # ---- Settings (Phase 4) ----
    def _handle_settings_page(self):
        if not self._current_session():
            return self._redirect("/admin-panel/login")
        self._send_html(render_shell_page("Settings", render_settings_page(), "/admin-panel/settings"))

    def _handle_settings_domains(self):
        if not self._current_session():
            return self._redirect("/admin-panel/login")
        form = self._read_form_body()
        domain = self._form_value(form, "domain")
        ns_domain = self._form_value(form, "ns_domain")
        outputs = []
        if domain:
            outputs.append(run_text(["bash", SETTINGS_ACTIONS_SCRIPT, "set-domain", domain]))
        if ns_domain:
            outputs.append(run_text(["bash", SETTINGS_ACTIONS_SCRIPT, "set-ns-domain", ns_domain]))
        if not outputs:
            outputs.append("Nothing changed (both fields were blank).")
        body = render_action_result("Change Domains", "\n\n".join(outputs), "/admin-panel/settings")
        self._send_html(render_shell_page("Settings", body, "/admin-panel/settings"))

    def _handle_settings_banner(self):
        if not self._current_session():
            return self._redirect("/admin-panel/login")
        form = self._read_form_body()
        banner_text = self._form_value(form, "banner_text")
        if not banner_text.endswith("\n"):
            banner_text += "\n"
        output = run_text(["bash", SETTINGS_ACTIONS_SCRIPT, "set-banner"], input_text=banner_text)
        body = render_action_result("Change Banner", output, "/admin-panel/settings")
        self._send_html(render_shell_page("Settings", body, "/admin-panel/settings"))

    def _handle_settings_autoreboot_enable(self):
        if not self._current_session():
            return self._redirect("/admin-panel/login")
        form = self._read_form_body()
        time_val = self._form_value(form, "time", "04:00")
        output = run_text(["bash", SETTINGS_ACTIONS_SCRIPT, "autoreboot-enable", time_val])
        body = render_action_result("Auto Reboot", output, "/admin-panel/settings")
        self._send_html(render_shell_page("Settings", body, "/admin-panel/settings"))

    def _handle_settings_autoreboot_disable(self):
        if not self._current_session():
            return self._redirect("/admin-panel/login")
        output = run_text(["bash", SETTINGS_ACTIONS_SCRIPT, "autoreboot-disable"])
        body = render_action_result("Auto Reboot", output, "/admin-panel/settings")
        self._send_html(render_shell_page("Settings", body, "/admin-panel/settings"))

    def _handle_settings_simple_action(self, action, title):
        if not self._current_session():
            return self._redirect("/admin-panel/login")
        output = run_text(["bash", SETTINGS_ACTIONS_SCRIPT, action])
        body = render_action_result(title, output, "/admin-panel/settings")
        self._send_html(render_shell_page("Settings", body, "/admin-panel/settings"))

    def _handle_settings_toggle(self, key, action):
        if not self._current_session():
            return self._redirect("/admin-panel/login")
        info = SETTINGS_TOGGLES[key]
        script = os.path.join(INSTALL_DIR, "core", info["script"])
        output = run_text(["bash", script, action])
        body = render_action_result(info["label"], output, "/admin-panel/settings")
        self._send_html(render_shell_page("Settings", body, "/admin-panel/settings"))

    def _handle_settings_ssh_engine(self):
        if not self._current_session():
            return self._redirect("/admin-panel/login")
        form = self._read_form_body()
        mode = self._form_value(form, "mode", "both")
        if mode not in ("dropbear", "openssh", "both"):
            mode = "both"
        output = run_text(["bash", os.path.join(INSTALL_DIR, "core", "ssh-engine.sh"), mode])
        body = render_action_result("SSH Tunnel Engine", output, "/admin-panel/settings")
        self._send_html(render_shell_page("Settings", body, "/admin-panel/settings"))

    # ---- Security Mgt (Phase 5) ----
    def _handle_security_page(self):
        if not self._current_session():
            return self._redirect("/admin-panel/login")
        self._send_html(render_shell_page("Security Mgt", render_security_page(), "/admin-panel/security"))

    def _handle_security_toggle(self, key, action):
        if not self._current_session():
            return self._redirect("/admin-panel/login")
        info = SECURITY_TOGGLES[key]
        script = os.path.join(INSTALL_DIR, "core", info["script"])
        output = run_text(["bash", script, action])
        body = render_action_result(info["label"], output, "/admin-panel/security")
        self._send_html(render_shell_page("Security Mgt", body, "/admin-panel/security"))

    # ---- Bot & Api Setup (Phase 6) ----
    def _handle_bot_api_page(self):
        if not self._current_session():
            return self._redirect("/admin-panel/login")
        self._send_html(render_shell_page("Bot & Api Setup", render_bot_api_page(), "/admin-panel/bot-api"))

    def _handle_bot_api_admin_connect(self):
        if not self._current_session():
            return self._redirect("/admin-panel/login")
        form = self._read_form_body()
        token = self._form_value(form, "token")
        output = run_text(["bash", TELEGRAM_BOT_ACTIONS_SCRIPT, "admin-connect", token])
        body = render_action_result("Connect Admin Bot", output, "/admin-panel/bot-api")
        self._send_html(render_shell_page("Bot & Api Setup", body, "/admin-panel/bot-api"))

    def _handle_bot_api_admin_disconnect(self):
        if not self._current_session():
            return self._redirect("/admin-panel/login")
        output = run_text(["bash", TELEGRAM_BOT_ACTIONS_SCRIPT, "admin-disconnect"])
        body = render_action_result("Disconnect Admin Bot", output, "/admin-panel/bot-api")
        self._send_html(render_shell_page("Bot & Api Setup", body, "/admin-panel/bot-api"))

    def _handle_bot_api_user_connect(self):
        if not self._current_session():
            return self._redirect("/admin-panel/login")
        form = self._read_form_body()
        token = self._form_value(form, "token")
        output = run_text(["bash", TELEGRAM_BOT_ACTIONS_SCRIPT, "user-connect", token])
        body = render_action_result("Connect User Bot", output, "/admin-panel/bot-api")
        self._send_html(render_shell_page("Bot & Api Setup", body, "/admin-panel/bot-api"))

    def _handle_bot_api_user_disconnect(self):
        if not self._current_session():
            return self._redirect("/admin-panel/login")
        output = run_text(["bash", TELEGRAM_BOT_ACTIONS_SCRIPT, "user-disconnect"])
        body = render_action_result("Disconnect User Bot", output, "/admin-panel/bot-api")
        self._send_html(render_shell_page("Bot & Api Setup", body, "/admin-panel/bot-api"))

    def _handle_bot_api_access_toggle(self):
        if not self._current_session():
            return self._redirect("/admin-panel/login")
        form = self._read_form_body()
        key = self._form_value(form, "key")
        output = run_text(["bash", TELEGRAM_BOT_ACTIONS_SCRIPT, "user-access-toggle", key])
        body = render_action_result("Control Access", output, "/admin-panel/bot-api")
        self._send_html(render_shell_page("Bot & Api Setup", body, "/admin-panel/bot-api"))


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

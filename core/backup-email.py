#!/usr/bin/env python3
# VPN-Starter-Kit :: core/backup-email.py
# Emails a backup archive as an attachment via SMTP -- stdlib smtplib only,
# matching this project's zero-pip-dependency convention. Reads server
# creds from /etc/vpn-script/smtp-config.json (written by the Settings
# page / menu-settings.sh, never by this script).
#
# Usage: backup-email.py <to_address> <backup_file_path>
# Prints one JSON line {ok: bool, message: str} and exits 0/1 accordingly,
# so both the bash callers (backup.sh) and admin-panel.py can read the
# result the same way every other run_json()-style script already works.

import json
import os
import smtplib
import sys
from email.mime.application import MIMEApplication
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText

SMTP_CONFIG_FILE = "/etc/vpn-script/smtp-config.json"


def fail(message):
    print(json.dumps({"ok": False, "message": message}))
    sys.exit(1)


def main():
    if len(sys.argv) != 3:
        fail("Usage: backup-email.py <to_address> <backup_file_path>")
    to_address, file_path = sys.argv[1], sys.argv[2]

    if not os.path.isfile(file_path):
        fail(f"Backup file not found: {file_path}")

    try:
        with open(SMTP_CONFIG_FILE) as f:
            cfg = json.load(f)
    except (OSError, json.JSONDecodeError):
        fail(f"SMTP is not configured yet -- set it up in Settings first ({SMTP_CONFIG_FILE} missing/invalid).")

    host = cfg.get("host", "")
    port = cfg.get("port", 587)
    username = cfg.get("username", "")
    password = cfg.get("password", "")
    from_addr = cfg.get("from") or username
    use_tls = cfg.get("use_tls", True)

    if not host or not username or not password or not from_addr:
        fail("SMTP settings are incomplete -- host, username, password, and from-address are all required.")

    msg = MIMEMultipart()
    msg["From"] = from_addr
    msg["To"] = to_address
    msg["Subject"] = f"VPN-Starter-Kit backup -- {os.path.basename(file_path)}"
    msg.attach(MIMEText(
        "Attached: a VPN-Starter-Kit backup archive (VPN data only).\n"
        "Restore it from the admin panel's Backup page, or via:\n"
        "  backup.sh restore <filename>\n",
        "plain",
    ))

    with open(file_path, "rb") as f:
        part = MIMEApplication(f.read(), Name=os.path.basename(file_path))
    part["Content-Disposition"] = f'attachment; filename="{os.path.basename(file_path)}"'
    msg.attach(part)

    try:
        if use_tls and port == 465:
            server = smtplib.SMTP_SSL(host, port, timeout=30)
        else:
            server = smtplib.SMTP(host, port, timeout=30)
            if use_tls:
                server.starttls()
        with server:
            server.login(username, password)
            server.sendmail(from_addr, [to_address], msg.as_string())
    except Exception as exc:
        fail(f"Failed to send email: {exc}")

    print(json.dumps({"ok": True, "message": f"Backup emailed to {to_address}."}))


if __name__ == "__main__":
    main()

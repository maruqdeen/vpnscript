#!/usr/bin/env python3
# VPN-Starter-Kit :: core/ohp.py
# SSH-over-HTTP-Proxy (OHP) tunnel — for client apps (HTTP Injector, HTTP
# Custom, KPN Tunnel, etc.) in "HTTP Proxy" mode, which send an HTTP
# CONNECT-style request and expect a standard proxy "200 Connection
# Established" reply, not a WebSocket "101 Switching Protocols" (that's
# what core/ws.py answers with, on a different port, for WS-mode clients).
# Beyond that response line, this is the exact same trick ws.py uses:
# don't actually parse the client's request, just answer and bridge raw
# bytes to a local SSH/Dropbear port. Runs on its own dedicated public
# port, bypassing nginx entirely (same pattern as SlowDNS/HAProxy/SSLH/
# OpenVPN/WireGuard/Proxy — nginx only fronts the WS/gRPC/Xray traffic
# that benefits from path-based routing on a shared port).

import socket
import threading
import select
import sys

LISTEN_HOST = "0.0.0.0"
LISTEN_PORT = 8181            # public port OHP clients connect to
TARGET_HOST = "127.0.0.1"    # local SSH daemon

# Same switch Settings > SSH Tunnel Engine writes for ws.py — Dropbear
# 143 or OpenSSH 22, whichever engine is currently selected.
TARGET_PORT_FILE = "/etc/vpn-script/ssh-target-port"


def _read_target_port():
    try:
        with open(TARGET_PORT_FILE) as f:
            return int(f.read().strip())
    except (OSError, ValueError):
        return 143  # Dropbear default


TARGET_PORT = _read_target_port()
BUFFER = 4096

# Standard HTTP proxy CONNECT tunnel-established response.
RESPONSE = "HTTP/1.1 200 Connection Established\r\n\r\n"


def pipe(src, dst):
    """Shovel bytes one direction until either side closes."""
    try:
        while True:
            r, _, _ = select.select([src], [], [], 60)
            if not r:
                continue
            data = src.recv(BUFFER)
            if not data:
                break
            dst.sendall(data)
    except (OSError, ConnectionError):
        pass
    finally:
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def handle(client):
    try:
        # Read (and discard) the client's CONNECT request.
        client.settimeout(5)
        try:
            client.recv(BUFFER)
        except socket.timeout:
            pass
        client.settimeout(None)

        # Complete the "tunnel established" handshake.
        client.sendall(RESPONSE.encode())

        # Open the tunnel to local SSH.
        target = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        target.connect((TARGET_HOST, TARGET_PORT))

        # Bridge both directions.
        t1 = threading.Thread(target=pipe, args=(client, target), daemon=True)
        t2 = threading.Thread(target=pipe, args=(target, client), daemon=True)
        t1.start()
        t2.start()
        t1.join()
        t2.join()
    except Exception as e:
        sys.stderr.write(f"handle error: {e}\n")
    finally:
        client.close()


def main():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((LISTEN_HOST, LISTEN_PORT))
    server.listen(200)
    sys.stdout.write(f"SSH-OHP proxy listening on {LISTEN_HOST}:{LISTEN_PORT} "
                     f"-> {TARGET_HOST}:{TARGET_PORT}\n")
    sys.stdout.flush()

    while True:
        client, _ = server.accept()
        threading.Thread(target=handle, args=(client,), daemon=True).start()


if __name__ == "__main__":
    main()

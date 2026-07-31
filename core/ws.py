#!/usr/bin/env python3
# VPN-Starter-Kit :: core/ws.py
# Minimal SSH-over-WebSocket proxy for HTTP Injector / HTTP Custom style tunnels.
# Listens on a public port, answers the HTTP upgrade with 101, then bridges
# raw bytes to a local SSH/Dropbear port.

import socket
import threading
import select
import sys

LISTEN_HOST = "0.0.0.0"
LISTEN_PORT = 8880            # public port clients connect to
TARGET_HOST = "127.0.0.1"    # local SSH daemon

# Which local sshd to bridge into (Dropbear 143 or OpenSSH 22) is switchable
# from Settings > SSH Tunnel Engine (core/ssh-engine.sh writes this file).
TARGET_PORT_FILE = "/etc/vpn-script/ssh-target-port"


def _read_target_port():
    try:
        with open(TARGET_PORT_FILE) as f:
            return int(f.read().strip())
    except (OSError, ValueError):
        return 143  # Dropbear default


TARGET_PORT = _read_target_port()
BUFFER = 4096

# Backend (Dropbear/OpenSSH) dial timeout -- without this, a slow/stuck
# backend hangs the handler thread for that one connection indefinitely.
CONNECT_TIMEOUT = 5

# Concurrency cap: every connection spawns 3 native OS threads (this
# accept-thread's handle() call, plus 2 more inside pipe()) with no pool
# and no other limit besides the listen() backlog below -- under a
# reconnect storm that's unbounded thread creation. A BoundedSemaphore
# caps how many connections are actively being bridged at once; anything
# past that is closed immediately (cheap: it never reaches the backend
# dial or spawns the 2 pipe threads) instead of piling up.
MAX_CONNECTIONS = 1000
_conn_semaphore = threading.BoundedSemaphore(MAX_CONNECTIONS)

# The banner sent back to the client to complete the "upgrade".
RESPONSE = (
    "HTTP/1.1 101 Switching Protocols\r\n"
    "Upgrade: websocket\r\n"
    "Connection: Upgrade\r\n\r\n"
)


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
    if not _conn_semaphore.acquire(blocking=False):
        # At capacity -- close immediately rather than dial the backend
        # and spawn 2 more threads on top of an already-saturated pool.
        try:
            client.close()
        except OSError:
            pass
        return
    try:
        # Read (and discard) the client's HTTP request payload.
        client.settimeout(5)
        try:
            client.recv(BUFFER)
        except socket.timeout:
            pass
        client.settimeout(None)

        # Complete the handshake.
        client.sendall(RESPONSE.encode())

        # Open the tunnel to local SSH.
        target = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        target.settimeout(CONNECT_TIMEOUT)
        try:
            target.connect((TARGET_HOST, TARGET_PORT))
        finally:
            target.settimeout(None)  # back to blocking for the actual tunnel I/O

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
        _conn_semaphore.release()


def main():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((LISTEN_HOST, LISTEN_PORT))
    server.listen(200)
    sys.stdout.write(f"SSH-WS proxy listening on {LISTEN_HOST}:{LISTEN_PORT} "
                     f"-> {TARGET_HOST}:{TARGET_PORT}\n")
    sys.stdout.flush()

    while True:
        client, _ = server.accept()
        threading.Thread(target=handle, args=(client,), daemon=True).start()


if __name__ == "__main__":
    main()

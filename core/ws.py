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
TARGET_PORT = 143            # Dropbear will listen here (set in File... Dropbear stage)
BUFFER = 4096

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
    sys.stdout.write(f"SSH-WS proxy listening on {LISTEN_HOST}:{LISTEN_PORT} "
                     f"-> {TARGET_HOST}:{TARGET_PORT}\n")
    sys.stdout.flush()

    while True:
        client, _ = server.accept()
        threading.Thread(target=handle, args=(client,), daemon=True).start()


if __name__ == "__main__":
    main()

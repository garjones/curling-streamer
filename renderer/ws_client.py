"""A minimal RFC 6455 WebSocket *client*, standard library only.

The renderer must hold one WebSocket to the club (polling is banned — see
README "No polling") and must not grow dependencies, and Python's standard
library has no WebSocket client. This is the smallest one that does the job:
text frames, client-side masking, ping/pong, close, TLS via ssl. It is not a
general-purpose library — no extensions, no binary messages, no fragmented
sends — and it doesn't need to be.
"""

import base64
import hashlib
import os
import socket
import ssl
import struct
import urllib.parse

_WS_MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class ConnectionClosed(Exception):
    """The server closed the connection (or the TCP link died)."""


class WebSocket:
    def __init__(self, url, timeout=15):
        u = urllib.parse.urlsplit(url)
        if u.scheme not in ("ws", "wss"):
            raise ValueError(f"not a WebSocket URL: {url}")
        host = u.hostname
        port = u.port or (443 if u.scheme == "wss" else 80)
        path = (u.path or "/") + (f"?{u.query}" if u.query else "")

        self.sock = socket.create_connection((host, port), timeout=timeout)
        if u.scheme == "wss":
            ctx = ssl.create_default_context()
            self.sock = ctx.wrap_socket(self.sock, server_hostname=host)

        key = base64.b64encode(os.urandom(16)).decode()
        hosthdr = host if port in (80, 443) else f"{host}:{port}"
        self.sock.sendall(
            (
                f"GET {path} HTTP/1.1\r\n"
                f"Host: {hosthdr}\r\n"
                "Upgrade: websocket\r\n"
                "Connection: Upgrade\r\n"
                f"Sec-WebSocket-Key: {key}\r\n"
                "Sec-WebSocket-Version: 13\r\n"
                "\r\n"
            ).encode()
        )

        # Read the handshake response headers (up to the blank line).
        raw = b""
        while b"\r\n\r\n" not in raw:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionClosed("connection closed during handshake")
            raw = raw + chunk
            if len(raw) > 65536:
                raise ConnectionClosed("oversized handshake response")
        head, self._buf = raw.split(b"\r\n\r\n", 1)
        lines = head.decode("latin-1").split("\r\n")
        if " 101" not in lines[0]:
            raise ConnectionClosed(f"handshake refused: {lines[0]}")
        accept = None
        for line in lines[1:]:
            if line.lower().startswith("sec-websocket-accept:"):
                accept = line.split(":", 1)[1].strip()
        expect = base64.b64encode(
            hashlib.sha1((key + _WS_MAGIC).encode()).digest()
        ).decode()
        if accept != expect:
            raise ConnectionClosed("bad Sec-WebSocket-Accept")

    # ------------------------------------------------------------- sending
    def _send_frame(self, opcode, payload):
        mask = os.urandom(4)
        n = len(payload)
        head = bytes([0x80 | opcode])
        if n < 126:
            head += bytes([0x80 | n])
        elif n < 65536:
            head += bytes([0x80 | 126]) + struct.pack(">H", n)
        else:
            head += bytes([0x80 | 127]) + struct.pack(">Q", n)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(head + mask + masked)

    def send_text(self, text):
        self._send_frame(0x1, text.encode("utf-8"))

    # ------------------------------------------------------------ receiving
    def _read_exact(self, n):
        while len(self._buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionClosed("connection closed")
            self._buf = self._buf + chunk
        out, self._buf = self._buf[:n], self._buf[n:]
        return out

    def recv(self, timeout=None):
        """Return the next complete text message, or None on timeout.
        Control frames (ping/pong/close) are handled internally."""
        self.sock.settimeout(timeout)
        message = b""
        try:
            while True:
                b1, b2 = self._read_exact(2)
                fin, opcode = b1 & 0x80, b1 & 0x0F
                n = b2 & 0x7F
                if n == 126:
                    (n,) = struct.unpack(">H", self._read_exact(2))
                elif n == 127:
                    (n,) = struct.unpack(">Q", self._read_exact(8))
                if b2 & 0x80:  # masked server frame: protocol violation
                    self._read_exact(4 + n)
                    raise ConnectionClosed("server sent a masked frame")
                payload = self._read_exact(n)

                if opcode == 0x8:  # close
                    try:
                        self._send_frame(0x8, payload[:2])
                    except OSError:
                        pass
                    raise ConnectionClosed("server closed the connection")
                if opcode == 0x9:  # ping -> pong
                    self._send_frame(0xA, payload)
                    continue
                if opcode == 0xA:  # pong: ignore
                    continue
                if opcode in (0x1, 0x2, 0x0):
                    message = message + payload
                    if fin:
                        if opcode == 0x2:
                            continue  # binary: not part of our protocol; skip
                        return message.decode("utf-8", errors="replace")
                    continue  # fragmented: keep accumulating
                # unknown opcode: skip it
        except (socket.timeout, TimeoutError):
            return None

    def close(self):
        try:
            self._send_frame(0x8, struct.pack(">H", 1000))
        except OSError:
            pass
        try:
            self.sock.close()
        except OSError:
            pass

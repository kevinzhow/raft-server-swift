"""Minimal stdlib HTTP and RFC 6455 WebSocket clients for scripted acceptance.

No third-party packages. The WebSocket client implements just enough of RFC
6455 for the Socket.IO v4 transport used by the server: a client handshake,
masked text frames, ping/pong, close and buffered reads.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import socket
import ssl
import struct
import time
import urllib.error
import urllib.parse
import urllib.request


class HTTPResult:
    __slots__ = ("status", "headers", "body")

    def __init__(self, status: int, headers: dict[str, str], body: bytes):
        self.status = status
        self.headers = headers
        self.body = body

    @property
    def text(self) -> str:
        return self.body.decode("utf-8", "replace")

    def json(self):
        return json.loads(self.body.decode("utf-8"))

    def __repr__(self) -> str:  # pragma: no cover - diagnostics only
        return f"HTTPResult(status={self.status}, bytes={len(self.body)})"


class HTTPClient:
    def __init__(self, base_url: str, timeout: float = 30.0):
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout

    def request(
        self,
        method: str,
        path: str,
        body: bytes | str | dict | None = None,
        headers: dict[str, str] | None = None,
        raw: bool = False,
        content_type: str = "application/json",
    ) -> HTTPResult:
        url = path if path.startswith("http") else self.base_url + path
        data: bytes | None
        if body is None:
            data = None
        elif isinstance(body, bytes):
            data = body
        elif isinstance(body, str):
            data = body.encode()
        else:
            data = json.dumps(body).encode()
        request_headers = {"Accept": "application/json", "User-Agent": "raft-scripted-acceptance/1"}
        if data is not None:
            request_headers["Content-Type"] = content_type
        if headers:
            request_headers.update(headers)
        request = urllib.request.Request(url, data=data, headers=request_headers, method=method.upper())
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                payload = response.read()
                return HTTPResult(response.status, dict(response.headers), payload)
        except urllib.error.HTTPError as error:
            payload = error.read()
            return HTTPResult(error.code, dict(error.headers or {}), payload)
        except urllib.error.URLError as error:
            raise ConnectionError(f"{method} {url}: {error.reason}") from None


def multipart(fields: list[tuple[str, bytes, str | None]]) -> tuple[bytes, str]:
    """Build a multipart/form-data body.

    Each field is ``(name, value, filename)``. A filename turns the part into a
    file upload.
    """
    boundary = "----raft-acceptance-" + base64.urlsafe_b64encode(os.urandom(12)).decode().rstrip("=")
    chunks: list[bytes] = []
    for name, value, filename in fields:
        chunks.append(f"--{boundary}\r\n".encode())
        if filename is None:
            chunks.append(f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode())
        else:
            chunks.append(
                f'Content-Disposition: form-data; name="{name}"; filename="{filename}"\r\n'.encode()
            )
            chunks.append(b"Content-Type: application/octet-stream\r\n\r\n")
        chunks.append(value)
        chunks.append(b"\r\n")
    chunks.append(f"--{boundary}--\r\n".encode())
    return b"".join(chunks), f"multipart/form-data; boundary={boundary}"


class WebSocketClient:
    """Single-connection RFC 6455 text client with Engine.IO/Socket.IO helpers."""

    def __init__(self, url: str, timeout: float = 30.0):
        parsed = urllib.parse.urlparse(url)
        if parsed.scheme not in ("ws", "wss"):
            raise ValueError(f"not a websocket URL: {url}")
        self.url = url
        self.timeout = timeout
        self.buffer = b""
        port = parsed.port or (443 if parsed.scheme == "wss" else 80)
        raw = socket.create_connection((parsed.hostname or "127.0.0.1", port), timeout=timeout)
        if parsed.scheme == "wss":
            context = ssl.create_default_context()
            raw = context.wrap_socket(raw, server_hostname=parsed.hostname)
        self.socket = raw
        self._handshake(parsed, port)

    def _handshake(self, parsed: urllib.parse.ParseResult, port: int) -> None:
        key = base64.b64encode(os.urandom(16)).decode()
        path = parsed.path or "/"
        if parsed.query:
            path += "?" + parsed.query
        host = parsed.hostname or "127.0.0.1"
        if (parsed.scheme == "ws" and port != 80) or (parsed.scheme == "wss" and port != 443):
            host = f"{host}:{port}"
        request = (
            f"GET {path} HTTP/1.1\r\n"
            f"Host: {host}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            "\r\n"
        )
        self.socket.sendall(request.encode())
        deadline = time.monotonic() + self.timeout
        while b"\r\n\r\n" not in self.buffer:
            if time.monotonic() > deadline:
                raise TimeoutError("websocket handshake timed out")
            chunk = self.socket.recv(4096)
            if not chunk:
                raise ConnectionError("websocket handshake closed by peer")
            self.buffer += chunk
        head, _, self.buffer = self.buffer.partition(b"\r\n\r\n")
        lines = head.decode("latin-1").split("\r\n")
        if not lines or " 101 " not in lines[0] + " ":
            raise ConnectionError(f"websocket upgrade refused: {lines[0] if lines else ''}")
        expected = base64.b64encode(
            hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()
        ).decode()
        for line in lines[1:]:
            if line.lower().startswith("sec-websocket-accept:"):
                if line.split(":", 1)[1].strip() != expected:
                    raise ConnectionError("websocket accept key mismatch")

    # -- framing ---------------------------------------------------------
    def _read_exact(self, count: int) -> bytes:
        while len(self.buffer) < count:
            chunk = self.socket.recv(65536)
            if not chunk:
                raise ConnectionError("websocket closed")
            self.buffer += chunk
        data, self.buffer = self.buffer[:count], self.buffer[count:]
        return data

    def send_text(self, text: str) -> None:
        payload = text.encode()
        header = bytearray([0x81])
        length = len(payload)
        if length < 126:
            header.append(0x80 | length)
        elif length < 65536:
            header.append(0x80 | 126)
            header += struct.pack("!H", length)
        else:
            header.append(0x80 | 127)
            header += struct.pack("!Q", length)
        mask = os.urandom(4)
        masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        self.socket.sendall(bytes(header) + mask + masked)

    def send_pong(self, payload: bytes) -> None:
        header = bytearray([0x8A])
        if len(payload) < 126:
            header.append(0x80 | len(payload))
        else:  # pragma: no cover - server pings are tiny
            header.append(0x80 | 126)
            header += struct.pack("!H", len(payload))
        mask = os.urandom(4)
        self.socket.sendall(bytes(header) + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def recv_text(self, timeout: float | None = None) -> str | None:
        """Return the next text message, or None on a clean close."""
        old_timeout = self.socket.gettimeout()
        self.socket.settimeout(self.timeout if timeout is None else timeout)
        try:
            while True:
                first = self._read_exact(2)
                fin = first[0] & 0x80
                opcode = first[0] & 0x0F
                masked = first[1] & 0x80
                length = first[1] & 0x7F
                if length == 126:
                    length = struct.unpack("!H", self._read_exact(2))[0]
                elif length == 127:
                    length = struct.unpack("!Q", self._read_exact(8))[0]
                mask = self._read_exact(4) if masked else None
                payload = self._read_exact(length)
                if mask:
                    payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
                if opcode == 0x8:
                    return None
                if opcode == 0x9:
                    self.send_pong(payload)
                    continue
                if opcode == 0xA:
                    continue
                if opcode in (0x1, 0x2):
                    if not fin:
                        raise ConnectionError("fragmented websocket frame is not supported")
                    return payload.decode("utf-8", "replace")
        finally:
            self.socket.settimeout(old_timeout)

    def close(self) -> None:
        try:
            self.socket.close()
        except OSError:
            pass

    # -- Socket.IO -------------------------------------------------------
    def connect_socketio(self, token: str, server_id: str, timeout: float = 20.0) -> dict:
        """Complete the Engine.IO open and Socket.IO connect handshake.

        Returns the parsed connect payload (``{"sid": ...}``) once the server
        acknowledges, after consuming the Engine.IO open frame.
        """
        opened = self.recv_text(timeout)
        if opened is None or not opened.startswith("0"):
            raise ConnectionError(f"expected an Engine.IO open frame, got {opened!r}")
        self.send_text("40" + json.dumps({"token": token, "serverId": server_id}, separators=(",", ":")))
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            frame = self.recv_text(max(0.2, deadline - time.monotonic()))
            if frame is None:
                raise ConnectionError("socket closed during connect")
            if frame == "2":
                self.send_text("3")
                continue
            if frame.startswith("44"):
                raise PermissionError(f"socket connect refused: {frame}")
            if frame.startswith("40"):
                try:
                    return json.loads(frame[2:] or "{}")
                except json.JSONDecodeError:
                    return {}
        raise TimeoutError("socket.io connect acknowledgement timed out")

    def wait_event(self, event: str, timeout: float = 30.0, predicate=None) -> dict:
        """Wait for ``event`` (a Socket.IO ``42[...]`` frame) and return its data."""
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"timed out waiting for socket event {event!r}")
            frame = self.recv_text(min(remaining, 5.0))
            if frame is None:
                raise ConnectionError(f"socket closed while waiting for {event!r}")
            if frame == "2":
                self.send_text("3")
                continue
            if not frame.startswith("42"):
                continue
            try:
                payload = json.loads(frame[2:])
            except json.JSONDecodeError:
                continue
            if not isinstance(payload, list) or not payload or payload[0] != event:
                continue
            data = payload[1] if len(payload) > 1 else {}
            if predicate is None or predicate(data):
                return data

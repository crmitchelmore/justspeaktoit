#!/usr/bin/env python3
"""Bounded, credential-free RFC6455 echo peer for the native Swift runtime probe.

Only binds IPv4 loopback. No third-party packages or external connections.
The slow route deliberately applies socket backpressure; it is not a benchmark.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import socket
import socketserver
import struct
import threading
import time


MAX_PAYLOAD = 4 * 1024 * 1024
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
LOG_LOCK = threading.Lock()


def log(event, **fields):
    with LOG_LOCK:
        print(json.dumps({"event": event, **fields}, sort_keys=True), flush=True)


class ProbeHandler(socketserver.BaseRequestHandler):
    def handle(self):
        if not self.server.slots.acquire(blocking=False):
            return
        try:
            self.request.settimeout(10)
            self.request.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 16 * 1024)
            self.request.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            self.pending = bytearray()
            self.slow = False
            self.upgraded = False
            self.run_connection()
        except (ConnectionError, TimeoutError, OSError) as error:
            log("connection-ended", reason=type(error).__name__)
        except ValueError as error:
            log("protocol-error", reason=str(error))
            if not self.upgraded:
                try:
                    self.request.sendall(
                        b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    )
                except OSError:
                    pass
        finally:
            self.server.slots.release()

    def read_exact(self, count):
        result = bytearray()
        if self.pending:
            take = min(count, len(self.pending))
            result.extend(self.pending[:take])
            del self.pending[:take]
        while len(result) < count:
            block = self.request.recv(min(count - len(result), 4096))
            if not block:
                raise ConnectionError("peer disconnected")
            result.extend(block)
            if self.slow and count > 4096:
                time.sleep(0.002)
        return result

    def handshake(self):
        while b"\r\n\r\n" not in self.pending:
            block = self.request.recv(2048)
            if not block:
                raise ConnectionError("peer disconnected before handshake")
            self.pending.extend(block)
            if len(self.pending) > 16 * 1024:
                raise ValueError("handshake exceeded bound")
        header, remainder = self.pending.split(b"\r\n\r\n", 1)
        self.pending = bytearray(remainder)
        lines = header.decode("ascii").split("\r\n")
        method, path, version = lines[0].split(" ")
        headers = {}
        for line in lines[1:]:
            name, value = line.split(":", 1)
            name, value = name.lower(), value.strip()
            headers[name] = headers[name] + ", " + value if name in headers else value
        # Only protocol fields and the synthetic marker are recorded. No
        # credentials, arbitrary request headers or WebSocket keys enter logs.
        log("handshake-request", method=method, path=path, version=version,
            connection=headers.get("connection"), upgrade=headers.get("upgrade"),
            websocketVersion=headers.get("sec-websocket-version"),
            subprotocol=headers.get("sec-websocket-protocol"),
            markerVerified=headers.get("x-jsti-probe") == "local-only")
        connection_tokens = {value.strip().lower() for value in headers.get("connection", "").split(",")}
        if (method != "GET" or version != "HTTP/1.1"
                or headers.get("upgrade", "").lower() != "websocket"
                or "upgrade" not in connection_tokens
                or headers.get("sec-websocket-version") != "13"
                or headers.get("x-jsti-probe") != "local-only"
                or headers.get("sec-websocket-protocol") != "jsti-probe"):
            raise ValueError("unexpected handshake")
        key = headers.get("sec-websocket-key", "")
        if len(base64.b64decode(key, validate=True)) != 16:
            raise ValueError("invalid handshake key")
        if path not in ("/echo", "/slow", "/hold", "/abrupt", "/delay"):
            raise ValueError("unknown route")
        if path == "/delay":
            time.sleep(1)
        accept = base64.b64encode(hashlib.sha1((key + GUID).encode("ascii")).digest()).decode("ascii")
        response = (
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            f"Sec-WebSocket-Accept: {accept}\r\nSec-WebSocket-Protocol: jsti-probe\r\n\r\n"
        )
        self.request.sendall(response.encode("ascii"))
        self.upgraded = True
        log("handshake", path=path, headerVerified=True)
        return path

    def read_frame(self):
        first, second = self.read_exact(2)
        if first & 0x70 or not second & 0x80:
            raise ValueError("unsupported flags or unmasked client frame")
        final, opcode, length = bool(first & 0x80), first & 0x0F, second & 0x7F
        if length == 126:
            length = struct.unpack("!H", self.read_exact(2))[0]
        elif length == 127:
            length = struct.unpack("!Q", self.read_exact(8))[0]
        if length > MAX_PAYLOAD or (opcode >= 8 and (not final or length > 125)):
            raise ValueError("frame exceeded bound")
        mask = self.read_exact(4)
        payload = self.read_exact(length)
        for index in range(length):
            payload[index] ^= mask[index % 4]
        return final, opcode, payload

    def send_frame(self, opcode, payload):
        length = len(payload)
        if length < 126:
            header = bytes([0x80 | opcode, length])
        elif length <= 65535:
            header = bytes([0x80 | opcode, 126]) + struct.pack("!H", length)
        else:
            header = bytes([0x80 | opcode, 127]) + struct.pack("!Q", length)
        self.request.sendall(header)
        self.request.sendall(payload)

    def run_connection(self):
        path = self.handshake()
        self.slow = path == "/slow"
        if self.slow:
            time.sleep(0.25)
        message = bytearray()
        message_opcode = None
        message_count = 0
        while message_count < 64:
            final, opcode, payload = self.read_frame()
            if opcode == 8:
                self.send_frame(8, payload)
                log("client-close", path=path)
                return
            if opcode == 9:
                self.send_frame(10, payload)
                continue
            if opcode == 10:
                continue
            if opcode in (1, 2) and message_opcode is None:
                message_opcode = opcode
            elif opcode != 0 or message_opcode is None:
                raise ValueError("invalid continuation")
            if len(message) + len(payload) > MAX_PAYLOAD:
                raise ValueError("message exceeded bound")
            message.extend(payload)
            if not final:
                continue
            message_count += 1
            log("message", path=path, number=message_count, opcode=message_opcode,
                bytes=len(message), sha256=hashlib.sha256(message).hexdigest())
            if path == "/abrupt":
                return
            if message_opcode == 1 and message == b"server-close":
                self.send_frame(8, struct.pack("!H", 1000) + b"probe-complete")
                log("server-close", path=path)
                _, reply_opcode, _ = self.read_frame()
                if reply_opcode != 8:
                    raise ValueError("expected close acknowledgement")
                log("close-acknowledged", path=path)
                return
            if path != "/hold":
                self.send_frame(message_opcode, message)
            message.clear()
            message_opcode = None
        raise ValueError("message count exceeded bound")


class ProbeServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    daemon_threads = True
    allow_reuse_address = False
    slots = threading.BoundedSemaphore(8)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ready-file", type=Path, required=True)
    parser.add_argument("--max-seconds", type=int, default=120)
    arguments = parser.parse_args()
    if not 1 <= arguments.max_seconds <= 600:
        parser.error("max-seconds must be between 1 and 600")
    with ProbeServer(("127.0.0.1", 0), ProbeHandler) as server:
        ready = {"host": "127.0.0.1", "port": server.server_address[1], "maximumPayloadBytes": MAX_PAYLOAD}
        temporary = arguments.ready_file.with_suffix(".tmp")
        temporary.write_text(json.dumps(ready), encoding="utf-8")
        temporary.replace(arguments.ready_file)
        timer = threading.Timer(arguments.max_seconds, server.shutdown)
        timer.daemon = True
        timer.start()
        log("ready", **ready)
        try:
            server.serve_forever(poll_interval=0.1)
        finally:
            timer.cancel()
            log("stopped")


if __name__ == "__main__":
    main()

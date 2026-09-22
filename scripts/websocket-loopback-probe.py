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

# Cartesia Ink-2 automatic-turns peer for CartesiaWinHTTPRuntimeTests. The route,
# query and headers are exactly what the shared Swift client builds; only the
# origin is redirected here. The key is synthetic and never logged.
CARTESIA_ROUTE = "/stt/turns/websocket"
CARTESIA_QUERY = "model=ink-2&encoding=pcm_s16le&sample_rate=16000&cartesia_version=2026-03-01"
CARTESIA_AUTHORIZATION = "Bearer loopback-synthetic-key"
CARTESIA_VERSION = "2026-03-01"
CARTESIA_SCENARIOS = ("complete", "failure", "incomplete", "hold", "abrupt", "abnormal")
CARTESIA_FRAMES = 10
CARTESIA_FRAME_BYTES = 3200
# (update, end) per turn. The second turn carries its own leading space, as
# Cartesia turns are concatenated without adding whitespace.
CARTESIA_TURNS = (("Grüße aus", "Grüße aus Zürich — 世界"), (" naïve", " naïve café 👩🏽‍💻"))


def cartesia_frame(index):
    """100 ms of 16 kHz PCM16 mono, generated identically by the Swift test."""
    return bytes(((index * 7 + offset * 13) & 0xFF) for offset in range(CARTESIA_FRAME_BYTES))


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
        route, _, query = path.partition("?")
        headers = {}
        for line in lines[1:]:
            name, value = line.split(":", 1)
            name, value = name.lower(), value.strip()
            headers[name] = headers[name] + ", " + value if name in headers else value
        # Only protocol fields and the synthetic marker are recorded. No
        # credentials, arbitrary request headers or WebSocket keys enter logs.
        log("handshake-request", method=method, path=route, version=version,
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
        if route == CARTESIA_ROUTE:
            self.verify_cartesia(query, headers)
        elif query or route not in ("/echo", "/slow", "/hold", "/abrupt", "/delay", "/fragment", "/oversize"):
            raise ValueError("unknown route")
        if route == "/delay":
            time.sleep(1)
        accept = base64.b64encode(hashlib.sha1((key + GUID).encode("ascii")).digest()).decode("ascii")
        response = (
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            f"Sec-WebSocket-Accept: {accept}\r\nSec-WebSocket-Protocol: jsti-probe\r\n\r\n"
        )
        self.request.sendall(response.encode("ascii"))
        self.upgraded = True
        log("handshake", path=route, headerVerified=True)
        return route

    def verify_cartesia(self, query, headers):
        """The exact request the shared client builds: route, query, bearer and version."""
        scenario = headers.get("x-jsti-cartesia-scenario", "")
        checks = {
            "queryVerified": query == CARTESIA_QUERY,
            "authorizationVerified": headers.get("authorization") == CARTESIA_AUTHORIZATION,
            "versionVerified": headers.get("cartesia-version") == CARTESIA_VERSION,
            "scenarioVerified": scenario in CARTESIA_SCENARIOS,
        }
        log("cartesia-handshake", scenario=scenario if checks["scenarioVerified"] else None, **checks)
        if not all(checks.values()):
            raise ValueError("unexpected Cartesia handshake")
        self.cartesia_scenario = scenario

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

    def send_frame(self, opcode, payload, final=True):
        length = len(payload)
        flags = (0x80 if final else 0) | opcode
        if length < 126:
            header = bytes([flags, length])
        elif length <= 65535:
            header = bytes([flags, 126]) + struct.pack("!H", length)
        else:
            header = bytes([flags, 127]) + struct.pack("!Q", length)
        self.request.sendall(header)
        self.request.sendall(payload)

    def run_connection(self):
        path = self.handshake()
        if path == CARTESIA_ROUTE:
            self.run_cartesia()
            return
        self.slow = path == "/slow"
        if self.slow:
            time.sleep(0.25)
        message = bytearray()
        message_opcode = None
        message_count = 0
        awaiting_pong = False
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
                if awaiting_pong:
                    if payload != b"server-probe":
                        raise ValueError("server ping payload not preserved")
                    awaiting_pong = False
                    self.send_frame(1, b"server-pong-verified")
                    log("server-pong-verified", path=path)
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
            if path == "/oversize":
                self.send_frame(2, bytes(MAX_PAYLOAD), final=False)
                self.send_frame(0, b"x")
                return
            if message_opcode == 1 and message == b"server-ping":
                awaiting_pong = True
                self.send_frame(9, b"server-probe")
                message.clear()
                message_opcode = None
                continue
            if message_opcode == 1 and message == b"server-close":
                self.send_frame(8, struct.pack("!H", 1000) + b"probe-complete")
                log("server-close", path=path)
                _, reply_opcode, _ = self.read_frame()
                if reply_opcode != 8:
                    raise ValueError("expected close acknowledgement")
                log("close-acknowledged", path=path)
                return
            if path == "/fragment":
                # Split through a possible UTF-8 scalar and require complete
                # message assembly, independently of TCP receive chunking.
                split = min(2, len(message))
                self.send_frame(message_opcode, message[:split], final=False)
                self.send_frame(0, message[split:])
            elif path != "/hold":
                self.send_frame(message_opcode, message)
            message.clear()
            message_opcode = None
        raise ValueError("message count exceeded bound")

    def read_message(self):
        """One complete data message as (opcode, payload); (8, payload) is a close."""
        message = bytearray()
        message_opcode = None
        while True:
            final, opcode, payload = self.read_frame()
            if opcode == 8:
                return 8, bytes(payload)
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
            if final:
                return message_opcode, bytes(message)

    def send_json(self, event):
        """One text message, split inside a multi-byte UTF-8 scalar when it has
        one, so the client must assemble the message before decoding it."""
        payload = json.dumps({**event, "request_id": "loopback"}, ensure_ascii=False,
                             separators=(",", ":")).encode("utf-8")
        continuation = (index for index, byte in enumerate(payload) if (byte & 0xC0) == 0x80)
        split = max(1, min(next(continuation, len(payload) // 2), len(payload) - 1))
        self.send_frame(1, payload[:split], final=False)
        self.send_frame(0, payload[split:])

    def send_turn(self, update, end):
        self.send_json({"type": "turn.start"})
        self.send_json({"type": "turn.update", "transcript": update})
        self.send_json({"type": "turn.end", "transcript": end})

    def close_cartesia(self, code, reason):
        """Ends the stream from the server side, as Cartesia does after `close`."""
        try:
            self.send_frame(8, struct.pack("!H", code) + reason)
            log("cartesia-server-close", code=code)
            opcode, _ = self.read_message()
        except (ConnectionError, OSError):
            opcode = None
        log("cartesia-closed", acknowledged=opcode == 8)

    def reject_cartesia(self, reason):
        log("cartesia-protocol-violation", reason=reason)
        self.send_json({"type": "error", "status_code": 400, "title": "Loopback protocol violation",
                        "message": reason, "error_code": "loopback_protocol"})
        self.close_cartesia(1008, b"protocol-violation")

    def run_cartesia(self):
        """Requires the exact 100 ms PCM frames in order, then the close command,
        then answers as the scenario asks. Any deviation is reported to the client
        as a Cartesia error frame, which fails the Swift test visibly."""
        scenario = self.cartesia_scenario
        self.send_json({"type": "connected"})
        digest = hashlib.sha256()
        for index in range(CARTESIA_FRAMES):
            opcode, payload = self.read_message()
            if opcode != 2 or payload != cartesia_frame(index):
                return self.reject_cartesia(f"PCM frame {index} was not the exact 100 ms frame")
            digest.update(payload)
            if scenario == "complete" and index == CARTESIA_FRAMES // 2 - 1:
                # A turn that ends while audio is still streaming.
                self.send_turn(*CARTESIA_TURNS[0])
        opcode, payload = self.read_message()
        if opcode != 1 or payload != b'{"type":"close"}':
            return self.reject_cartesia("expected the close command after every audio frame")
        log("cartesia-close-command", scenario=scenario, frames=CARTESIA_FRAMES,
            bytes=CARTESIA_FRAMES * CARTESIA_FRAME_BYTES, sha256=digest.hexdigest())
        if scenario == "hold":
            # Never answer: the client must bound or cancel its own finish.
            try:
                opcode, _ = self.read_message()
            except (ConnectionError, OSError):
                opcode = None
            log("cartesia-client-released", closeFrame=opcode == 8)
        elif scenario == "incomplete":
            self.send_json({"type": "turn.start"})
            self.send_json({"type": "turn.update", "transcript": "Unfinished thought"})
            self.close_cartesia(1000, b"stream-complete")
        elif scenario == "abrupt":
            # The flush arrives, then the connection drops without a close frame.
            self.send_turn(*CARTESIA_TURNS[1])
            log("cartesia-abrupt-disconnect")
        elif scenario == "abnormal":
            # The flush arrives, then the server closes with a non-normal status.
            self.send_turn(*CARTESIA_TURNS[1])
            self.close_cartesia(1011, b"loopback-abnormal")
        else:
            self.send_turn(*CARTESIA_TURNS[1])
            if scenario == "failure":
                self.send_json({"type": "error", "status_code": 500, "title": "Loopback failure",
                                "message": "Synthetic terminal failure", "error_code": "loopback_failure"})
                self.close_cartesia(1011, b"loopback-failure")
            else:
                self.close_cartesia(1000, b"stream-complete")


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

#!/usr/bin/env python3
"""Bounded local-only Modulate peer with an explicitly released HTTP101 barrier.

Synthetic PCM only. No provider connections, microphone, credentials or PCM logs.
Control requests acknowledge the held upgrade before the test releases/fails it;
a fixed sleep is never used to manufacture the startup timing.
"""
import argparse
import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import struct
import threading
import time
import urllib.parse

_SPEC = importlib.util.spec_from_file_location("websocket_probe", Path(__file__).with_name("websocket-loopback-probe.py"))
WS = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(WS)
FRAME_BYTES = 3200
ROUTE = "/api/velma-2-stt-streaming"
SESSION = re.compile(r"[0-9a-f-]{36}")


def pcm(identifier):
    return struct.pack("<I", identifier) + bytes((identifier * 31 + offset * 7) & 255 for offset in range(4, FRAME_BYTES))


def wav_header():
    return (b"RIFF" + struct.pack("<I", 0xFFFFFFFF) + b"WAVEfmt "
            + struct.pack("<IHHIIHH", 16, 1, 1, 16000, 32000, 2, 16)
            + b"data" + struct.pack("<I", 0xFFFFFFFF))


class OpeningSession:
    def __init__(self, identifiers, ack_after):
        if (not isinstance(identifiers, list) or not 1 <= len(identifiers) <= 32
                or any(type(value) is not int or not 0 <= value <= 0xFFFFFFFF for value in identifiers)
                or len(set(identifiers)) != len(identifiers) or type(ack_after) is not int
                or not 1 <= ack_after <= len(identifiers)):
            raise ValueError("bounded unique synthetic identifiers and acknowledgement position required")
        self.expected = identifiers
        self.ack_after = ack_after
        self.release = threading.Event()
        self.lock = threading.Lock()
        self.changed = threading.Condition(self.lock)
        self.state = {"stage": "configured", "upgradeComplete": False, "receivedIDs": [],
                      "receivedPCMBytes": 0, "wavHeaders": 0, "upgradeHoldMilliseconds": 0, "endVerified": False, "rejectUpgrade": False}

    def snapshot(self):
        with self.lock:
            return {**self.state, "receivedIDs": list(self.state["receivedIDs"])}

    def update(self, **fields):
        with self.changed:
            self.state.update(fields)
            self.changed.notify_all()

    def await_stage(self, stages):
        with self.changed:
            self.changed.wait_for(lambda: self.state["stage"] in stages, timeout=4)

    def accept(self, payload):
        with self.lock:
            index = len(self.state["receivedIDs"])
            if index >= len(self.expected):
                raise ValueError("extra or duplicated PCM chunk")
            header = wav_header() if index == 0 else b""
            if payload != header + pcm(self.expected[index]):
                raise ValueError("PCM loss, duplication, order, bytes or WAV framing mismatch")
            if header:
                self.state["wavHeaders"] += 1
            self.state["receivedIDs"].append(self.expected[index])
            self.state["receivedPCMBytes"] += FRAME_BYTES
            return index + 1 == self.ack_after

    def finish(self):
        with self.lock:
            if self.state["receivedIDs"] != self.expected or self.state["wavHeaders"] != 1:
                raise ValueError("end before every exact PCM chunk and one WAV header")
            self.state.update(stage="completed", endVerified=True)
            self.changed.notify_all()


class OpeningServer(WS.ProbeServer):
    def __init__(self, address):
        super().__init__(address, OpeningHandler)
        self.sessions = {}
        self.session_lock = threading.Lock()

    def session(self, identifier, configuration=None):
        if not SESSION.fullmatch(identifier):
            raise ValueError("synthetic session ID required")
        with self.session_lock:
            if configuration is not None:
                if identifier in self.sessions or len(self.sessions) >= 32:
                    raise ValueError("duplicate session or session bound exceeded")
                self.sessions[identifier] = OpeningSession(configuration.get("ids"), configuration.get("ackAfter"))
            if identifier not in self.sessions:
                raise ValueError("unknown controlled session")
            return self.sessions[identifier]


class OpeningHandler(WS.ProbeHandler):
    def run_connection(self):
        session = None
        try:
            while b"\r\n\r\n" not in self.pending:
                block = self.request.recv(2048)
                if not block:
                    raise ConnectionError("closed before request")
                self.pending.extend(block)
                if len(self.pending) > 16384:
                    raise ValueError("request bound exceeded")
            header, remainder = self.pending.split(b"\r\n\r\n", 1)
            self.pending = bytearray(remainder)
            lines = header.decode("ascii").split("\r\n")
            method, target, version = lines[0].split(" ")
            headers = dict((key.lower(), value.strip()) for key, value in (line.split(":", 1) for line in lines[1:]))
            path, _, query = target.partition("?")
            if headers.get("x-jsti-probe") != "local-only" or version != "HTTP/1.1":
                raise ValueError("local synthetic marker required")
            if path.startswith("/control/"):
                return self.control(method, path, headers)
            if (method != "GET" or path != ROUTE or headers.get("upgrade", "").lower() != "websocket"
                    or "upgrade" not in {part.strip().lower() for part in headers.get("connection", "").split(",")}
                    or headers.get("sec-websocket-version") != "13"
                    or headers.get("sec-websocket-protocol") != "jsti-probe"
                    or urllib.parse.parse_qs(query).get("api_key") != ["synthetic-loopback-key"]):
                raise ValueError("unexpected synthetic Modulate upgrade")
            key = headers.get("sec-websocket-key", "")
            if len(base64.b64decode(key, validate=True)) != 16:
                raise ValueError("invalid WebSocket key")
            session = self.server.session(headers.get("x-jsti-opening-session", ""))
            if session.snapshot()["stage"] != "configured":
                raise ValueError("session upgrade reused")
            held_at = time.monotonic()
            session.update(stage="held")
            WS.log("modulate-upgrade-held", **session.snapshot())
            if not session.release.wait(8):
                raise ValueError("controlled upgrade release deadline exceeded")
            session.update(upgradeHoldMilliseconds=round((time.monotonic() - held_at) * 1000, 3))
            if session.snapshot()["rejectUpgrade"]:
                self.request.sendall(b"HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                session.update(stage="failed")
                return
            accept = base64.b64encode(hashlib.sha1((key + WS.GUID).encode("ascii")).digest()).decode("ascii")
            self.request.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                                  f"Sec-WebSocket-Accept: {accept}\r\nSec-WebSocket-Protocol: jsti-probe\r\n\r\n").encode("ascii"))
            self.upgraded = True
            session.update(stage="upgraded", upgradeComplete=True)
            while True:
                opcode, payload = self.read_message(close_ends=False)
                if opcode == 8:
                    session.update(stage="cancelled")
                    self.send_frame(8, payload)
                    return
                if opcode == 2:
                    if session.accept(payload):
                        self.send_frame(1, json.dumps({"type": "utterance", "utterance": {
                            "text": "Opening verified.", "utterance_uuid": "synthetic-opening"}}).encode())
                elif opcode == 1 and payload == b"":
                    session.finish()
                    self.send_frame(1, b'{"type":"done"}')
                    WS.log("modulate-opening-receipt", **session.snapshot())
                    return
                else:
                    raise ValueError("only exact binary PCM and empty text end accepted")
        except (ValueError, ConnectionError, OSError):
            if session and session.snapshot()["stage"] not in ("completed", "cancelled", "failed"):
                session.update(stage="failed")
            raise

    def control(self, method, path, headers):
        parts = path.split("/")
        if len(parts) != 4 or method not in ("GET", "POST"):
            raise ValueError("unexpected control request")
        _, _, identifier, action = parts
        if action == "configure" and method == "POST":
            length = int(headers.get("content-length", "0"))
            if not 1 <= length <= 4096:
                raise ValueError("configuration bound exceeded")
            session = self.server.session(identifier, json.loads(self.read_exact(length)))
        else:
            session = self.server.session(identifier)
            if action in ("release", "fail") and method == "POST":
                session.update(rejectUpgrade=action == "fail")
                session.release.set()
            elif action in ("await-held", "await-ended") and method == "POST":
                session.await_stage({"held"} if action == "await-held" else {"failed", "cancelled", "completed"})
            elif action != "state" or method != "GET":
                raise ValueError("unexpected control action")
        payload = json.dumps(session.snapshot(), sort_keys=True).encode()
        self.request.sendall((f"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {len(payload)}\r\n"
                              "Connection: close\r\n\r\n").encode() + payload)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ready-file", type=Path, required=True)
    parser.add_argument("--max-seconds", type=int, default=120)
    args = parser.parse_args()
    if not 1 <= args.max_seconds <= 600:
        parser.error("max-seconds must be between 1 and 600")
    with OpeningServer(("127.0.0.1", 0)) as server:
        ready = {"host": "127.0.0.1", "port": server.server_address[1]}
        args.ready_file.write_text(json.dumps(ready))
        timer = threading.Timer(args.max_seconds, server.shutdown)
        timer.daemon = True
        timer.start()
        WS.log("ready", **ready)
        try:
            server.serve_forever(poll_interval=0.1)
        finally:
            timer.cancel()


if __name__ == "__main__":
    main()

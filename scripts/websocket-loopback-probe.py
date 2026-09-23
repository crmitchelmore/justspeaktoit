#!/usr/bin/env python3
"""Bounded, credential-free RFC6455 echo peer for the native Swift runtime probe.

Only binds IPv4 loopback. No third-party packages or external connections.
The slow route deliberately applies socket backpressure; it is not a benchmark.
The Voxtral route plays Mistral's realtime transcription peer for the actual
shared Swift client, with a synthetic key and generated audio only.

The /gladia* routes play Gladia's two-stage live protocol for the shared
client: POST /<scenario>/v2/live creates a session and returns a single-use,
tokenised WebSocket URL; that socket takes 100 ms PCM16 frames and
stop_recording, and answers with transcripts and lifecycle events. The key is
a synthetic marker; tokens and keys never enter the logs.

The Cartesia route plays the Ink-2 automatic-turns stream at the shared
client's own path and query: exact 100 ms PCM16 frames, then the close
command, answered by the scenario's turns and the server's closure.

The Rev.ai route plays the streaming speech-to-text socket at the shared
client's own path and query: `connected` is held and nothing may arrive
before it, then exact 100 ms PCM16 frames and the literal EOS, answered by
the scenario's hypotheses and closure. The query carries the synthetic access
token, so a Rev.ai route's query never enters the logs.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import re
import secrets
import select
import socket
import socketserver
import struct
import threading
import time
import urllib.parse


MAX_PAYLOAD = 4 * 1024 * 1024
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
LOG_LOCK = threading.Lock()

# The Voxtral Realtime peer. The Swift probe sends the synthetic key, keeps
# the client's own path and model query, and names a scenario in a header.
MISTRAL_PATH = "/v1/audio/transcriptions/realtime"
MISTRAL_MODEL = "voxtral-mini-transcribe-realtime-2602"
MISTRAL_AUTHORIZATION = "Bearer jsti-loopback-synthetic"
MISTRAL_SCENARIOS = ("complete", "fragment", "disconnect", "silent")
MISTRAL_FRAME_BYTES = 3200  # 100 ms of 16 kHz mono PCM16
MISTRAL_HELD_FRAMES = 10  # queued by the client before session.created
MISTRAL_FRAMES = 20
# Escapes keep composed U+00E9 distinct from e + U+0301 and the joiner visible.
MISTRAL_UNICODE_HEAD = "\U0000754c \U00002014 caf\U000000e9"
MISTRAL_UNICODE_TAIL = " e\U00000301 \U0001f469\U0001f3fd\U0000200d\U0001f4bb"
MISTRAL_TEXT = {
    "complete": (["helo", " wrld"], "Hello world."),
    "fragment": ([MISTRAL_UNICODE_HEAD, MISTRAL_UNICODE_TAIL], MISTRAL_UNICODE_HEAD + MISTRAL_UNICODE_TAIL + "."),
}


def mistral_pcm(index):
    """The generated frame the Swift probe sends at this index."""
    return bytes((index * 31 + offset * 7) & 0xFF for offset in range(MISTRAL_FRAME_BYTES))


# The Gladia two-stage live peer: a marked local POST creates a session, whose
# single-use token the WebSocket upgrade must carry instead of the account key.
GLADIA_ROUTE = re.compile(r"/(gladia(?:-failure|-hold|-held-session)?)/(v2/live|live)")
GLADIA_SYNTHETIC_KEY = "synthetic-loopback-key"
GLADIA_FRAME_BYTES = 3_200
GLADIA_FRAMES = 10
# The failure lands once every frame was received, so it can only reach the
# client through its receive path, after the final that precedes it.
GLADIA_FAILURE_AFTER_FRAMES = GLADIA_FRAMES
GLADIA_SESSION_HOLD_SECONDS = 8
GLADIA_MAX_MESSAGES = 64
GLADIA_CREATED_AT = "2026-09-22T12:00:00Z"
# Mirrored exactly, scalar for scalar, by GladiaWinHTTPRuntimeTests. Spelled
# as escapes so the file stays ASCII and no editor can normalise a scalar.
GLADIA_PARTIAL = "Caf\U000000E9 \U00002014 na\U000000EFve"
GLADIA_FIRST_FINAL = ("Caf\U000000E9 \U00002014 na\U000000EFve e\U00000301 "
                      "\U0001F469\U0001F3FD\U0000200D\U0001F4BB \U0000754C.")
GLADIA_TAIL_PARTIAL = "\U000000DCbergr\U000000F6\U000000DFe"
GLADIA_TAIL_FINAL = "\U000000DCbergr\U000000F6\U000000DFe \U00002013 \U000000BD \U00002713 \U0001F600"
GLADIA_FAILURE_FINAL = "Vor dem Fehler \U00002014 \U000000E7a va."
GLADIA_HELD_FINAL = "Held \U000023F8 final."


def log(event, **fields):
    with LOG_LOCK:
        print(json.dumps({"event": event, **fields}, sort_keys=True), flush=True)


def gladia_pcm(index):
    """The 100 ms PCM16 frame the runtime test sends at position `index`."""
    return bytes((offset * 7 + index * 31) & 0xFF for offset in range(GLADIA_FRAME_BYTES))


def gladia_session_problems(body, headers):
    """Checks the session request against the shared client's documented init."""
    expected = {"model": "solaria-1", "encoding": "wav/pcm", "bit_depth": 16,
                "sample_rate": 16_000, "channels": 1}
    problems = [f"{name} must be {value!r}" for name, value in expected.items() if body.get(name) != value]
    messages = body.get("messages_config") or {}
    for flag in ("receive_partial_transcripts", "receive_final_transcripts", "receive_lifecycle_events"):
        if messages.get(flag) is not True:
            problems.append(f"{flag} must be true")
    if messages.get("receive_post_processing_events") is not False:
        problems.append("post-processing events must stay off")
    language = body.get("language_config") or {}
    if language.get("languages") != [] or language.get("code_switching") is not True:
        problems.append("automatic language detection expected")
    if headers.get("content-type") != "application/json":
        problems.append("content-type must be application/json")
    return problems


def gladia_transcript(utterance_id, text, is_final):
    return {"session_id": "loopback", "created_at": GLADIA_CREATED_AT, "type": "transcript",
            "data": {"id": utterance_id, "is_final": is_final,
                     "utterance": {"text": text, "start": 0.0, "end": 0.5, "language": "en", "channel": 0}}}


def gladia_lifecycle(kind, data=None):
    event = {"session_id": "loopback", "created_at": GLADIA_CREATED_AT, "type": kind}
    if data is not None:
        event["data"] = data
    return event


# Cartesia Ink-2 automatic-turns peer for the Cartesia loopback runtime tests.
# The route, query and headers are exactly what the shared Swift client builds;
# only the origin is redirected here. The key is synthetic and never logged.
CARTESIA_ROUTE = "/stt/turns/websocket"
CARTESIA_QUERY = "model=ink-2&encoding=pcm_s16le&sample_rate=16000&cartesia_version=2026-03-01"
CARTESIA_AUTHORIZATION = "Bearer loopback-synthetic-key"
CARTESIA_VERSION = "2026-03-01"
CARTESIA_SCENARIOS = ("complete", "failure", "incomplete", "hold", "abrupt", "abnormal")
CARTESIA_FRAMES = 10
CARTESIA_FRAME_BYTES = 3200
# (update, end) per turn. The second turn carries its own leading space, as
# Cartesia turns are concatenated without adding whitespace. Mirrored scalar
# for scalar by the Swift tests; spelled as escapes so this file stays ASCII.
CARTESIA_TURNS = (
    ("Gr\U000000FC\U000000DFe aus", "Gr\U000000FC\U000000DFe aus Z\U000000FCrich \U00002014 \U00004E16\U0000754C"),
    (" na\U000000EFve", " na\U000000EFve caf\U000000E9 \U0001F469\U0001F3FD\U0000200D\U0001F4BB"),
)


def cartesia_frame(index):
    """100 ms of 16 kHz PCM16 mono, generated identically by the Swift test."""
    return bytes(((index * 7 + offset * 13) & 0xFF) for offset in range(CARTESIA_FRAME_BYTES))


# Rev.ai streaming peer for the Rev.ai loopback runtime tests. The route and
# query items, in order, are exactly what the shared Swift client builds for a
# French selection; only the origin is redirected here.
REVAI_ROUTE = "/speechtotext/v1/stream"
REVAI_QUERY = {
    "access_token": "loopback-synthetic-token",
    "content_type": "audio/x-raw;layout=interleaved;rate=16000;format=S16LE;channels=1",
    "transcriber": "machine_v2",
    "language": "fr",
}
REVAI_SCENARIOS = ("complete", "credits", "early", "abrupt", "incomplete", "hold")
REVAI_FRAMES = 10
REVAI_FRAME_BYTES = 3200
# `connected` is held this long. Rev.ai rejects audio sent before it, so the
# client must stay silent meanwhile.
REVAI_CONNECTED_DELAY = 0.3
# Mirrored scalar for scalar by the Swift tests; spelled as escapes so this
# file stays ASCII. A partial carries words only, and a final's punct
# elements carry its spacing and punctuation, as in Rev.ai's example session.
REVAI_PARTIAL = ("Bonjour", "caf\U000000E9")
REVAI_FINAL = (("text", "Bonjour"), ("punct", ","), ("punct", " "), ("text", "caf\U000000E9"), ("punct", " "),
               ("text", "cr\U000000E8me"), ("punct", " "), ("punct", "\U00002014"), ("punct", " "),
               ("text", "na\U000000EFve"), ("punct", "."))
REVAI_TAIL_PARTIAL = ("\U0001F469\U0001F3FD\U0000200D\U0001F4BB",)
REVAI_TAIL_FINAL = (("text", "\U0001F469\U0001F3FD\U0000200D\U0001F4BB"), ("punct", " "), ("text", "fin"),
                    ("punct", "."))


def revai_frame(index):
    """100 ms of 16 kHz PCM16 mono, generated identically by the Swift tests."""
    return bytes(((index * 11 + offset * 17) & 0xFF) for offset in range(REVAI_FRAME_BYTES))


def revai_partial(words):
    return {"type": "partial", "ts": 0.0, "end_ts": 0.5,
            "elements": [{"type": "text", "value": word} for word in words]}


def revai_final(elements):
    return {"type": "final", "ts": 0.0, "end_ts": 1.0,
            "elements": [{"type": kind, "value": value} for kind, value in elements]}


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
        gladia = GLADIA_ROUTE.fullmatch(route)
        # Only protocol fields and the synthetic marker are recorded. No
        # credentials, arbitrary request headers or WebSocket keys enter logs,
        # and the query of a Gladia route (its session token) or a Rev.ai route
        # (its access token) is dropped.
        logged_path = route if gladia or route == REVAI_ROUTE else path
        log("handshake-request", method=method, path=logged_path, version=version,
            connection=headers.get("connection"), upgrade=headers.get("upgrade"),
            websocketVersion=headers.get("sec-websocket-version"),
            subprotocol=headers.get("sec-websocket-protocol"),
            markerVerified=headers.get("x-jsti-probe") == "local-only")
        if gladia and gladia.group(2) == "v2/live":
            self.create_gladia_session(method, gladia.group(1), headers)
            return None, None
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
        scenario = None
        if route == MISTRAL_PATH:
            self.mistral_scenario = self.verify_mistral_request(query, headers)
            path = route
        elif gladia:
            scenario = self.consume_gladia_token(gladia.group(1), query, headers)
            path = route
        elif route == CARTESIA_ROUTE:
            self.verify_cartesia(query, headers)
            path = route
        elif route == REVAI_ROUTE:
            self.verify_revai(query, headers)
            path = route
        elif path not in ("/echo", "/slow", "/hold", "/abrupt", "/delay", "/fragment", "/oversize"):
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
        return path, scenario

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

    def verify_mistral_request(self, query, headers):
        """Checks the client's own query and synthetic credential, logging only verdicts."""
        scenario = headers.get("x-jsti-mistral-scenario")
        model_verified = query == f"model={MISTRAL_MODEL}"
        authorization_verified = headers.get("authorization") == MISTRAL_AUTHORIZATION
        log("mistral-handshake", scenario=scenario, modelVerified=model_verified,
            authorizationVerified=authorization_verified)
        if scenario not in MISTRAL_SCENARIOS or not model_verified or not authorization_verified:
            raise ValueError("unexpected Voxtral handshake")
        return scenario

    def read_message(self, close_ends=True):
        """Returns one complete data message, answering pings; a close ends the peer.

        With close_ends=False a close frame is returned as (8, payload) instead,
        for a peer that initiated the closing handshake or is waiting for one."""
        message = bytearray()
        message_opcode = None
        while True:
            final, opcode, payload = self.read_frame()
            if opcode == 8:
                if not close_ends:
                    return 8, bytes(payload)
                self.send_frame(8, payload)
                raise ConnectionError("client closed")
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

    def read_mistral_event(self):
        opcode, message = self.read_message()
        if opcode != 1:
            raise ValueError("Voxtral client messages are JSON text")
        event = json.loads(message.decode("utf-8"))
        if not isinstance(event, dict) or not isinstance(event.get("type"), str):
            raise ValueError("Voxtral client message is not a typed JSON object")
        return event

    def send_mistral(self, event, fragmented):
        payload = json.dumps(event, ensure_ascii=False).encode("utf-8")
        if not fragmented:
            self.send_frame(1, payload)
            return
        # Split inside a multi-byte scalar when there is one, so the client's
        # transport must assemble the message before decoding its UTF-8.
        split = next((index for index, byte in enumerate(payload) if 0x80 <= byte <= 0xBF), 2)
        self.send_frame(1, payload[:split], final=False)
        self.send_frame(0, payload[split:split + 3], final=False)
        self.send_frame(0, payload[split + 3:])

    def reject_mistral(self, reason):
        self.send_frame(1, json.dumps({"type": "error", "error": {"message": reason, "code": 4000}}).encode())
        self.send_frame(8, struct.pack("!H", 1008) + b"protocol")
        raise ValueError(reason)

    def run_mistral(self, scenario):
        """Plays one Voxtral session: created, update before any audio, exact
        PCM, flush then end, deltas and a revised done unless the scenario
        withholds the completion."""
        fragmented = scenario == "fragment"
        deltas, done = MISTRAL_TEXT["fragment" if fragmented else "complete"]
        # Hold session.created briefly: audio captured meanwhile must wait.
        time.sleep(0.2)
        self.send_mistral({"type": "session.created",
                           "session": {"request_id": "loopback", "model": MISTRAL_MODEL}}, fragmented)
        update = self.read_mistral_event()
        if update["type"] != "session.update":
            self.reject_mistral(f"{update['type']} before session.update")
        session = update.get("session") or {}
        if (session.get("audio_format") != {"encoding": "pcm_s16le", "sample_rate": 16000}
                or session.get("target_streaming_delay_ms") != 480 or "language" in json.dumps(update)):
            self.reject_mistral("unexpected session.update")
        log("mistral-session-update", scenario=scenario, verified=True)
        digest = hashlib.sha256()
        frames = 0
        flushed = False
        while True:
            event = self.read_mistral_event()
            kind = event["type"]
            if kind == "input_audio.append" and not flushed and frames < MISTRAL_FRAMES:
                audio = base64.b64decode(event.get("audio", ""), validate=True)
                if audio != mistral_pcm(frames):
                    self.reject_mistral(f"append {frames} changed in transport")
                digest.update(audio)
                frames += 1
                if frames == MISTRAL_HELD_FRAMES:
                    self.send_mistral({"type": "session.updated", "session": session}, fragmented)
                    self.send_mistral({"type": "transcription.language", "audio_language": "en"}, fragmented)
                    for delta in deltas:
                        self.send_mistral({"type": "transcription.text.delta", "text": delta}, fragmented)
            elif kind == "input_audio.flush" and not flushed and frames == MISTRAL_FRAMES:
                flushed = True
            elif kind == "input_audio.end" and flushed:
                break
            else:
                self.reject_mistral(f"unexpected {kind} after {frames} frames")
        log("mistral-audio", scenario=scenario, frames=frames, bytes=frames * MISTRAL_FRAME_BYTES,
            sha256=digest.hexdigest(), flushThenEnd=True)
        if scenario == "disconnect":
            # Let the end's send completion land, then drop the TCP connection.
            time.sleep(0.1)
            log("mistral-disconnect", scenario=scenario)
            return
        if scenario == "silent":
            log("mistral-silent", scenario=scenario)
            while True:
                self.read_message()
        self.send_mistral({"type": "transcription.done", "model": MISTRAL_MODEL, "text": done,
                           "language": "en", "segments": [], "usage": {"prompt_audio_seconds": 2}}, fragmented)
        self.send_frame(8, struct.pack("!H", 1000) + b"transcription-complete")
        log("mistral-done", scenario=scenario)

    def run_connection(self):
        path, scenario = self.handshake()
        if path is None:
            return
        if path == MISTRAL_PATH:
            return self.run_mistral(self.mistral_scenario)
        if path == CARTESIA_ROUTE:
            return self.run_cartesia()
        if path == REVAI_ROUTE:
            return self.run_revai()
        if scenario is not None:
            self.run_gladia(path, scenario)
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

    # Gladia two-stage live protocol

    def create_gladia_session(self, method, scenario, headers):
        if method != "POST" or headers.get("x-jsti-probe") != "local-only":
            raise ValueError("gladia sessions are created by a marked local POST")
        length = int(headers.get("content-length", "0"))
        if not 0 < length <= 16 * 1024:
            raise ValueError("gladia session body out of bounds")
        if headers.get("expect", "").lower() == "100-continue":
            self.request.sendall(b"HTTP/1.1 100 Continue\r\n\r\n")
        body = json.loads(bytes(self.read_exact(length)).decode("utf-8"))
        key_verified = headers.get("x-gladia-key") == GLADIA_SYNTHETIC_KEY
        problems = gladia_session_problems(body, headers)
        log("gladia-session-request", scenario=scenario, keyVerified=key_verified, configVerified=not problems)
        if not key_verified:
            self.respond_json(401, "Unauthorized", {"statusCode": 401, "message": "Unauthorized"})
            return
        if problems:
            self.respond_json(422, "Unprocessable Entity", {"statusCode": 422, "message": "; ".join(problems)})
            return
        if scenario == "gladia-held-session":
            log("gladia-session-held", scenario=scenario, seconds=GLADIA_SESSION_HOLD_SECONDS)
            time.sleep(GLADIA_SESSION_HOLD_SECONDS)
        token = secrets.token_hex(16)
        with self.server.gladia_lock:
            self.server.gladia_tokens[token] = scenario
        port = self.server.server_address[1]
        self.respond_json(201, "Created", {
            "id": secrets.token_hex(8), "created_at": GLADIA_CREATED_AT,
            "url": f"ws://127.0.0.1:{port}/{scenario}/live?token={token}"})
        log("gladia-session-created", scenario=scenario)

    def respond_json(self, status, reason, payload):
        body = json.dumps(payload).encode("utf-8")
        head = (f"HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\n"
                f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n")
        self.request.sendall(head.encode("ascii") + body)

    def consume_gladia_token(self, scenario, query, headers):
        token = urllib.parse.parse_qs(query).get("token", [""])[0]
        with self.server.gladia_lock:
            issued = self.server.gladia_tokens.pop(token, None)
        account_key_absent = "x-gladia-key" not in headers and "authorization" not in headers
        log("gladia-socket-request", scenario=scenario, tokenVerified=issued == scenario,
            accountKeyAbsent=account_key_absent)
        if issued != scenario:
            raise ValueError("unknown or reused gladia session token")
        if not account_key_absent:
            raise ValueError("account credential forwarded to the session socket")
        return scenario

    def run_gladia(self, route, scenario):
        self.send_gladia(gladia_lifecycle("start_session"))
        digest = hashlib.sha256()
        frames = 0
        for _ in range(GLADIA_MAX_MESSAGES):
            # A client close raises ConnectionError, which ends the session.
            opcode, payload = self.read_message()
            if opcode == 2:
                if payload != gladia_pcm(frames):
                    log("gladia-pcm-mismatch", scenario=scenario, frame=frames + 1, bytes=len(payload))
                    self.send_gladia({"type": "error", "error": {"message": f"PCM frame {frames + 1} differs"}})
                    return
                frames += 1
                digest.update(payload)
                log("gladia-audio", scenario=scenario, frame=frames, bytes=len(payload))
                if self.reply_while_streaming(scenario, frames):
                    return
                continue
            if opcode != 1 or json.loads(payload.decode("utf-8")) != {"type": "stop_recording"}:
                raise ValueError("unexpected gladia client message")
            log("gladia-stop-recording", scenario=scenario, frames=frames,
                bytes=frames * GLADIA_FRAME_BYTES, sha256=digest.hexdigest())
            self.finish_gladia(route, scenario, frames)
            return
        raise ValueError("gladia message count exceeded bound")

    def reply_while_streaming(self, scenario, frames):
        """Sends the scenario's live transcripts; answers whether the session ended."""
        if scenario == "gladia" and frames == 2:
            self.send_fragmented_gladia(gladia_transcript("00-00000001", GLADIA_PARTIAL, False))
        elif scenario == "gladia" and frames == 4:
            self.send_fragmented_gladia(gladia_transcript("00-00000001", GLADIA_FIRST_FINAL, True))
        elif scenario == "gladia-hold" and frames == 1:
            self.send_fragmented_gladia(gladia_transcript("00-00000001", GLADIA_HELD_FINAL, True))
        elif scenario == "gladia-failure" and frames == GLADIA_FAILURE_AFTER_FRAMES:
            self.send_fragmented_gladia(gladia_transcript("00-00000001", GLADIA_FAILURE_FINAL, True))
            self.send_frame(8, struct.pack("!H", 1011) + b"synthetic failure")
            log("gladia-terminal-failure", scenario=scenario, frames=frames)
            return True
        return False

    def finish_gladia(self, route, scenario, frames):
        if scenario == "gladia-hold":
            # Never answers stop_recording: the client must bound its own wait,
            # and its close or cancellation ends the session.
            log("gladia-holding-completion", scenario=scenario)
            for _ in range(GLADIA_MAX_MESSAGES):
                self.read_message()
            raise ValueError("gladia message count exceeded bound")
        if frames != GLADIA_FRAMES:
            self.send_gladia({"type": "error", "error": {
                "message": f"expected {GLADIA_FRAMES} PCM frames, received {frames}"}})
            return
        self.send_fragmented_gladia(gladia_transcript("00-00000002", GLADIA_TAIL_PARTIAL, False))
        self.send_fragmented_gladia(gladia_transcript("00-00000002", GLADIA_TAIL_FINAL, True))
        self.send_gladia(gladia_lifecycle("end_recording", {
            "reason": "user_request", "received_total_bytes": frames * GLADIA_FRAME_BYTES}))
        self.send_gladia(gladia_lifecycle("end_session"))
        self.send_frame(8, struct.pack("!H", 1000) + b"session-complete")
        log("gladia-session-complete", scenario=scenario, frames=frames)
        _, reply_opcode, _ = self.read_frame()
        log("close-acknowledged" if reply_opcode == 8 else "close-unacknowledged", path=route)

    def send_gladia(self, payload):
        self.send_frame(1, json.dumps(payload, ensure_ascii=False).encode("utf-8"))

    def send_fragmented_gladia(self, payload):
        """Splits one text message inside UTF-8 scalars across continuation frames."""
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        continuation = [index for index, byte in enumerate(data) if 0x80 <= byte < 0xC0]
        if len(continuation) < 2:
            raise ValueError("fragmented transcript needs multi-byte text")
        cuts = sorted({continuation[0], continuation[len(continuation) // 2]})
        bounds = list(zip([0] + cuts, cuts + [len(data)]))
        for number, (start, end) in enumerate(bounds):
            self.send_frame(1 if number == 0 else 0, data[start:end], final=number == len(bounds) - 1)

    # Cartesia Ink-2 automatic-turns stream

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

    def send_json(self, event, request_id="loopback"):
        """One text message, split inside a multi-byte UTF-8 scalar when it has
        one, so the client must assemble the message before decoding it. Ink-2
        events name their connection; Rev.ai's pass request_id=None."""
        body = {**event, "request_id": request_id} if request_id else event
        payload = json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
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
            opcode, _ = self.read_message(close_ends=False)
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
            opcode, payload = self.read_message(close_ends=False)
            if opcode != 2 or payload != cartesia_frame(index):
                return self.reject_cartesia(f"PCM frame {index} was not the exact 100 ms frame")
            digest.update(payload)
            if scenario == "complete" and index == CARTESIA_FRAMES // 2 - 1:
                # A turn that ends while audio is still streaming.
                self.send_turn(*CARTESIA_TURNS[0])
        opcode, payload = self.read_message(close_ends=False)
        if opcode != 1 or payload != b'{"type":"close"}':
            return self.reject_cartesia("expected the close command after every audio frame")
        log("cartesia-close-command", scenario=scenario, frames=CARTESIA_FRAMES,
            bytes=CARTESIA_FRAMES * CARTESIA_FRAME_BYTES, sha256=digest.hexdigest())
        if scenario == "hold":
            # Never answer: the client must bound or cancel its own finish.
            try:
                opcode, _ = self.read_message(close_ends=False)
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

    # Rev.ai streaming speech-to-text

    def verify_revai(self, query, headers):
        """The exact request the shared client builds: route, query items in
        order with the synthetic token, and no header credential. Only
        verdicts are logged, never the query."""
        scenario = headers.get("x-jsti-revai-scenario", "")
        try:
            items = urllib.parse.parse_qsl(query, keep_blank_values=True, strict_parsing=True)
        except ValueError:
            items = []
        checks = {
            "queryVerified": items == list(REVAI_QUERY.items()),
            "authorizationAbsent": "authorization" not in headers,
            "scenarioVerified": scenario in REVAI_SCENARIOS,
        }
        log("revai-handshake", scenario=scenario if checks["scenarioVerified"] else None, **checks)
        if not all(checks.values()):
            raise ValueError("unexpected Rev.ai handshake")
        self.revai_scenario = scenario

    def close_revai(self, code, reason):
        """Ends the stream from the server side, then drains the client until its
        closing reply or disconnect; audio already in flight may precede it."""
        opcode = None
        try:
            self.send_frame(8, struct.pack("!H", code) + reason)
            log("revai-server-close", code=code)
            for _ in range(REVAI_FRAMES + 2):
                opcode, _ = self.read_message(close_ends=False)
                if opcode == 8:
                    break
        except (ConnectionError, OSError):
            opcode = None
        log("revai-closed", acknowledged=opcode == 8)

    def reject_revai(self, reason):
        """A deviation closes with Rev.ai's bad-request status, which the Swift
        test reports as a failure."""
        log("revai-protocol-violation", reason=reason)
        self.close_revai(4002, b"loopback-protocol-violation")

    def run_revai(self):
        """Holds `connected` and requires silence meanwhile, then the exact
        100 ms PCM frames in order and the literal EOS, and answers as the
        scenario asks: a partial and a final while audio streams, then the tail
        hypotheses and the closure that end the stream after EOS."""
        scenario = self.revai_scenario
        readable, _, _ = select.select([self.request], [], [], REVAI_CONNECTED_DELAY)
        if self.pending or readable:
            return self.reject_revai("the client sent data before connected")
        self.send_json({"type": "connected", "id": "loopback"}, request_id=None)
        digest = hashlib.sha256()
        for index in range(REVAI_FRAMES):
            opcode, payload = self.read_message(close_ends=False)
            if opcode != 2 or payload != revai_frame(index):
                return self.reject_revai(f"PCM frame {index} was not the exact 100 ms frame")
            digest.update(payload)
            if index == 1:
                self.send_json(revai_partial(REVAI_PARTIAL), request_id=None)
            elif index == 3:
                self.send_json(revai_final(REVAI_FINAL), request_id=None)
                if scenario == "credits":
                    log("revai-credits-exhausted", frames=index + 1)
                    return self.close_revai(4003, b"insufficient-credits")
        if scenario == "early":
            # The server ends the stream on its own, as at its three-hour limit,
            # before the client has finished.
            log("revai-early-close", frames=REVAI_FRAMES)
            return self.close_revai(1000, b"reached-max-session-lifetime")
        opcode, payload = self.read_message(close_ends=False)
        if opcode != 1 or payload != b"EOS":
            return self.reject_revai("expected the literal EOS after every audio frame")
        log("revai-end-of-stream", scenario=scenario, frames=REVAI_FRAMES,
            bytes=REVAI_FRAMES * REVAI_FRAME_BYTES, sha256=digest.hexdigest())
        if scenario == "hold":
            # Never answer: the client must bound or cancel its own finish.
            try:
                opcode, _ = self.read_message(close_ends=False)
            except (ConnectionError, OSError):
                opcode = None
            log("revai-client-released", closeFrame=opcode == 8)
            return None
        self.send_json(revai_partial(REVAI_TAIL_PARTIAL), request_id=None)
        if scenario == "incomplete":
            # The last partial never gets its final before the closure.
            return self.close_revai(1000, b"end-of-stream")
        self.send_json(revai_final(REVAI_TAIL_FINAL), request_id=None)
        if scenario == "abrupt":
            # The tail arrives, then the connection drops without a close frame.
            log("revai-abrupt-disconnect")
            return None
        return self.close_revai(1000, b"end-of-stream")


class ProbeServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    daemon_threads = True
    allow_reuse_address = False
    slots = threading.BoundedSemaphore(8)
    gladia_lock = threading.Lock()
    gladia_tokens = {}


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

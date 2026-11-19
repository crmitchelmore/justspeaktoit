"""The Gladia two-stage live peer for the shared Swift client.

POST /<scenario>/v2/live creates a session and returns a single-use, tokenised
WebSocket URL; that socket takes 100 ms PCM16 frames and stop_recording, and
answers with transcripts and lifecycle events. A marked local POST creates the
session, whose token the upgrade must carry instead of the account key. The key
is a synthetic marker; tokens and keys never enter the logs.
"""
import hashlib
import json
import re
import secrets
import struct
import time
import urllib.parse

from loopback_wire import log

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


def respond_json(conn, status, reason, payload):
    body = json.dumps(payload).encode("utf-8")
    head = (f"HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\n"
            f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n")
    conn.request.sendall(head.encode("ascii") + body)


def create_gladia_session(conn, method, scenario, headers):
    """Answers the session POST and issues a single-use socket token on the server."""
    if method != "POST" or headers.get("x-jsti-probe") != "local-only":
        raise ValueError("gladia sessions are created by a marked local POST")
    length = int(headers.get("content-length", "0"))
    if not 0 < length <= 16 * 1024:
        raise ValueError("gladia session body out of bounds")
    if headers.get("expect", "").lower() == "100-continue":
        conn.request.sendall(b"HTTP/1.1 100 Continue\r\n\r\n")
    body = json.loads(bytes(conn.read_exact(length)).decode("utf-8"))
    key_verified = headers.get("x-gladia-key") == GLADIA_SYNTHETIC_KEY
    problems = gladia_session_problems(body, headers)
    log("gladia-session-request", scenario=scenario, keyVerified=key_verified, configVerified=not problems)
    if not key_verified:
        respond_json(conn, 401, "Unauthorized", {"statusCode": 401, "message": "Unauthorized"})
        return
    if problems:
        respond_json(conn, 422, "Unprocessable Entity", {"statusCode": 422, "message": "; ".join(problems)})
        return
    if scenario == "gladia-held-session":
        log("gladia-session-held", scenario=scenario, seconds=GLADIA_SESSION_HOLD_SECONDS)
        time.sleep(GLADIA_SESSION_HOLD_SECONDS)
    token = secrets.token_hex(16)
    with conn.server.gladia_lock:
        conn.server.gladia_tokens[token] = scenario
    port = conn.server.server_address[1]
    respond_json(conn, 201, "Created", {
        "id": secrets.token_hex(8), "created_at": GLADIA_CREATED_AT,
        "url": f"ws://127.0.0.1:{port}/{scenario}/live?token={token}"})
    log("gladia-session-created", scenario=scenario)


def consume_gladia_token(conn, scenario, query, headers):
    """Admits an upgrade only with the session's own token and no account key."""
    token = urllib.parse.parse_qs(query).get("token", [""])[0]
    with conn.server.gladia_lock:
        issued = conn.server.gladia_tokens.pop(token, None)
    account_key_absent = "x-gladia-key" not in headers and "authorization" not in headers
    log("gladia-socket-request", scenario=scenario, tokenVerified=issued == scenario,
        accountKeyAbsent=account_key_absent)
    if issued != scenario:
        raise ValueError("unknown or reused gladia session token")
    if not account_key_absent:
        raise ValueError("account credential forwarded to the session socket")
    return scenario


class GladiaPeer:
    """One Gladia session socket, admitted by consume_gladia_token."""

    def __init__(self, conn, route, scenario):
        self.conn = conn
        self.route = route
        self.scenario = scenario

    def run(self):
        scenario = self.scenario
        self.send(gladia_lifecycle("start_session"))
        digest = hashlib.sha256()
        frames = 0
        for _ in range(GLADIA_MAX_MESSAGES):
            # A client close raises ConnectionError, which ends the session.
            opcode, payload = self.conn.read_message()
            if opcode == 2:
                if payload != gladia_pcm(frames):
                    log("gladia-pcm-mismatch", scenario=scenario, frame=frames + 1, bytes=len(payload))
                    self.send({"type": "error", "error": {"message": f"PCM frame {frames + 1} differs"}})
                    return
                frames += 1
                digest.update(payload)
                log("gladia-audio", scenario=scenario, frame=frames, bytes=len(payload))
                if self.reply_while_streaming(frames):
                    return
                continue
            if opcode != 1 or json.loads(payload.decode("utf-8")) != {"type": "stop_recording"}:
                raise ValueError("unexpected gladia client message")
            log("gladia-stop-recording", scenario=scenario, frames=frames,
                bytes=frames * GLADIA_FRAME_BYTES, sha256=digest.hexdigest())
            self.finish(frames)
            return
        raise ValueError("gladia message count exceeded bound")

    def reply_while_streaming(self, frames):
        """Sends the scenario's live transcripts; answers whether the session ended."""
        scenario = self.scenario
        if scenario == "gladia" and frames == 2:
            self.send_fragmented(gladia_transcript("00-00000001", GLADIA_PARTIAL, False))
        elif scenario == "gladia" and frames == 4:
            self.send_fragmented(gladia_transcript("00-00000001", GLADIA_FIRST_FINAL, True))
        elif scenario == "gladia-hold" and frames == 1:
            self.send_fragmented(gladia_transcript("00-00000001", GLADIA_HELD_FINAL, True))
        elif scenario == "gladia-failure" and frames == GLADIA_FAILURE_AFTER_FRAMES:
            self.send_fragmented(gladia_transcript("00-00000001", GLADIA_FAILURE_FINAL, True))
            self.conn.send_frame(8, struct.pack("!H", 1011) + b"synthetic failure")
            log("gladia-terminal-failure", scenario=scenario, frames=frames)
            return True
        return False

    def finish(self, frames):
        scenario = self.scenario
        if scenario == "gladia-hold":
            # Never answers stop_recording: the client must bound its own wait,
            # and its close or cancellation ends the session.
            log("gladia-holding-completion", scenario=scenario)
            for _ in range(GLADIA_MAX_MESSAGES):
                self.conn.read_message()
            raise ValueError("gladia message count exceeded bound")
        if frames != GLADIA_FRAMES:
            self.send({"type": "error", "error": {
                "message": f"expected {GLADIA_FRAMES} PCM frames, received {frames}"}})
            return
        self.send_fragmented(gladia_transcript("00-00000002", GLADIA_TAIL_PARTIAL, False))
        self.send_fragmented(gladia_transcript("00-00000002", GLADIA_TAIL_FINAL, True))
        self.send(gladia_lifecycle("end_recording", {
            "reason": "user_request", "received_total_bytes": frames * GLADIA_FRAME_BYTES}))
        self.send(gladia_lifecycle("end_session"))
        self.conn.send_frame(8, struct.pack("!H", 1000) + b"session-complete")
        log("gladia-session-complete", scenario=scenario, frames=frames)
        _, reply_opcode, _ = self.conn.read_frame()
        log("close-acknowledged" if reply_opcode == 8 else "close-unacknowledged", path=self.route)

    def send(self, payload):
        self.conn.send_frame(1, json.dumps(payload, ensure_ascii=False).encode("utf-8"))

    def send_fragmented(self, payload):
        """Splits one text message inside UTF-8 scalars across continuation frames."""
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        continuation = [index for index, byte in enumerate(data) if 0x80 <= byte < 0xC0]
        if len(continuation) < 2:
            raise ValueError("fragmented transcript needs multi-byte text")
        cuts = sorted({continuation[0], continuation[len(continuation) // 2]})
        bounds = list(zip([0] + cuts, cuts + [len(data)]))
        for number, (start, end) in enumerate(bounds):
            self.conn.send_frame(1 if number == 0 else 0, data[start:end], final=number == len(bounds) - 1)

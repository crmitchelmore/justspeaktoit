"""The Rev.ai streaming speech-to-text peer for the Rev.ai loopback runtime tests.

The route and query items, in order, are exactly what the shared Swift client
builds for a French selection; only the origin is redirected here. `connected`
is held and nothing may arrive before it, then exact 100 ms PCM16 frames and the
literal EOS are answered by the scenario's hypotheses and closure. The query
carries the synthetic access token, so a Rev.ai route's query never enters the
logs.
"""
import hashlib
import select
import struct
import urllib.parse

from loopback_wire import log, send_json

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


def verify_revai(query, headers):
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
    return scenario


class RevAIPeer:
    """One Rev.ai stream on an upgraded connection."""

    def __init__(self, conn, scenario):
        self.conn = conn
        self.scenario = scenario

    def send(self, event):
        send_json(self.conn, event, request_id=None)

    def close(self, code, reason):
        """Ends the stream from the server side, then drains the client until its
        closing reply or disconnect; audio already in flight may precede it."""
        opcode = None
        try:
            self.conn.send_frame(8, struct.pack("!H", code) + reason)
            log("revai-server-close", code=code)
            for _ in range(REVAI_FRAMES + 2):
                opcode, _ = self.conn.read_message(close_ends=False)
                if opcode == 8:
                    break
        except (ConnectionError, OSError):
            opcode = None
        log("revai-closed", acknowledged=opcode == 8)

    def reject(self, reason):
        """A deviation closes with Rev.ai's bad-request status, which the Swift
        test reports as a failure."""
        log("revai-protocol-violation", reason=reason)
        self.close(4002, b"loopback-protocol-violation")

    def run(self):
        """Holds `connected` and requires silence meanwhile, then the exact
        100 ms PCM frames in order and the literal EOS, and answers as the
        scenario asks: a partial and a final while audio streams, then the tail
        hypotheses and the closure that end the stream after EOS."""
        scenario = self.scenario
        readable, _, _ = select.select([self.conn.request], [], [], REVAI_CONNECTED_DELAY)
        if self.conn.pending or readable:
            return self.reject("the client sent data before connected")
        self.send({"type": "connected", "id": "loopback"})
        digest = hashlib.sha256()
        for index in range(REVAI_FRAMES):
            opcode, payload = self.conn.read_message(close_ends=False)
            if opcode != 2 or payload != revai_frame(index):
                return self.reject(f"PCM frame {index} was not the exact 100 ms frame")
            digest.update(payload)
            if index == 1:
                self.send(revai_partial(REVAI_PARTIAL))
            elif index == 3:
                self.send(revai_final(REVAI_FINAL))
                if scenario == "credits":
                    log("revai-credits-exhausted", frames=index + 1)
                    return self.close(4003, b"insufficient-credits")
        if scenario == "early":
            # The server ends the stream on its own, as at its three-hour limit,
            # before the client has finished.
            log("revai-early-close", frames=REVAI_FRAMES)
            return self.close(1000, b"reached-max-session-lifetime")
        opcode, payload = self.conn.read_message(close_ends=False)
        if opcode != 1 or payload != b"EOS":
            return self.reject("expected the literal EOS after every audio frame")
        log("revai-end-of-stream", scenario=scenario, frames=REVAI_FRAMES,
            bytes=REVAI_FRAMES * REVAI_FRAME_BYTES, sha256=digest.hexdigest())
        if scenario == "hold":
            # Never answer: the client must bound or cancel its own finish.
            try:
                opcode, _ = self.conn.read_message(close_ends=False)
            except (ConnectionError, OSError):
                opcode = None
            log("revai-client-released", closeFrame=opcode == 8)
            return None
        self.send(revai_partial(REVAI_TAIL_PARTIAL))
        if scenario == "incomplete":
            # The last partial never gets its final before the closure.
            return self.close(1000, b"end-of-stream")
        self.send(revai_final(REVAI_TAIL_FINAL))
        if scenario == "abrupt":
            # The tail arrives, then the connection drops without a close frame.
            log("revai-abrupt-disconnect")
            return None
        return self.close(1000, b"end-of-stream")

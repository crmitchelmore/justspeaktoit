"""The Cartesia Ink-2 automatic-turns peer for the Cartesia loopback runtime tests.

The route, query and headers are exactly what the shared Swift client builds;
only the origin is redirected here. Exact 100 ms PCM16 frames, then the close
command, are answered by the scenario's turns and the server's closure. The key
is synthetic and never logged.
"""
import hashlib
import struct

from loopback_wire import log, send_json

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


def verify_cartesia(query, headers):
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
    return scenario


class CartesiaPeer:
    """One Ink-2 stream on an upgraded connection."""

    def __init__(self, conn, scenario):
        self.conn = conn
        self.scenario = scenario

    def send(self, event):
        send_json(self.conn, event)

    def send_turn(self, update, end):
        self.send({"type": "turn.start"})
        self.send({"type": "turn.update", "transcript": update})
        self.send({"type": "turn.end", "transcript": end})

    def close(self, code, reason):
        """Ends the stream from the server side, as Cartesia does after `close`."""
        try:
            self.conn.send_frame(8, struct.pack("!H", code) + reason)
            log("cartesia-server-close", code=code)
            opcode, _ = self.conn.read_message(close_ends=False)
        except (ConnectionError, OSError):
            opcode = None
        log("cartesia-closed", acknowledged=opcode == 8)

    def reject(self, reason):
        log("cartesia-protocol-violation", reason=reason)
        self.send({"type": "error", "status_code": 400, "title": "Loopback protocol violation",
                   "message": reason, "error_code": "loopback_protocol"})
        self.close(1008, b"protocol-violation")

    def run(self):
        """Requires the exact 100 ms PCM frames in order, then the close command,
        then answers as the scenario asks. Any deviation is reported to the client
        as a Cartesia error frame, which fails the Swift test visibly."""
        scenario = self.scenario
        self.send({"type": "connected"})
        digest = hashlib.sha256()
        for index in range(CARTESIA_FRAMES):
            opcode, payload = self.conn.read_message(close_ends=False)
            if opcode != 2 or payload != cartesia_frame(index):
                return self.reject(f"PCM frame {index} was not the exact 100 ms frame")
            digest.update(payload)
            if scenario == "complete" and index == CARTESIA_FRAMES // 2 - 1:
                # A turn that ends while audio is still streaming.
                self.send_turn(*CARTESIA_TURNS[0])
        opcode, payload = self.conn.read_message(close_ends=False)
        if opcode != 1 or payload != b'{"type":"close"}':
            return self.reject("expected the close command after every audio frame")
        log("cartesia-close-command", scenario=scenario, frames=CARTESIA_FRAMES,
            bytes=CARTESIA_FRAMES * CARTESIA_FRAME_BYTES, sha256=digest.hexdigest())
        if scenario == "hold":
            # Never answer: the client must bound or cancel its own finish.
            try:
                opcode, _ = self.conn.read_message(close_ends=False)
            except (ConnectionError, OSError):
                opcode = None
            log("cartesia-client-released", closeFrame=opcode == 8)
        elif scenario == "incomplete":
            self.send({"type": "turn.start"})
            self.send({"type": "turn.update", "transcript": "Unfinished thought"})
            self.close(1000, b"stream-complete")
        elif scenario == "abrupt":
            # The flush arrives, then the connection drops without a close frame.
            self.send_turn(*CARTESIA_TURNS[1])
            log("cartesia-abrupt-disconnect")
        elif scenario == "abnormal":
            # The flush arrives, then the server closes with a non-normal status.
            self.send_turn(*CARTESIA_TURNS[1])
            self.close(1011, b"loopback-abnormal")
        else:
            self.send_turn(*CARTESIA_TURNS[1])
            if scenario == "failure":
                self.send({"type": "error", "status_code": 500, "title": "Loopback failure",
                           "message": "Synthetic terminal failure", "error_code": "loopback_failure"})
                self.close(1011, b"loopback-failure")
            else:
                self.close(1000, b"stream-complete")
        return None

"""The Azure Voice Live input-transcription peer for the Azure loopback runtime tests.

The route, query and api-key header are exactly what the shared Swift client
builds; only the origin is redirected here. The transcription-only
configuration, exact 100 ms PCM16 frames with a server-VAD turn part way, then
the client's commit and finalisation barrier are answered as the scenario asks.
The key is synthetic and never logged. Voice Live never ends a session itself;
the client's close does.
"""
import base64
import hashlib
import json
import struct

from loopback_wire import log, send_json

AZURE_ROUTE = "/voice-live/realtime"
AZURE_QUERY = "api-version=2026-04-10&model=gpt-4.1"
AZURE_KEY = "loopback-synthetic-key"
AZURE_SCENARIOS = ("complete", "commit-empty", "barrier-error", "abrupt", "hold")
AZURE_FRAMES = 10
AZURE_FRAME_BYTES = 4800  # 100 ms of 24 kHz mono PCM16
AZURE_VAD_AFTER_FRAMES = 5
# Mirrored scalar for scalar by the Swift tests; spelled as escapes so this
# file stays ASCII and no editor can normalise a scalar.
AZURE_VAD_DRAFT = "Gr\U000000FC\U000000DFe aus"
AZURE_VAD_FINAL = "Gr\U000000FC\U000000DFe aus Z\U000000FCrich \U00002014 \U00004E16\U0000754C"
AZURE_TAIL_DRAFT = "na\U000000EFve"
AZURE_TAIL_FINAL = "na\U000000EFve caf\U000000E9 \U0001F469\U0001F3FD\U0000200D\U0001F4BB"


def azure_frame(index):
    """100 ms of 24 kHz PCM16 mono, generated identically by the Swift test."""
    return bytes(((index * 31 + offset * 7) & 0xFF) for offset in range(AZURE_FRAME_BYTES))


def azure_transcription(kind, item, text):
    field = "delta" if kind == "delta" else "transcript"
    return {"type": f"conversation.item.input_audio_transcription.{kind}", "item_id": item,
            "content_index": 0, field: text}


def verify_azure(query, headers):
    """The exact request the shared client builds: route, query and api-key header."""
    scenario = headers.get("x-jsti-azure-scenario", "")
    checks = {
        "queryVerified": query == AZURE_QUERY,
        "keyVerified": headers.get("api-key") == AZURE_KEY,
        "bearerAbsent": "authorization" not in headers,
        "scenarioVerified": scenario in AZURE_SCENARIOS,
    }
    log("azure-handshake", scenario=scenario if checks["scenarioVerified"] else None, **checks)
    if not all(checks.values()):
        raise ValueError("unexpected Azure Voice Live handshake")
    return scenario


def azure_configuration_problem(update):
    session = update.get("session") or {}
    transcription = session.get("input_audio_transcription") or {}
    turns = session.get("turn_detection") or {}
    expected = (update.get("type") == "session.update" and bool(update.get("event_id"))
                and session.get("modalities") == ["text"] and session.get("input_audio_format") == "pcm16"
                and session.get("input_audio_sampling_rate") == 24000
                and transcription.get("model") == "azure-speech" and "language" not in transcription
                and turns.get("type") == "azure_semantic_vad" and turns.get("create_response") is False)
    return None if expected else "expected the transcription-only session.update first"


class AzurePeer:
    """One Voice Live session on an upgraded connection."""

    def __init__(self, conn, scenario):
        self.conn = conn
        self.scenario = scenario

    def send(self, event):
        """Voice Live events carry their own event_id, never a request_id."""
        send_json(self.conn, event, request_id=None)

    def read_event(self):
        opcode, message = self.conn.read_message(close_ends=False)
        if opcode == 8:
            raise ConnectionError("client closed")
        if opcode != 1:
            raise ValueError("Voice Live client messages are JSON text")
        event = json.loads(message.decode("utf-8"))
        if not isinstance(event, dict) or not isinstance(event.get("type"), str):
            raise ValueError("Voice Live client message is not a typed JSON object")
        return event

    def reject(self, reason):
        """Reports a deviation as a Voice Live error, which fails the Swift test visibly."""
        log("azure-protocol-violation", reason=reason)
        self.send({"type": "error", "event_id": "event_violation", "error": {
            "type": "invalid_request_error", "code": "loopback_protocol", "message": reason}})
        self.wait_for_close()

    def wait_for_close(self):
        """Voice Live never closes a session itself: the client's close ends it."""
        opcode = None
        try:
            for _ in range(64):
                opcode, _ = self.conn.read_message(close_ends=False)
                if opcode == 8:
                    self.conn.send_frame(8, struct.pack("!H", 1000))
                    break
        except (ConnectionError, OSError):
            opcode = None
        log("azure-client-closed", closeFrame=opcode == 8)

    def read_audio(self):
        """Requires the exact 100 ms frames in order; server VAD ends a turn part way."""
        digest = hashlib.sha256()
        for index in range(AZURE_FRAMES):
            event = self.read_event()
            audio = event.get("audio", "") if event["type"] == "input_audio_buffer.append" else None
            if audio is None or base64.b64decode(audio, validate=True) != azure_frame(index):
                return f"PCM frame {index} was not the exact 100 ms frame"
            digest.update(azure_frame(index))
            if index == AZURE_VAD_AFTER_FRAMES - 1:
                self.send({"type": "input_audio_buffer.committed", "item_id": "item_vad",
                           "previous_item_id": None})
                self.send(azure_transcription("delta", "item_vad", AZURE_VAD_DRAFT))
                self.send(azure_transcription("completed", "item_vad", AZURE_VAD_FINAL))
        log("azure-audio", scenario=self.scenario, frames=AZURE_FRAMES, bytes=AZURE_FRAMES * AZURE_FRAME_BYTES,
            sha256=digest.hexdigest())
        return None

    def run(self):
        """Plays one session: created, the configuration and its acknowledgement,
        exact PCM, then the commit and the barrier, answered as the scenario asks.
        Any deviation is reported to the client as a Voice Live error."""
        scenario = self.scenario
        self.send({"type": "session.created", "event_id": "event_created", "session": {"id": "sess_loopback"}})
        update = self.read_event()
        problem = azure_configuration_problem(update)
        if problem:
            return self.reject(problem)
        self.send({"type": "session.updated", "event_id": "event_configured", "session": {"id": "sess_loopback"}})
        problem = self.read_audio()
        if problem:
            return self.reject(problem)
        commit = self.read_event()
        if commit["type"] != "input_audio_buffer.commit" or not commit.get("event_id"):
            return self.reject("expected the commit after every audio frame")
        if scenario == "commit-empty":
            # Server VAD already committed everything, so the commit finds nothing.
            self.send({"type": "error", "event_id": "event_empty", "error": {
                "type": "invalid_request_error", "code": "input_audio_buffer_commit_empty",
                "message": "Synthetic empty buffer", "event_id": commit["event_id"]}})
        else:
            self.send({"type": "input_audio_buffer.committed", "item_id": "item_tail",
                       "previous_item_id": "item_vad"})
        barrier = self.read_event()
        if (barrier["type"] != "session.update" or barrier.get("session") != {"modalities": ["text"]}
                or barrier.get("event_id") in (None, update["event_id"], commit["event_id"])):
            return self.reject("expected the finalisation barrier after the commit")
        log("azure-barrier", scenario=scenario)
        if scenario == "abrupt":
            # The barrier arrives, then the connection drops without a close frame.
            log("azure-abrupt-disconnect")
            return None
        if scenario == "barrier-error":
            self.send(azure_transcription("completed", "item_tail", AZURE_TAIL_FINAL))
            self.send({"type": "error", "event_id": "event_barrier_failure", "error": {
                "type": "server_error", "code": "server_error", "message": "Synthetic server failure",
                "event_id": barrier["event_id"]}})
        elif scenario != "hold":
            # "hold" never answers: the client must bound or cancel its own finish.
            self.send({"type": "session.updated", "event_id": "event_barrier", "session": {"id": "sess_loopback"}})
            if scenario == "complete":
                self.send(azure_transcription("delta", "item_tail", AZURE_TAIL_DRAFT))
                self.send(azure_transcription("completed", "item_tail", AZURE_TAIL_FINAL))
        return self.wait_for_close()

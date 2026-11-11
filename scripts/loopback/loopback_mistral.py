"""The Voxtral Realtime peer (Mistral) for the shared Swift client.

The Swift probe sends the synthetic key, keeps the client's own path and model
query, and names a scenario in a header.
"""
import base64
import hashlib
import json
import struct
import time

from loopback_wire import log, send_text

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


def verify_mistral_request(query, headers):
    """Checks the client's own query and synthetic credential, logging only verdicts."""
    scenario = headers.get("x-jsti-mistral-scenario")
    model_verified = query == f"model={MISTRAL_MODEL}"
    authorization_verified = headers.get("authorization") == MISTRAL_AUTHORIZATION
    log("mistral-handshake", scenario=scenario, modelVerified=model_verified,
        authorizationVerified=authorization_verified)
    if scenario not in MISTRAL_SCENARIOS or not model_verified or not authorization_verified:
        raise ValueError("unexpected Voxtral handshake")
    return scenario


class MistralPeer:
    """One Voxtral session on an upgraded connection."""

    def __init__(self, conn, scenario):
        self.conn = conn
        self.scenario = scenario
        self.fragmented = scenario == "fragment"

    def read_event(self):
        opcode, message = self.conn.read_message()
        if opcode != 1:
            raise ValueError("Voxtral client messages are JSON text")
        event = json.loads(message.decode("utf-8"))
        if not isinstance(event, dict) or not isinstance(event.get("type"), str):
            raise ValueError("Voxtral client message is not a typed JSON object")
        return event

    def send(self, event):
        send_text(self.conn, event, self.fragmented)

    def reject(self, reason):
        self.conn.send_frame(1, json.dumps({"type": "error", "error": {"message": reason, "code": 4000}}).encode())
        self.conn.send_frame(8, struct.pack("!H", 1008) + b"protocol")
        raise ValueError(reason)

    def run(self):
        """Plays one Voxtral session: created, update before any audio, exact
        PCM, flush then end, deltas and a revised done unless the scenario
        withholds the completion."""
        scenario = self.scenario
        deltas, done = MISTRAL_TEXT["fragment" if self.fragmented else "complete"]
        # Hold session.created briefly: audio captured meanwhile must wait.
        time.sleep(0.2)
        self.send({"type": "session.created", "session": {"request_id": "loopback", "model": MISTRAL_MODEL}})
        update = self.read_event()
        if update["type"] != "session.update":
            self.reject(f"{update['type']} before session.update")
        session = update.get("session") or {}
        if (session.get("audio_format") != {"encoding": "pcm_s16le", "sample_rate": 16000}
                or session.get("target_streaming_delay_ms") != 480 or "language" in json.dumps(update)):
            self.reject("unexpected session.update")
        log("mistral-session-update", scenario=scenario, verified=True)
        digest = hashlib.sha256()
        frames = 0
        flushed = False
        while True:
            event = self.read_event()
            kind = event["type"]
            if kind == "input_audio.append" and not flushed and frames < MISTRAL_FRAMES:
                audio = base64.b64decode(event.get("audio", ""), validate=True)
                if audio != mistral_pcm(frames):
                    self.reject(f"append {frames} changed in transport")
                digest.update(audio)
                frames += 1
                if frames == MISTRAL_HELD_FRAMES:
                    self.send({"type": "session.updated", "session": session})
                    self.send({"type": "transcription.language", "audio_language": "en"})
                    for delta in deltas:
                        self.send({"type": "transcription.text.delta", "text": delta})
            elif kind == "input_audio.flush" and not flushed and frames == MISTRAL_FRAMES:
                flushed = True
            elif kind == "input_audio.end" and flushed:
                break
            else:
                self.reject(f"unexpected {kind} after {frames} frames")
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
                self.conn.read_message()
        self.send({"type": "transcription.done", "model": MISTRAL_MODEL, "text": done,
                   "language": "en", "segments": [], "usage": {"prompt_audio_seconds": 2}})
        self.conn.send_frame(8, struct.pack("!H", 1000) + b"transcription-complete")
        log("mistral-done", scenario=scenario)

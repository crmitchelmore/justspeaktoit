"""Gemini, Meta, Modulate and Grok live-transcription peers for the shared Swift clients.

Each route is selected by the `x-jsti-provider` header at the provider's own
path; `x-jsti-provider-scenario` chooses a complete stream or an early server
close. The key is synthetic, and the query of these routes is never logged.
"""
import base64
import json
import select
import struct
import urllib.parse

from loopback_wire import log, send_text

ADDITIONAL_PROVIDER_PATHS = {
    "gemini": "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent",
    "meta": "/v1/asr/realtime",
    "modulate": "/api/velma-2-stt-streaming",
    "grok": "/v1/realtime",
}
ADDITIONAL_SCENARIOS = ("complete", "early")
ADDITIONAL_KEY = "synthetic-loopback-key"
ADDITIONAL_FRAMES = 3
ADDITIONAL_END = {
    "gemini": {"realtimeInput": {"audioStreamEnd": True}},
    "meta": {"type": "endStream"},
    "grok": {"type": "input_audio_buffer.commit"},
}


def accept_additional_provider(conn, provider, route, query, headers):
    """The peer for a marked additional-provider upgrade, or a ValueError."""
    scenario = headers.get("x-jsti-provider-scenario")
    if route != ADDITIONAL_PROVIDER_PATHS.get(provider) or scenario not in ADDITIONAL_SCENARIOS:
        raise ValueError("unexpected additional provider route/scenario")
    return AdditionalProviderPeer(conn, provider, scenario, urllib.parse.parse_qs(query), headers)


def require(condition):
    if not condition:
        raise ValueError("additional provider protocol mismatch")


class AdditionalProviderPeer:
    """One session: setup and readiness, three exact PCM frames, the provider's
    end of audio, then a final caption and the scenario's closure."""

    def __init__(self, conn, provider, scenario, query, headers):
        self.conn = conn
        self.provider = provider
        self.scenario = scenario
        self.query = query
        self.headers = headers
        self.rate = 24000 if provider in ("meta", "grok") else 16000

    def read_json(self):
        opcode, payload = self.conn.read_message()
        require(opcode == 1)
        return json.loads(payload)

    def send_json(self, event):
        send_text(self.conn, event, fragmented=True)

    def final(self, text, identity):
        if self.provider == "gemini":
            return {"serverContent": {"inputTranscription": {"text": text}}}
        if self.provider == "meta":
            return {"type": "speechComplete", "turnId": identity, "transcript": text}
        if self.provider == "modulate":
            return {"type": "utterance", "utterance": {"utterance_uuid": str(identity), "text": text}}
        return {"type": "conversation.item.input_audio_transcription.completed", "transcript": text}

    def ready_event(self):
        """Verifies the provider's setup; answers the event that admits audio, if any."""
        provider, query = self.provider, self.query
        if provider == "gemini":
            require(query.get("key") == [ADDITIONAL_KEY])
            setup = self.read_json()["setup"]
            require(setup["model"] == "models/gemini-3.5-transcribe-live")
            require(setup["generationConfig"] == {"responseModalities": ["TEXT"]})
            require(setup["inputAudioTranscription"]["mode"] == "VERBATIM")
            require(setup["realtimeInputConfig"]["automaticActivityDetection"]["disabled"] is False)
            return {"setupComplete": {}}
        if provider == "meta":
            require(len(query.get("sessionId", [])) == 1 and bool(query["sessionId"][0]))
            setup = self.read_json()
            require(setup["authorization"]["accessToken"] == ADDITIONAL_KEY)
            require(setup["model"] == "muse-voice-transcribe-1.0")
            require(setup["audioEncoding"] == "PCM_24KHZ" and setup["partialMode"] == "CUMULATIVE")
            return {"sessionId": "synthetic"}
        if provider == "grok":
            require(query.get("model") == ["grok-voice-3.0"])
            require(self.headers.get("authorization") == "Bearer " + ADDITIONAL_KEY)
            setup = self.read_json()
            require(setup["type"] == "session.update")
            session = setup["session"]
            require(session["turn_detection"] is None and session["reasoning"] == {"effort": "none"})
            require(session["audio"]["input"]["format"] == {"type": "audio/pcm", "rate": self.rate})
            require(session["audio"]["input"]["transcription"]["model"] == "grok-transcribe")
            return {"type": "session.updated"}
        require(query.get("api_key") == [ADDITIONAL_KEY])
        return None

    def read_frame_audio(self, index):
        """Frame `index`, unwrapped from the provider's framing."""
        opcode, payload = self.conn.read_message()
        rate = self.rate
        if self.provider in ("meta", "modulate"):
            require(opcode == 2)
            if self.provider == "modulate" and index == 0:
                require(payload[:4] == b"RIFF" and payload[8:12] == b"WAVE" and len(payload) == rate // 5 + 44)
                require(payload[12:16] == b"fmt " and payload[36:40] == b"data")
                require(struct.unpack("<HHI", payload[20:28]) == (1, 1, rate))
                require(struct.unpack("<IHH", payload[28:36]) == (rate * 2, 2, 16))
                payload = payload[44:]
            return payload
        require(opcode == 1)
        event = json.loads(payload)
        if self.provider == "gemini":
            audio = event["realtimeInput"]["audio"]
            require(audio["mimeType"] == "audio/pcm;rate=16000")
            encoded = audio["data"]
        else:
            require(event["type"] == "input_audio_buffer.append")
            encoded = event["audio"]
        return base64.b64decode(encoded, validate=True)

    def read_end(self):
        opcode, payload = self.conn.read_message()
        require(opcode == 1)
        if self.provider == "modulate":
            require(payload == b"")
        else:
            require(json.loads(payload) == ADDITIONAL_END[self.provider])

    def run(self):
        provider, rate = self.provider, self.rate
        ready = self.ready_event()
        if ready:
            # A setup send completion is not permission to stream PCM.
            require(not self.conn.pending and not select.select([self.conn.request], [], [], 0.05)[0])
            self.send_json(ready)
        for index in range(ADDITIONAL_FRAMES):
            expected = bytes((index * 31 + offset * 7) & 0xFF for offset in range(rate // 5))
            require(self.read_frame_audio(index) == expected)
        self.send_json(self.final("Before.", 1))
        self.read_end()
        log("additional-provider-audio", provider=provider, scenario=self.scenario,
            frames=ADDITIONAL_FRAMES, bytes=ADDITIONAL_FRAMES * rate // 5, endVerified=True)
        if self.scenario == "complete":
            self.send_json(self.final("Tail.", 2))
            if provider == "modulate":
                self.send_json({"type": "done", "duration_ms": 300})
        else:
            self.conn.send_frame(8, struct.pack("!H", 1000))
        # In particular, a Grok caption must never be followed by response.create.
        opcode, _ = self.conn.read_message(close_ends=False)
        require(opcode == 8)

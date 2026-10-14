"""Credential-free checks for the native additional-provider loopback peer."""
import base64
import importlib.util
import json
from pathlib import Path
import struct
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "websocket_peer", Path(__file__).resolve().parents[1] / "websocket-loopback-probe.py"
)
PEER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PEER)


class AdditionalProviderPeerTests(unittest.TestCase):
    def drive(self, provider, scenario="complete", corrupt_pcm=False, assistant_request=False):
        handler = PEER.ProbeHandler.__new__(PEER.ProbeHandler)
        handler.additional_provider = provider
        handler.additional_scenario = scenario
        handler.additional_query = {
            "key": ["synthetic-loopback-key"], "api_key": ["synthetic-loopback-key"],
            "sessionId": ["synthetic"], "model": ["grok-voice-think-fast-2.0"],
        }
        handler.additional_headers = {"authorization": "Bearer synthetic-loopback-key"}
        handler.pending = bytearray()
        rate = 24000 if provider in ("meta", "grok") else 16000
        incoming = []

        def text(event):
            incoming.append((1, json.dumps(event).encode()))

        if provider == "gemini":
            text({"setup": {
                "model": "models/gemini-3.5-transcribe-live",
                "generationConfig": {"responseModalities": ["TEXT"]},
                "inputAudioTranscription": {"mode": "VERBATIM"},
                "realtimeInputConfig": {"automaticActivityDetection": {"disabled": False}},
            }})
        elif provider == "meta":
            text({"authorization": {"accessToken": "synthetic-loopback-key"},
                  "model": "muse-voice-transcribe-1.0", "audioEncoding": "PCM_24KHZ", "partialMode": "CUMULATIVE"})
        elif provider == "grok":
            text({"type": "session.update", "session": {
                "turn_detection": None, "reasoning": {"effort": "none"},
                "audio": {"input": {"format": {"type": "audio/pcm", "rate": rate},
                                    "transcription": {"model": "grok-transcribe"}}},
            }})

        for index in range(3):
            pcm = bytes((index * 31 + offset * 7) & 0xFF for offset in range(rate // 5))
            if corrupt_pcm and index == 1:
                pcm = bytes(len(pcm))
            if provider == "modulate":
                if index == 0:
                    pcm = (b"RIFF" + struct.pack("<I", 0xFFFFFFFF) + b"WAVEfmt "
                           + struct.pack("<IHHIIHH", 16, 1, 1, rate, rate * 2, 2, 16)
                           + b"data" + struct.pack("<I", 0xFFFFFFFF) + pcm)
                incoming.append((2, pcm))
            elif provider == "meta":
                incoming.append((2, pcm))
            elif provider == "gemini":
                text({"realtimeInput": {"audio": {
                    "mimeType": "audio/pcm;rate=16000", "data": base64.b64encode(pcm).decode(),
                }}})
            else:
                text({"type": "input_audio_buffer.append", "audio": base64.b64encode(pcm).decode()})
        if assistant_request:
            text({"type": "response.create"})
        elif provider == "modulate":
            incoming.append((1, b""))
        elif provider == "gemini":
            text({"realtimeInput": {"audioStreamEnd": True}})
        else:
            text({"type": "endStream" if provider == "meta" else "input_audio_buffer.commit"})
        incoming.append((8, b""))
        frames = []
        handler.read_message = lambda **_: incoming.pop(0)
        handler.send_frame = lambda opcode, payload, **kwargs: frames.append((opcode, payload))
        handler.request = object()
        with patch.object(PEER.select, "select", return_value=([], [], [])), patch.object(PEER, "log") as log:
            handler.run_additional_provider()
            self.assertEqual(log.call_args.kwargs["frames"], 3)
            self.assertTrue(log.call_args.kwargs["endVerified"])
        return frames

    def test_complete_and_early_closure_for_every_protocol(self):
        for provider in ("gemini", "meta", "modulate", "grok"):
            for scenario in ("complete", "early"):
                with self.subTest(provider=provider, scenario=scenario):
                    frames = self.drive(provider, scenario)
                    self.assertEqual(any(opcode == 8 for opcode, _ in frames), scenario == "early")

    def test_pcm_corruption_is_never_accepted(self):
        for provider in ("gemini", "meta", "modulate", "grok"):
            with self.subTest(provider=provider), self.assertRaises(ValueError):
                self.drive(provider, corrupt_pcm=True)

    def test_grok_peer_rejects_assistant_generation(self):
        with self.assertRaises(ValueError):
            self.drive("grok", assistant_request=True)


if __name__ == "__main__":
    unittest.main()

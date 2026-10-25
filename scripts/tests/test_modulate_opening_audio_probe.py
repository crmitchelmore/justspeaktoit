"""Real loopback sockets prove the HTTP101 barrier and exact synthetic receipt."""
import base64
import http.client
import importlib.util
import json
import os
from pathlib import Path
import select
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import unittest
import uuid

SPEC = importlib.util.spec_from_file_location("modulate_opening", Path(__file__).resolve().parents[1] / "modulate-opening-audio-probe.py")
PEER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PEER)


def read_exact(sock, count):
    result = b""
    while len(result) < count:
        block = sock.recv(count - len(result))
        if not block:
            raise ConnectionError("closed")
        result += block
    return result


def send_frame(sock, opcode, payload):
    mask = b"test"
    size = len(payload)
    prefix = bytes([0x80 | opcode, 0x80 | size]) if size < 126 else bytes([0x80 | opcode, 0xFE]) + struct.pack("!H", size)
    sock.sendall(prefix + mask + bytes(value ^ mask[index % 4] for index, value in enumerate(payload)))


def read_frame(sock):
    first, length = read_exact(sock, 2)
    if length == 126:
        length = struct.unpack("!H", read_exact(sock, 2))[0]
    return first & 15, read_exact(sock, length)


class HeldModulatePeerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = PEER.OpeningServer(("127.0.0.1", 0))
        cls.port = cls.server.server_address[1]
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(2)

    def control(self, identifier, action, body=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        try:
            connection.request("GET" if action == "state" else "POST", f"/control/{identifier}/{action}",
                               body=json.dumps(body).encode() if body is not None else None,
                               headers={"X-JSTI-Probe": "local-only"})
            response = connection.getresponse()
            self.assertEqual(response.status, 200)
            return json.loads(response.read())
        finally:
            connection.close()

    def held(self, ids=(1, 2), ack_after=1):
        identifier = str(uuid.uuid4())
        self.control(identifier, "configure", {"ids": list(ids), "ackAfter": ack_after})
        sock = socket.create_connection(("127.0.0.1", self.port), timeout=2)
        self.addCleanup(sock.close)
        key = base64.b64encode(b"0123456789abcdef").decode()
        sock.sendall((f"GET {PEER.ROUTE}?api_key=synthetic-loopback-key HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                      "Connection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\n"
                      f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Protocol: jsti-probe\r\n"
                      f"X-JSTI-Probe: local-only\r\nX-JSTI-Opening-Session: {identifier}\r\n\r\n").encode())
        self.assertEqual(self.control(identifier, "await-held")["stage"], "held")
        self.assertFalse(select.select([sock], [], [], 0)[0], "no HTTP101 before explicit release")
        return identifier, sock

    def release(self, identifier, sock):
        self.control(identifier, "release")
        header = b""
        while not header.endswith(b"\r\n\r\n"):
            header += read_exact(sock, 1)
        self.assertTrue(header.startswith(b"HTTP/1.1 101 "))

    def test_real_held_upgrade_receives_exact_ordered_pcm_and_one_wav_header(self):
        identifier, sock = self.held()
        before = self.control(identifier, "state")
        self.assertEqual(before["receivedIDs"], [])
        self.assertFalse(before["upgradeComplete"])
        self.release(identifier, sock)
        send_frame(sock, 2, PEER.wav_header() + PEER.pcm(1))
        self.assertEqual(json.loads(read_frame(sock)[1])["type"], "utterance")
        send_frame(sock, 2, PEER.pcm(2))
        send_frame(sock, 1, b"")
        self.assertEqual(json.loads(read_frame(sock)[1]), {"type": "done"})
        receipt = self.control(identifier, "state")
        self.assertEqual(receipt["receivedIDs"], [1, 2])
        self.assertEqual(receipt["receivedPCMBytes"], 6400)
        self.assertEqual(receipt["wavHeaders"], 1)
        self.assertTrue(receipt["endVerified"])

    def test_transport_failure_is_distinct_from_a_held_upgrade(self):
        identifier, sock = self.held()
        self.control(identifier, "fail")
        self.assertTrue(sock.recv(4096).startswith(b"HTTP/1.1 503 "))
        receipt = self.control(identifier, "state")
        self.assertFalse(receipt["upgradeComplete"])
        self.assertEqual(receipt["receivedIDs"], [])
        self.assertEqual(receipt["stage"], "failed")

    def test_corruption_order_duplicates_extra_wav_and_early_end_are_rejected(self):
        for scenario in ("corrupt", "order", "duplicate", "header", "early-end"):
            with self.subTest(scenario=scenario):
                identifier, sock = self.held()
                self.release(identifier, sock)
                if scenario == "corrupt":
                    send_frame(sock, 2, PEER.wav_header() + bytes(3200))
                elif scenario == "order":
                    send_frame(sock, 2, PEER.wav_header() + PEER.pcm(2))
                elif scenario == "early-end":
                    send_frame(sock, 1, b"")
                else:
                    send_frame(sock, 2, PEER.wav_header() + PEER.pcm(1))
                    read_frame(sock)
                    send_frame(sock, 2, PEER.pcm(1) if scenario == "duplicate" else PEER.wav_header() + PEER.pcm(2))
                self.assertEqual(sock.recv(4096), b"")
                self.assertEqual(self.control(identifier, "state")["stage"], "failed")
                sock.close()

    def test_cancelled_old_upgrade_cannot_receive_replacement_session_audio(self):
        old, old_socket = self.held(ids=(3000,))
        old_socket.close()
        current, current_socket = self.held(ids=(3100,))
        self.control(old, "release")
        self.assertEqual(self.control(old, "await-ended")["stage"], "failed")
        self.release(current, current_socket)
        send_frame(current_socket, 2, PEER.wav_header() + PEER.pcm(3100))
        read_frame(current_socket)
        send_frame(current_socket, 1, b"")
        self.assertEqual(json.loads(read_frame(current_socket)[1]), {"type": "done"})
        self.assertEqual(self.control(old, "state")["receivedIDs"], [])
        self.assertEqual(self.control(current, "state")["receivedIDs"], [3100])

    def test_configuration_is_bounded_and_cannot_accept_duplicate_ids(self):
        for ids, ack in (([], 1), ([1, 1], 1), (list(range(33)), 1), ([1], 0), ([True], 1)):
            with self.subTest(ids=ids, ack=ack), self.assertRaises(ValueError):
                PEER.OpeningSession(ids, ack)


RUNNER_SPEC = importlib.util.spec_from_file_location(
    "modulate_runner", Path(__file__).resolve().parents[1] / "qualify-modulate-opening-audio.py")
RUNNER = importlib.util.module_from_spec(RUNNER_SPEC)
RUNNER_SPEC.loader.exec_module(RUNNER)
# This contract lists the four semantic scenarios independently of runner code.
CASES = (
    "testHeldHTTP101PreservesOpeningAndLivePCMExactlyOnceInCaptureOrder",
    "testPrestartPrerollIsSeparateAndPostStopAudioDoesNotLeakIntoRestart",
    "testFailedHeldUpgradeReportsTransportFailureAndClearsPendingAudioBeforeRestart",
    "testStopDuringHeldUpgradeSeparatesRestartFromLateOldUpgrade",
)
VALID_OUTPUT = "".join(f"Test Case '-[SpeakPortableTests.ModulateOpeningAudioQualificationTests {name}]' passed (0.01 seconds).\n"
                       for name in CASES)


class OwnedRunnerTests(unittest.TestCase):
    def test_exact_four_cases_reject_skip_fail_duplicate_missing_wrong_filter_and_fake_zero(self):
        self.assertEqual(RUNNER.qualification(VALID_OUTPUT)[0], [])
        for output in ("", "Test Suite passed. Executed 0 tests.\n", "4 tests passed.\n",
                       VALID_OUTPUT.replace("passed", "skipped", 1), VALID_OUTPUT.replace("passed", "failed", 1),
                       VALID_OUTPUT + VALID_OUTPUT.splitlines()[0] + "\n", "\n".join(VALID_OUTPUT.splitlines()[1:]),
                       VALID_OUTPUT.replace("ModulateOpeningAudioQualificationTests", "WrongFilterTests")):
            with self.subTest(output=output):
                self.assertTrue(RUNNER.qualification(output)[0])

    def test_runner_reaps_owned_peer_and_command_and_preserves_nonzero_and_timeout(self):
        runner = Path(__file__).resolve().parents[1] / "qualify-modulate-opening-audio.py"
        with tempfile.TemporaryDirectory(prefix="modulate-owned-runner-") as directory:
            for scenario, expected in (("pass", 0), ("timeout", 124), ("fake-zero", 1), ("failed-command", 7)):
                output = Path(directory) / scenario
                pid_file = Path(directory) / f"child-{scenario}.pid"
                result_text = "Test Suite passed. Executed 0 tests." if scenario == "fake-zero" else VALID_OUTPUT
                ending = "time.sleep(30)" if scenario == "timeout" else f"sys.exit({7 if scenario == 'failed-command' else 0})"
                code = ("import os,pathlib,sys,time; "
                        "assert int(os.environ['JSTI_MODULATE_OPENING_PROBE_PORT']) > 0; "
                        "pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); "
                        f"print({result_text!r}, flush=True); " + ending)
                result = subprocess.run([sys.executable, "-B", str(runner), "--output-dir", str(output),
                                         "--test-timeout", "1", "--", sys.executable, "-B", "-c", code, str(pid_file)],
                                        capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode, expected, result.stderr)
                receipt = json.loads((output / "qualification.json").read_text())
                self.assertEqual(receipt["qualificationExitCode"], expected)
                self.assertEqual(receipt["commandExitCode"], expected if scenario != "fake-zero" else 0)
                with self.assertRaises(ProcessLookupError):
                    os.kill(int(pid_file.read_text()), 0)
                port = json.loads((output / "peer-ready.json").read_text())["port"]
                with socket.socket() as probe:
                    probe.settimeout(1)
                    self.assertNotEqual(probe.connect_ex(("127.0.0.1", port)), 0, "owned peer must be gone")


if __name__ == "__main__":
    unittest.main()

import importlib.util
import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest.mock import Mock, patch
import urllib.error
import urllib.request


SPEC = importlib.util.spec_from_file_location(
    "azure_speech_proxy", Path(__file__).resolve().parents[1] / "azure-speech-proxy.py",
)
proxy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(proxy)

SSML = b"""<speak xmlns="http://www.w3.org/2001/10/synthesis">
<voice name="en-US-Harper:MAI-Voice-2.1">Test.</voice></speak>"""


class FakeTransport:
    def __init__(self):
        self.calls = []

    def forward(self, method, path, body, output_format):
        self.calls.append((method, path, body, output_format))
        return 200, "audio/wav", b"RIFFtestWAVE"


class ProxyTests(unittest.TestCase):
    def setUp(self):
        self.transport = FakeTransport()
        self.token = "test-only-token"
        self.server = proxy.ProxyServer(0, self.token, self.transport)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.origin = "http://127.0.0.1:%d" % self.server.server_port

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def request(self, path="/cognitiveservices/v1", body=SSML, extra=None):
        headers = {
            "Ocp-Apim-Subscription-Key": self.token,
            "Content-Type": "application/ssml+xml",
            "X-Microsoft-OutputFormat": "riff-24khz-16bit-mono-pcm",
        }
        headers.update(extra or {})
        request = urllib.request.Request(self.origin + path, data=body, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                return response.status, response.read()
        except urllib.error.HTTPError as error:
            with error:
                return error.code, error.read()

    def test_synthesis_preserves_azure_contract(self):
        self.assertEqual(self.request()[0], 200)
        self.assertEqual(self.transport.calls, [
            ("POST", "/tts/cognitiveservices/v1", SSML, "riff-24khz-16bit-mono-pcm"),
        ])

    def test_voice_list_and_health(self):
        self.assertEqual(self.request("/cognitiveservices/voices/list", body=None)[0], 200)
        self.assertEqual(self.transport.calls[0][1], "/tts/cognitiveservices/voices/list")
        status, data = self.request("/health", body=None)
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(data)["scope"], "tts-only")

    def test_wrong_token_is_rejected(self):
        for token in ("wrong", "\u00e9"):
            self.assertEqual(self.request(extra={"Ocp-Apim-Subscription-Key": token})[0], 401)
        self.assertFalse(self.transport.calls)

    def test_browser_and_rebound_host_are_rejected(self):
        for headers in ({"Origin": "https://example.com"}, {"Sec-Fetch-Site": "same-origin"},
                        {"Host": "example.com"}, {"Host": "localhost"}):
            with self.subTest(headers=headers):
                self.assertEqual(self.request(extra=headers)[0], 403)
        self.assertFalse(self.transport.calls)

    def test_no_arbitrary_forwarding(self):
        for path in ("/", "/cognitiveservices/v1?url=https://example.com",
                     "/speechtotext/transcriptions:transcribe", "/tts/cognitiveservices/v1"):
            with self.subTest(path=path):
                self.assertEqual(self.request(path)[0], 404)
        self.assertFalse(self.transport.calls)

    def test_invalid_or_external_ssml_is_rejected(self):
        bodies = [b"invalid", b"", b"<speak>wrong namespace</speak>",
                  b'<!DOCTYPE speak [<!ENTITY x "hello">]>' + SSML,
                  SSML.replace(b"Test.", b'<audio src="https://example.com/a.wav"/>'),
                  SSML.replace(b"Test.", b'<lexicon uri="https://example.com/lexicon"/>')]
        for body in bodies:
            with self.subTest(body=body):
                self.assertEqual(self.request(body=body)[0], 400)
        self.assertFalse(self.transport.calls)

    def test_body_and_format_limits(self):
        self.assertEqual(self.request(body=b"x" * (proxy.MAX_REQUEST + 1))[0], 413)
        self.assertEqual(self.request(extra={"X-Microsoft-OutputFormat": "unknown"})[0], 400)
        self.assertEqual(self.request(extra={"Transfer-Encoding": "chunked"})[0], 400)
        self.assertFalse(self.transport.calls)

    def test_upstream_error_is_explicit(self):
        with patch.object(self.transport, "forward", side_effect=proxy.ProxyError(503, "Run az login.")):
            status, data = self.request()
        self.assertEqual(status, 503)
        self.assertIn("az login", json.loads(data)["error"])


class ConfigurationTests(unittest.TestCase):
    def test_only_fixed_azure_https_origins(self):
        for host in ("test.cognitiveservices.azure.com", "test.services.ai.azure.com"):
            self.assertEqual(proxy.resource_origin("https://" + host + "/"), "https://" + host)
        for value in ("http://test.cognitiveservices.azure.com", "https://example.com",
                      "https://test.cognitiveservices.azure.com:443",
                      "https://test.cognitiveservices.azure.com/path",
                      "https://test.cognitiveservices.azure.com?key=secret",
                      "https://user@test.cognitiveservices.azure.com"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                proxy.resource_origin(value)

    def test_token_file_is_private_and_reused(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "token"
            token = proxy.local_token(path)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(proxy.local_token(path), token)
            path.chmod(0o644)
            with self.assertRaises(ValueError):
                proxy.local_token(path)

    def test_token_symlink_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "target"
            proxy.local_token(target)
            link = Path(directory) / "link"
            link.symlink_to(target)
            with self.assertRaises(OSError):
                proxy.local_token(link)

    def test_cli_tokens_are_cached_and_refreshed(self):
        tokens = proxy.AzureCLIToken("subscription", "/test/az")
        result = type("Result", (), {"returncode": 0, "stdout": json.dumps({
            "accessToken": "synthetic-entra-token", "expires_on": time.time() + 3600,
        })})()
        with patch.object(proxy.subprocess, "run", return_value=result) as run:
            self.assertEqual(tokens.get(), "synthetic-entra-token")
            self.assertEqual(tokens.get(), "synthetic-entra-token")
            self.assertEqual(run.call_count, 1)
            tokens.expires = time.time()
            tokens.get()
            self.assertEqual(run.call_count, 2)
            self.assertIn("https://cognitiveservices.azure.com/", run.call_args.args[0])

    def test_sign_in_errors_do_not_expose_cli_output(self):
        result = type("Result", (), {"returncode": 1, "stdout": "secret", "stderr": "secret"})()
        with patch.object(proxy.subprocess, "run", return_value=result):
            with self.assertRaises(proxy.ProxyError) as caught:
                proxy.AzureCLIToken("subscription", "/test/az").get()
        self.assertEqual(caught.exception.status, 503)
        self.assertNotIn("secret", str(caught.exception))


class TransportTests(unittest.TestCase):
    def setUp(self):
        self.tokens = Mock()
        self.tokens.get.side_effect = ["old-token", "new-token"]
        self.transport = proxy.AzureTransport("https://test.cognitiveservices.azure.com", self.tokens)
        self.transport.opener = Mock()

    def error(self, status):
        return urllib.error.HTTPError(
            "https://test.cognitiveservices.azure.com", status, "Not logged", {}, None,
        )

    def response(self, data=b"RIFFtestWAVE"):
        response = Mock()
        response.status = 200
        response.headers = {"Content-Type": "audio/wav"}
        response.read.return_value = data
        response.__enter__ = Mock(return_value=response)
        response.__exit__ = Mock(return_value=False)
        return response

    def test_azure_receives_only_entra_credentials_and_fixed_target(self):
        self.transport.opener.open.return_value = self.response()
        self.transport.forward("POST", "/tts/cognitiveservices/v1", SSML, "riff-24khz-16bit-mono-pcm")
        request = self.transport.opener.open.call_args.args[0]
        self.assertEqual(request.full_url, "https://test.cognitiveservices.azure.com/tts/cognitiveservices/v1")
        self.assertEqual(request.get_header("Authorization"), "Bearer old-token")
        self.assertIsNone(request.get_header("Ocp-apim-subscription-key"))
        self.assertEqual(request.data, SSML)

    def test_401_refreshes_once(self):
        self.transport.opener.open.side_effect = [self.error(401), self.response()]
        self.assertEqual(self.transport.forward("GET", "/tts/cognitiveservices/voices/list", b"", None)[0], 200)
        self.tokens.invalidate.assert_called_once_with("old-token")
        request = self.transport.opener.open.call_args.args[0]
        self.assertEqual(request.get_header("Authorization"), "Bearer new-token")

    def test_persistent_access_failure_is_not_hidden(self):
        self.transport.opener.open.side_effect = [self.error(401), self.error(401)]
        with self.assertRaises(proxy.ProxyError) as caught:
            self.transport.forward("GET", "/tts/cognitiveservices/voices/list", b"", None)
        self.assertEqual(caught.exception.status, 401)
        self.assertEqual(self.transport.opener.open.call_count, 2)

    def test_redirect_is_refused(self):
        self.transport.opener.open.side_effect = self.error(302)
        with self.assertRaises(proxy.ProxyError) as caught:
            self.transport.forward("GET", "/tts/cognitiveservices/voices/list", b"", None)
        self.assertEqual(caught.exception.status, 502)
        self.assertIsNone(proxy.NoRedirects().redirect_request(
            None, None, 302, "", {}, "https://example.com",
        ))

    def test_rate_limit_is_preserved(self):
        self.transport.opener.open.side_effect = self.error(429)
        with self.assertRaises(proxy.ProxyError) as caught:
            self.transport.forward("GET", "/tts/cognitiveservices/voices/list", b"", None)
        self.assertEqual(caught.exception.status, 429)

    def test_empty_and_oversized_responses_fail(self):
        for data in (b"", b"x" * 11):
            self.tokens.get.side_effect = None
            self.tokens.get.return_value = "synthetic"
            self.transport.opener.open.return_value = self.response(data)
            with self.subTest(data=data), patch.object(proxy, "MAX_RESPONSE", 10):
                with self.assertRaises(proxy.ProxyError) as caught:
                    self.transport.forward("GET", "/tts/cognitiveservices/voices/list", b"", None)
                self.assertEqual(caught.exception.status, 502)


if __name__ == "__main__":
    unittest.main()

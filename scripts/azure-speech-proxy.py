#!/usr/bin/env python3
"""Loopback-only Azure batch/live transcription and TTS bridge using Azure CLI sign-in."""

import argparse
import base64
from email import policy
from email.parser import BytesParser
import hashlib
import hmac
import http.client
import io
import http.server
import json
import os
from pathlib import Path
import re
import secrets
import select
import shutil
import socket
import ssl
import stat
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET


MAX_REQUEST = 64 * 1024
MAX_TRANSCRIPTION_REQUEST = 32 * 1024 * 1024
MAX_RESPONSE = 32 * 1024 * 1024
MAX_UPLOAD_SECONDS = 30
MAX_RESPONSE_SECONDS = 180
TRANSCRIPTION_PATH = "/speechtotext/transcriptions:transcribe?api-version=2025-10-15"
STREAMING_PATH = "/voice-live/realtime?api-version=2026-04-10&model=gpt-4.1"
MAX_STREAM_SECONDS = 3600
MAX_STREAM_UPLOAD = 256 * 1024 * 1024
MAX_STREAM_DOWNLOAD = 64 * 1024 * 1024
WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
ROUTES = {
    ("POST", "/cognitiveservices/v1"): "/tts/cognitiveservices/v1",
    ("GET", "/cognitiveservices/voices/list"): "/tts/cognitiveservices/voices/list",
    ("POST", TRANSCRIPTION_PATH): TRANSCRIPTION_PATH,
}
FORMATS = {
    "riff-24khz-16bit-mono-pcm", "riff-48khz-16bit-mono-pcm",
    "audio-24khz-48kbitrate-mono-mp3", "audio-24khz-96kbitrate-mono-mp3",
    "audio-24khz-160kbitrate-mono-mp3", "audio-48khz-192kbitrate-mono-mp3",
}


class ProxyError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


def resource_origin(value):
    parsed = urllib.parse.urlsplit(value)
    if (parsed.scheme != "https" or parsed.username or parsed.password
            or parsed.netloc != parsed.hostname or parsed.path not in ("", "/")
            or parsed.query or parsed.fragment or not parsed.hostname
            or not re.fullmatch(
                r"[a-z0-9][a-z0-9-]{0,62}\.(?:cognitiveservices|services\.ai)\.azure\.com",
                parsed.hostname)):
        raise ValueError("Use a custom Azure HTTPS resource origin, without a path or port.")
    return value.rstrip("/")


def local_token(path):
    """Reuse a private token file; never follow a symlink or overwrite a file."""
    path = Path(path)
    flags = os.O_RDWR | os.O_CREAT | os.O_EXCL
    try:
        fd = os.open(path, flags, 0o600)
    except FileExistsError:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, "r") as stream:
            info = os.fstat(stream.fileno())
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                    or info.st_mode & 0o077):
                raise ValueError("The local token must be an owner-only regular file (chmod 600).")
            token = stream.read(129).strip()
            if not re.fullmatch(r"[A-Za-z0-9_-]{43,128}", token):
                raise ValueError("The local token file is invalid.")
            return token
    else:
        token = secrets.token_urlsafe(32)
        with os.fdopen(fd, "w") as stream:
            stream.write(token + "\n")
        return token


class AzureCLIToken:
    def __init__(self, subscription, executable):
        self.subscription = subscription
        self.executable = executable
        self.lock = threading.Lock()
        self.value = ""
        self.expires = 0

    def get(self):
        with self.lock:
            if self.value and time.time() < self.expires - 120:
                return self.value
            try:
                result = subprocess.run(
                    [self.executable, "account", "get-access-token", "--subscription",
                     self.subscription, "--resource", "https://cognitiveservices.azure.com/",
                     "--output", "json"],
                    capture_output=True, text=True, timeout=30, check=False,
                )
            except (OSError, subprocess.TimeoutExpired) as error:
                raise ProxyError(503, "Azure CLI token retrieval failed or timed out.") from error
            if result.returncode:
                raise ProxyError(503, "Azure sign-in is unavailable. Run az login, then retry.")
            try:
                payload = json.loads(result.stdout)
                token = payload["accessToken"]
                expires = float(payload["expires_on"])
                if not isinstance(token, str) or not token or expires <= time.time() + 120:
                    raise ValueError("Invalid token lifetime")
            except (ValueError, KeyError, TypeError) as error:
                raise ProxyError(503, "Azure CLI returned an invalid or expired token.") from error
            self.value, self.expires = token, expires
            return token

    def invalidate(self, value):
        with self.lock:
            if self.value == value:
                self.value, self.expires = "", 0


class NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file, code, message, headers, new_url):
        return None


def bounded_response(response):
    expired = threading.Event()
    # Closing HTTPResponse can wait on its buffered-reader lock. Shut down the
    # underlying stdlib socket instead, so the deadline interrupts a blocked read.
    connection = response.fp.raw._sock

    def expire():
        expired.set()
        try:
            connection.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass  # The peer may have already closed the socket.

    timer = threading.Timer(MAX_RESPONSE_SECONDS, expire)
    timer.daemon = True
    timer.start()
    try:
        data = response.read(MAX_RESPONSE + 1)
        if expired.is_set():
            raise ProxyError(504, "Azure response deadline reached.")
        return data
    except (OSError, http.client.HTTPException) as error:
        if expired.is_set():
            raise ProxyError(504, "Azure response deadline reached.") from error
        raise
    finally:
        timer.cancel()


def websocket_accept(key):
    return base64.b64encode(hashlib.sha1((key + WEBSOCKET_GUID).encode("ascii")).digest()).decode("ascii")


def read_upgrade(socket):
    data = bytearray()
    deadline = time.monotonic() + 10
    while not data.endswith(b"\r\n\r\n"):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise ProxyError(504, "Azure WebSocket handshake timed out.")
        socket.settimeout(remaining)
        chunk = socket.recv(1)
        if not chunk or len(data) >= 16 * 1024:
            raise ProxyError(502, "Azure WebSocket handshake was invalid or too large.")
        data.extend(chunk)
    first, _, rest = bytes(data).partition(b"\r\n")
    pieces = first.split()
    if len(pieces) < 2 or pieces[0] != b"HTTP/1.1" or not pieces[1].isdigit():
        raise ProxyError(502, "Azure WebSocket handshake was invalid.")
    headers = http.client.parse_headers(io.BytesIO(rest))
    return int(pieces[1]), headers


def relay_websocket(client, upstream):
    """Opaque RFC6455 relay: masks, frames, fragments and close handshakes stay intact."""
    client.settimeout(5)
    upstream.settimeout(5)
    started = time.monotonic()
    last_activity = started
    counts = {client: 0, upstream: 0}
    limits = {client: MAX_STREAM_UPLOAD, upstream: MAX_STREAM_DOWNLOAD}
    while True:
        now = time.monotonic()
        if now - started >= MAX_STREAM_SECONDS or now - last_activity >= 60:
            raise ProxyError(504, "Streaming session duration or idle limit reached.")
        # TLS may already have decrypted bytes even when its descriptor isn't readable.
        readable = [upstream] if upstream.pending() else []
        ready, _, _ = select.select([client, upstream], [], [], 0 if readable else 1)
        for source in set(readable + ready):
            chunk = source.recv(64 * 1024)
            if not chunk:
                return
            counts[source] += len(chunk)
            if counts[source] > limits[source]:
                raise ProxyError(413, "Streaming session byte limit reached.")
            destination = upstream if source is client else client
            destination.sendall(chunk)
            last_activity = time.monotonic()


def validate_transcription(body, content_type):
    if not re.fullmatch(r"multipart/form-data;\s*boundary=[A-Za-z0-9_-]{1,70}", content_type):
        raise ProxyError(415, "Use multipart/form-data with an unquoted boundary.")
    message = BytesParser(policy=policy.default).parsebytes(
        ("Content-Type: " + content_type + "\r\nMIME-Version: 1.0\r\n\r\n").encode("ascii") + body,
    )
    if not message.is_multipart() or message.defects:
        raise ProxyError(400, "Invalid multipart transcription body.")
    parts = {}
    for part in message.iter_parts():
        name = part.get_param("name", header="content-disposition")
        if (name not in ("audio", "definition") or name in parts or part.is_multipart()
                or part.defects or part.get_content_disposition() != "form-data"
                or part.get("Content-Transfer-Encoding") is not None):
            raise ProxyError(400, "Upload exactly one audio and one definition part.")
        parts[name] = part
    if set(parts) != {"audio", "definition"}:
        raise ProxyError(400, "Upload exactly one audio and one definition part.")
    audio = parts["audio"].get_payload(decode=True) or b""
    if len(audio) <= 44 or audio[:4] != b"RIFF" or audio[8:12] != b"WAVE":
        raise ProxyError(400, "Upload recorded WAV audio, not an audio URL.")
    definition_bytes = parts["definition"].get_payload(decode=True) or b""
    if len(definition_bytes) > MAX_REQUEST:
        raise ProxyError(413, "Transcription definition exceeds the local proxy limit.")
    try:
        definition = json.loads(definition_bytes)
    except (ValueError, UnicodeDecodeError) as error:
        raise ProxyError(400, "Invalid transcription definition JSON.") from error
    if not isinstance(definition, dict) or set(definition) - {"enhancedMode", "locales", "phraseList"}:
        raise ProxyError(400, "Unsupported transcription definition options.")
    enhanced = definition.get("enhancedMode")
    if enhanced is not None and (
            not isinstance(enhanced, dict) or set(enhanced) != {"enabled", "model"}
            or enhanced["enabled"] is not True
            or enhanced["model"] not in ("MAI-Transcribe-2", "MAI-Transcribe-1.5")):
        raise ProxyError(400, "Choose MAI-Transcribe-2, MAI-Transcribe-1.5, or Fast Transcription.")
    locales = definition.get("locales", [])
    if not isinstance(locales, list) or len(locales) > 10 or any(
            not isinstance(locale, str) or not re.fullmatch(r"[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*", locale)
            for locale in locales):
        raise ProxyError(400, "Invalid transcription locales.")
    phrase_list = definition.get("phraseList", {"phrases": []})
    if not isinstance(phrase_list, dict) or set(phrase_list) != {"phrases"}:
        raise ProxyError(400, "Invalid transcription phrase list.")
    phrases = phrase_list["phrases"]
    if not isinstance(phrases, list) or len(phrases) > 100 or any(
            not isinstance(phrase, str) or not phrase or len(phrase) > 1024 for phrase in phrases):
        raise ProxyError(400, "Invalid transcription phrases.")


class AzureTransport:
    def __init__(self, origin, tokens):
        self.origin = resource_origin(origin)
        self.tokens = tokens
        context = ssl.create_default_context()
        if sys.platform == "darwin":
            context.load_verify_locations(cafile="/etc/ssl/cert.pem")
        self.ssl_context = context
        # Ignore environment proxy settings: credentials go directly to the fixed Azure origin.
        self.opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}), NoRedirects(),
            urllib.request.HTTPSHandler(context=context),
        )

    def open_streaming(self, key):
        # Voice Live uses the Foundry host for the same fixed custom-resource name.
        host = urllib.parse.urlsplit(self.origin).hostname.replace(
            ".cognitiveservices.azure.com", ".services.ai.azure.com",
        )
        for attempt in range(2):
            token = self.tokens.get()
            upstream = None
            try:
                raw = socket.create_connection((host, 443), timeout=10)
                try:
                    upstream = self.ssl_context.wrap_socket(raw, server_hostname=host)
                except (OSError, ValueError):
                    raw.close()
                    raise
                request = (
                    "GET " + STREAMING_PATH + " HTTP/1.1\r\nHost: " + host
                    + "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13"
                    + "\r\nSec-WebSocket-Key: " + key + "\r\nAuthorization: Bearer " + token
                    + "\r\nUser-Agent: JustSpeakLocalProxy\r\n\r\n"
                )
                upstream.sendall(request.encode("ascii"))
                status, headers = read_upgrade(upstream)
                if status == 401 and attempt == 0:
                    upstream.close()
                    upstream = None
                    self.tokens.invalidate(token)
                    continue
                if status in (401, 403):
                    raise ProxyError(status, "Azure denied streaming access. Check sign-in and Speech permissions.")
                if status == 429:
                    raise ProxyError(429, "Azure Voice Live rate limit or quota reached.")
                if (status != 101 or headers.get("Upgrade", "").lower() != "websocket"
                        or "upgrade" not in [value.strip().lower()
                                             for value in headers.get("Connection", "").split(",")]
                        or headers.get_all("Sec-WebSocket-Accept") != [websocket_accept(key)]
                        or headers.get("Sec-WebSocket-Extensions") is not None
                        or headers.get("Sec-WebSocket-Protocol") is not None):
                    raise ProxyError(502, "Azure WebSocket upgrade was refused or invalid.")
                return upstream
            except (OSError, ValueError, http.client.HTTPException) as error:
                if upstream is not None:
                    upstream.close()
                raise ProxyError(502, "Azure WebSocket connection failed or timed out.") from error
            except ProxyError:
                if upstream is not None:
                    upstream.close()
                raise

    def forward(self, method, path, body, output_format, content_type=None):
        for attempt in range(2):
            token = self.tokens.get()
            headers = {"Authorization": "Bearer " + token, "User-Agent": "JustSpeakLocalProxy"}
            if method == "POST":
                headers["Content-Type"] = content_type or "application/ssml+xml"
                if output_format is not None:
                    headers["X-Microsoft-OutputFormat"] = output_format
            request = urllib.request.Request(
                self.origin + path, data=body if method == "POST" else None,
                headers=headers, method=method,
            )
            try:
                with self.opener.open(request, timeout=180) as response:
                    data = bounded_response(response)
                    if len(data) > MAX_RESPONSE:
                        raise ProxyError(502, "Azure response exceeds the local proxy limit.")
                    if not data:
                        raise ProxyError(502, "Azure returned an empty response.")
                    return response.status, response.headers.get("Content-Type", "application/octet-stream"), data
            except urllib.error.HTTPError as error:
                error.close()
                if error.code == 401 and attempt == 0:
                    self.tokens.invalidate(token)
                    continue
                if error.code in (401, 403):
                    raise ProxyError(error.code, "Azure denied access. Check sign-in and the Speech User role.")
                if error.code == 429:
                    raise ProxyError(429, "Azure Speech rate limit or quota reached.")
                if 300 <= error.code < 400:
                    raise ProxyError(502, "Azure redirect refused.")
                status = error.code if error.code in (400, 404, 413, 415, 422) else 502
                raise ProxyError(status, "Azure Speech rejected the request (HTTP %d)." % error.code)
            except (urllib.error.URLError, TimeoutError, OSError) as error:
                raise ProxyError(502, "Azure Speech connection failed or timed out.") from error


class ProxyServer(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, port, token, transport):
        self.token = token
        self.transport = transport
        self.slots = threading.BoundedSemaphore(4)
        super().__init__(("127.0.0.1", port), ProxyHandler)

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            try:
                request.settimeout(0.05)
                request.sendall(
                    b"HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n"
                    b"Connection: close\r\nRetry-After: 1\r\n\r\n"
                )
            except OSError:
                pass
            finally:
                request.close()
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()

    def handle_error(self, request, client_address):
        print("Local proxy request failed.", file=sys.stderr, flush=True)


class ProxyHandler(http.server.BaseHTTPRequestHandler):
    # No read-ahead: after HTTP upgrade the relay reads directly from the socket.
    rbufsize = 0

    def setup(self):
        self.request.settimeout(15)
        super().setup()

    def log_message(self, *args):
        pass

    def send_error(self, code, message=None, explain=None):
        self.respond(code, "application/json", json.dumps({"error": "Invalid HTTP request."}).encode())

    def respond(self, status, content_type, body):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def do_GET(self):
        self.handle_proxy()

    def do_POST(self):
        self.handle_proxy()

    def handle_proxy(self):
        try:
            host = "127.0.0.1:%d" % self.server.server_port
            if self.headers.get_all("Host") != [host]:
                raise ProxyError(403, "Only the exact loopback host is accepted.")
            if self.headers.get("Origin") is not None or self.headers.get("Sec-Fetch-Site") is not None:
                raise ProxyError(403, "Browser requests are not supported.")
            streaming = self.command == "GET" and self.path == STREAMING_PATH
            header = "api-key" if streaming else "Ocp-Apim-Subscription-Key"
            supplied = self.headers.get_all(header) or []
            if len(supplied) != 1 or not hmac.compare_digest(
                    supplied[0].encode("utf-8"), self.server.token.encode("utf-8")):
                raise ProxyError(401, "A local proxy token is required; this is not an Azure API key.")
            if self.headers.get("Transfer-Encoding") is not None:
                raise ProxyError(400, "Transfer-Encoding is not supported.")
            lengths = self.headers.get_all("Content-Length") or []
            if len(lengths) > 1 or (lengths and not re.fullmatch(r"[0-9]{1,8}", lengths[0])):
                raise ProxyError(400, "Invalid Content-Length.")
            length = int(lengths[0]) if lengths else 0
            transcription = self.command == "POST" and self.path == TRANSCRIPTION_PATH
            limit = MAX_TRANSCRIPTION_REQUEST if transcription else MAX_REQUEST
            if length > limit:
                raise ProxyError(413, "Request body exceeds the local proxy limit.")
            if self.command == "GET" and length:
                raise ProxyError(400, "GET requests must not carry a body.")
            if streaming:
                self.handle_streaming()
                return
            if self.command == "GET" and self.path == "/health":
                self.respond(200, "application/json",
                             b'{"status":"ready","scope":"batch-transcription-and-tts","streaming":"voice-live"}')
                return
            upstream = ROUTES.get((self.command, self.path))
            if upstream is None:
                raise ProxyError(404, "Only batch transcription, synthesis and voice listing are supported.")
            body, output_format = b"", None
            content_type = None
            if self.command == "POST":
                chunks = bytearray()
                deadline = time.monotonic() + MAX_UPLOAD_SECONDS
                while len(chunks) < length:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise ProxyError(408, "Upload deadline reached.")
                    self.connection.settimeout(min(15, remaining))
                    chunk = self.rfile.read(min(64 * 1024, length - len(chunks)))
                    if not chunk:
                        break
                    chunks.extend(chunk)
                if time.monotonic() >= deadline:
                    raise ProxyError(408, "Upload deadline reached.")
                body = bytes(chunks)
                if len(body) != length or not body:
                    raise ProxyError(400, "A complete request body is required.")
            if transcription:
                content_type = self.headers.get("Content-Type", "")
                validate_transcription(body, content_type)
            elif self.command == "POST":
                if self.headers.get("Content-Type", "").split(";")[0].strip() != "application/ssml+xml":
                    raise ProxyError(415, "Use application/ssml+xml.")
                output_format = self.headers.get("X-Microsoft-OutputFormat")
                if output_format not in FORMATS:
                    raise ProxyError(400, "Unsupported audio output format.")
                if b"<!DOCTYPE" in body.upper() or b"<!ENTITY" in body.upper():
                    raise ProxyError(400, "XML declarations of entities or doctypes are not supported.")
                try:
                    text = body.decode("utf-8")
                    root = ET.fromstring(text)
                except (UnicodeDecodeError, ET.ParseError) as error:
                    raise ProxyError(400, "Invalid UTF-8 SSML.") from error
                if root.tag != "{http://www.w3.org/2001/10/synthesis}speak":
                    raise ProxyError(400, "Use the Speech synthesis SSML namespace.")
                if any(node.tag.rsplit("}", 1)[-1] in ("audio", "lexicon") for node in root.iter()):
                    raise ProxyError(400, "External audio and lexicon references are not supported.")
            if transcription:
                status, response_type, data = self.server.transport.forward(
                    self.command, upstream, body, output_format, content_type=content_type,
                )
            else:
                status, response_type, data = self.server.transport.forward(
                    self.command, upstream, body, output_format,
                )
            self.respond(status, response_type, data)
        except ProxyError as error:
            self.respond(error.status, "application/json", json.dumps({"error": str(error)}).encode())
        except (BrokenPipeError, ConnectionResetError, socket.timeout):
            self.close_connection = True

    def handle_streaming(self):
        keys = self.headers.get_all("Sec-WebSocket-Key") or []
        if (self.headers.get_all("Sec-WebSocket-Version") != ["13"]
                or self.headers.get("Upgrade", "").lower() != "websocket"
                or "upgrade" not in [value.strip().lower()
                                     for value in self.headers.get("Connection", "").split(",")]
                or len(keys) != 1):
            raise ProxyError(400, "A WebSocket version 13 upgrade is required.")
        try:
            if len(base64.b64decode(keys[0], validate=True)) != 16:
                raise ValueError("Invalid key length")
        except (ValueError, base64.binascii.Error) as error:
            raise ProxyError(400, "Invalid WebSocket handshake key.") from error
        upstream = self.server.transport.open_streaming(keys[0])
        self.close_connection = True
        try:
            self.protocol_version = "HTTP/1.1"
            self.send_response(101)
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "Upgrade")
            self.send_header("Sec-WebSocket-Accept", websocket_accept(keys[0]))
            self.end_headers()
            self.wfile.flush()
            try:
                relay_websocket(self.connection, upstream)
            except (OSError, ProxyError):
                # A post-upgrade failure is a WebSocket failure, never an HTTP success.
                try:
                    self.connection.sendall(b"\x88\x02\x03\xf3")  # Close 1011, no provider text.
                except OSError:
                    pass
        finally:
            upstream.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--subscription", required=True, help="Explicit Azure subscription ID")
    parser.add_argument("--resource", required=True, help="Custom Azure HTTPS resource origin")
    parser.add_argument("--token-file", required=True, help="Private local client token file (created with mode 600)")
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    if not 1 <= args.port <= 65535:
        parser.error("Port must be between 1 and 65535.")
    az = shutil.which("az")
    if not az:
        parser.error("Azure CLI is required. Install it and run az login.")
    try:
        transport = AzureTransport(args.resource, AzureCLIToken(args.subscription, az))
        # Fail before claiming readiness if sign-in is missing.
        transport.tokens.get()
        server = ProxyServer(args.port, local_token(args.token_file), transport)
    except (ValueError, OSError, ProxyError) as error:
        parser.exit(1, str(error) + "\n")
    print("Azure Speech proxy ready at http://127.0.0.1:%d (local token required)." % args.port, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()

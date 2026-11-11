import Foundation

#if !APP_STORE
/// The Python sidecar `SherpaOnnxLiveController` runs: it reads 16 kHz Float32
/// PCM on stdin and writes JSON transcript events on stdout.
enum SherpaOnnxSidecarScript {
  static let source = """
#!/usr/bin/env python3
import argparse
import array
import json
import sys

import sherpa_onnx


def emit(kind, text):
    print(json.dumps({"type": kind, "text": text}), flush=True)


def read_samples():
    chunk = sys.stdin.buffer.read(6400)
    if not chunk:
        return None
    usable = len(chunk) - (len(chunk) % 4)
    samples = array.array("f")
    if usable > 0:
        samples.frombytes(chunk[:usable])
    return samples


def run_online(args):
    recognizer = sherpa_onnx.OnlineRecognizer.from_transducer(
        tokens=args.tokens,
        encoder=args.encoder,
        decoder=args.decoder,
        joiner=args.joiner,
        num_threads=2,
        sample_rate=16000,
        feature_dim=args.feature_dim,
        decoding_method="greedy_search",
        provider="cpu",
    )
    stream = recognizer.create_stream()
    if args.language:
        # Language-ID prompted exports (Nemotron 3.5) only; unset auto-detects.
        stream.set_option("language", args.language)
    last_text = ""

    while True:
        samples = read_samples()
        if samples is None:
            break
        if not samples:
            continue
        stream.accept_waveform(16000, samples)
        while recognizer.is_ready(stream):
            recognizer.decode_stream(stream)
        text = recognizer.get_result(stream)
        if text and text != last_text:
            last_text = text
            emit("partial", text)

    stream.input_finished()
    while recognizer.is_ready(stream):
        recognizer.decode_stream(stream)
    final_text = recognizer.get_result(stream) or last_text
    emit("session_final", final_text)


def run_offline(args):
    # Offline transducers (e.g. NVIDIA Parakeet TDT) decode a whole utterance
    # at a time. Ingestion and inference are decoupled (issue #679): a reader
    # thread always drains stdin, so the pipe can never fill and block the
    # app's real-time audio queue behind model inference. Partials decode a
    # bounded tail window at an adaptive cadence (never more than ~half the
    # wall clock), so partial latency and per-decode cost stay constant for
    # long sessions instead of growing quadratically. The session final still
    # decodes every retained sample.
    import collections
    import threading
    import time

    recognizer = sherpa_onnx.OfflineRecognizer.from_transducer(
        encoder=args.encoder,
        decoder=args.decoder,
        joiner=args.joiner,
        tokens=args.tokens,
        num_threads=2,
        sample_rate=16000,
        feature_dim=args.feature_dim,
        decoding_method="greedy_search",
        model_type=args.model_type,
        provider="cpu",
    )

    # Bounded retention: one hour of 16 kHz mono float32 (~230 MB). Beyond it
    # the oldest audio is dropped and the cap is reported once, so memory is
    # bounded and truncation is explicit rather than silent.
    max_buffer_samples = 16000 * 60 * 60
    # Partials decode at most the trailing minute, keeping each partial decode
    # constant-cost regardless of session length.
    partial_window_samples = 16000 * 60

    lock = threading.Lock()
    # Retained audio is a deque of PCM chunks rather than one flat array:
    # evicting old audio drops whole leading chunks (plus a prefix of one
    # small chunk), so a post-cap read costs the same as any other read
    # instead of shifting the whole hour of samples while the reader holds
    # the lock and stdin stops draining.
    buffered = collections.deque()
    retained = 0  # samples currently held in `buffered`
    received = 0  # samples accepted from stdin since start; never decreases
    eof = threading.Event()
    capped = threading.Event()

    def reader():
        nonlocal retained, received
        while True:
            samples = read_samples()
            if samples is None:
                break
            if not samples:
                continue
            with lock:
                buffered.append(samples)
                retained += len(samples)
                received += len(samples)
                while retained > max_buffer_samples:
                    excess = retained - max_buffer_samples
                    oldest = buffered[0]
                    if len(oldest) <= excess:
                        buffered.popleft()
                        retained -= len(oldest)
                    else:
                        del oldest[:excess]
                        retained -= excess
                    capped.set()
        eof.set()

    def snapshot(limit):
        # Concatenates the trailing `limit` retained samples (every retained
        # sample when `limit` is None). Called with the lock held.
        window = array.array("f")
        if limit is None or retained <= limit:
            for chunk in buffered:
                window.extend(chunk)
            return window
        remaining = limit
        tail = []
        for chunk in reversed(buffered):
            if len(chunk) >= remaining:
                tail.append(chunk[len(chunk) - remaining:])
                break
            tail.append(chunk)
            remaining -= len(chunk)
        for chunk in reversed(tail):
            window.extend(chunk)
        return window

    thread = threading.Thread(target=reader, daemon=True)
    thread.start()

    def decode(window):
        stream = recognizer.create_stream()
        stream.accept_waveform(16000, window)
        recognizer.decode_stream(stream)
        return stream.result.text

    last_text = ""
    # `received` at the last partial decode. Progress is measured against
    # samples accepted, not samples retained, so partials continue after the
    # retention cap holds the buffer at a constant length.
    decoded_upto = 0
    last_decode_seconds = 0.0
    did_report_cap = False

    def report_cap_once():
        nonlocal did_report_cap
        if capped.is_set() and not did_report_cap:
            did_report_cap = True
            emit("buffer_capped", "retention window exceeded; oldest audio dropped")

    while not eof.is_set():
        time.sleep(0.1)
        report_cap_once()
        with lock:
            available = received
        # Adaptive cadence: at least two seconds of new audio, and at least
        # twice the previous decode's duration, so decoding can never occupy
        # more than about half of real time and ingestion always stays ahead.
        required = int(16000 * max(2.0, last_decode_seconds * 2.0))
        if available - decoded_upto < required:
            continue
        with lock:
            window = snapshot(partial_window_samples)
        started = time.monotonic()
        text = decode(window)
        last_decode_seconds = time.monotonic() - started
        decoded_upto = available
        if text and text != last_text:
            last_text = text
            emit("partial", text)

    thread.join()
    # The reader can reach the cap between the last poll and EOF; the
    # truncation is still reported before the final transcript.
    report_cap_once()
    with lock:
        final_window = snapshot(None)
    emit("finalizing", "%.1f" % (len(final_window) / 16000.0))
    final_text = (decode(final_window) if final_window else "") or last_text
    emit("session_final", final_text)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tokens", required=True)
    parser.add_argument("--encoder", required=True)
    parser.add_argument("--decoder", required=True)
    parser.add_argument("--joiner", required=True)
    parser.add_argument("--feature-dim", type=int, default=80)
    parser.add_argument("--model-type", default="transducer")
    parser.add_argument("--language", default=None)
    args = parser.parse_args()

    if args.model_type == "transducer":
        run_online(args)
    else:
        run_offline(args)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(json.dumps({"type": "error", "message": str(exc)}), flush=True)
        sys.exit(1)
"""
}

#endif

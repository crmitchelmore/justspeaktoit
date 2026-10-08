"""Bounded, content-free stream accounting for launch verification."""
import json
import os
import selectors
import signal
import sys
import time
from pathlib import Path

CHUNK_BYTES = 32 * 1024


def drain(descriptor, deadline, stopped=lambda: False):
    count = 0
    # macOS kqueue can miss readability on an RDWR FIFO; select handles both
    # the candidate FIFO and subprocess pipes without delaying the producer.
    with selectors.SelectSelector() as selector:
        selector.register(descriptor, selectors.EVENT_READ)
        while not stopped() and time.monotonic() < deadline:
            for _, _ in selector.select(min(0.1, max(0, deadline - time.monotonic()))):
                chunk = os.read(descriptor, CHUNK_BYTES)
                if not chunk:
                    return {"bytesDiscarded": count, "timedOut": False}
                count += len(chunk)
    return {"bytesDiscarded": count, "timedOut": not stopped()}


def capture_fifo(fifo, output):
    stopping = False

    def stop(_signal, _frame):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    # RDWR prevents EOF before the candidate opens its writer, or a descendant
    # keeping stdout open from delaying cleanup. Only our stop signal ends capture.
    descriptor = os.open(fifo, os.O_RDWR | os.O_NONBLOCK)
    try:
        statistics = drain(descriptor, float("inf"), lambda: stopping)
        statistics["contentRetained"] = False
        Path(output).write_text(json.dumps(statistics) + "\n")
    finally:
        os.close(descriptor)


if __name__ == "__main__":
    capture_fifo(*sys.argv[1:])

#!/usr/bin/env python3
"""Witness replacement of both bundle and executable, not just install intent."""
import json
import os
import sys
import time


def identity(bundle, executable):
    return [[value.st_dev, value.st_ino] for value in (os.stat(bundle), os.stat(executable))]


def was_replaced(before, bundle, executable):
    try:
        after = identity(bundle, executable)
    except FileNotFoundError:
        # Sparkle may temporarily remove the old bundle while swapping it.
        return False
    return all(old != new for old, new in zip(before, after))


def wait_for_replacement(before, bundle, executable, timeout):
    deadline = time.monotonic() + timeout
    while True:
        if was_replaced(before, bundle, executable):
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(min(0.5, max(0, deadline - time.monotonic())))


if __name__ == "__main__":
    command, bundle, executable, *arguments = sys.argv[1:]
    if command == "snapshot":
        print(json.dumps(identity(bundle, executable)))
    elif command == "wait":
        before = json.loads(arguments[0])
        timeout = float(arguments[1])
        if not wait_for_replacement(before, bundle, executable, timeout):
            print("FAIL: Sparkle did not replace both the bundle and executable before the deadline", file=sys.stderr)
            sys.exit(1)
        print("OK: observed replacement of both the bundle and executable")
    else:
        raise ValueError(f"unknown command: {command}")

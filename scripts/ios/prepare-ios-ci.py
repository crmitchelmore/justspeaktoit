#!/usr/bin/env python3
"""Require bounded simulator readiness before running compiled XCTest products."""

import subprocess
import sys


def prepare(simulator_id):
    boot = subprocess.Popen(["xcrun", "simctl", "bootstatus", simulator_id, "-b"])
    try:
        print("Waiting for simulator readiness before running XCTest.", flush=True)
        try:
            result = boot.wait(timeout=600)
        except subprocess.TimeoutExpired as error:
            raise RuntimeError(
                "Simulator did not become ready within ten minutes."
            ) from error
        if result:
            raise subprocess.CalledProcessError(result, boot.args)
    finally:
        if boot.poll() is None:
            boot.terminate()
            try:
                boot.wait(timeout=5)
            except subprocess.TimeoutExpired:
                boot.kill()
                boot.wait(timeout=5)


if __name__ == "__main__":
    if len(sys.argv) != 2 or not sys.argv[1]:
        raise SystemExit("Usage: prepare-ios-ci.py <simulator-udid>")
    prepare(sys.argv[1])

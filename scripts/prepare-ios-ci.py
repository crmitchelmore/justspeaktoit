#!/usr/bin/env python3
"""Overlap simulator initialization with independent iOS compilation."""

import os
import subprocess
import sys


def prepare(simulator_id):
    boot = subprocess.Popen(["xcrun", "simctl", "bootstatus", simulator_id, "-b"])
    try:
        print("Building the iOS library while the simulator initializes.", flush=True)
        subprocess.run(
            ["swift", "build", "--disable-dependency-cache", "--target", "SpeakiOSLib"],
            check=True,
        )
        if boot.poll() not in (None, 0):
            raise subprocess.CalledProcessError(boot.returncode, boot.args)

        print("Generating the shipping keyboard/app project.", flush=True)
        environment = os.environ.copy()
        environment["TUIST_IOS_KEYBOARD"] = "1"
        subprocess.run(
            ["tuist", "generate", "--no-open"], env=environment, check=True
        )
        print("Waiting for simulator readiness before running XCTest.", flush=True)
        try:
            result = boot.wait(timeout=300)
        except subprocess.TimeoutExpired as error:
            raise RuntimeError(
                "Simulator did not become ready within five minutes after compilation."
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

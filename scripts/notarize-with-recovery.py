#!/usr/bin/env python3
"""Submit once, then recover transient status-query failures for the same UUID.

Callers own the existing job deadline and signing/validation gates. The app
retains its 120 attempts/60 minutes; CLI retains 45 minutes. DMG callers adopt
the app's explicitly tighter 120-attempt/60-minute cap (previously only the
240-minute outer job bounded their wait).

Upload now has a NEW tighter cap equal to the caller's polling window (60
minutes for app/DMG, 45 for CLI). A timed-out upload has unknown acceptance:
fail without a second submission or any status query lacking a confirmed ID.
The separate post-upload polling window still starts only after upload.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time
import uuid


def _credentials():
    names = ("APPLE_ID", "APPLE_ID_PASSWORD", "APPLE_TEAM_ID")
    values = [os.environ.get(name, "") for name in names]
    if not all(value.strip() for value in values):
        raise ValueError("Existing Apple ID, app-specific password and team ID are required")
    return ["--apple-id", values[0], "--password", values[1], "--team-id", values[2]], values


def _diagnostic(text, secrets):
    for secret in secrets:
        text = text.replace(secret, "[redacted]")
    if text.strip():
        print(text.strip(), file=sys.stderr)


def _request(arguments, credentials, timeout=None):
    return subprocess.run(
        ["xcrun", "notarytool", *arguments, *credentials],
        capture_output=True, text=True, check=False, timeout=timeout,
    )


def _status(output, submission_id):
    response = json.loads(output)
    if not isinstance(response, dict) or response.get("id") != submission_id:
        raise ValueError("Notary response does not identify the submitted UUID")
    status = response.get("status")
    if status not in ("Accepted", "In Progress", "Invalid", "Rejected"):
        raise ValueError("Unknown notarization status")
    return status


def _transient(output):
    # Do not turn authentication/authorization failures into retries even if a
    # secondary diagnostic happens to contain a network error.
    if re.search(r"(?:HTTP(?:Error| status)?|statusCode)\D*(?:401|403)\b", output, re.I):
        return False
    return bool(re.search(r"NSURLErrorDomain\s+Code=-(?:1005|1009)\b", output))


def notarize(path, timeout_seconds, max_attempts, poll_seconds):
    credentials, secrets = _credentials()
    # No --wait: successful upload yields the durable ID before polling can
    # encounter a network failure. Never call submit again in this operation.
    try:
        submitted = _request(
            ["submit", path, "--no-wait", "--output-format", "json"], credentials, timeout_seconds,
        )
    except subprocess.TimeoutExpired:
        # TimeoutExpired can retain the command and captured authentication
        # diagnostics. Never render it or repeat an upload of unknown state.
        print("Upload exceeded its finite time limit; acceptance unknown, refusing to resubmit", file=sys.stderr)
        return 1
    if submitted.returncode:
        _diagnostic(submitted.stdout + submitted.stderr, secrets)
        return 1
    try:
        submission_id = json.loads(submitted.stdout)["id"]
        if not isinstance(submission_id, str):
            raise ValueError("Submission UUID is not a string")
        if str(uuid.UUID(submission_id)) != submission_id:
            raise ValueError("Noncanonical submission UUID")
    except (ValueError, TypeError, KeyError):
        print("Upload did not return a valid submission UUID; refusing to resubmit", file=sys.stderr)
        return 1

    print(f"Submission ID: {submission_id}", flush=True)
    # Match the existing policy: the polling window starts after the upload.
    # Recoveries consume this single deadline and the same attempt counter.
    deadline = time.monotonic() + timeout_seconds
    for attempt in range(1, max_attempts + 1):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        try:
            result = _request(["info", submission_id, "--output-format", "json"], credentials, remaining)
        except subprocess.TimeoutExpired:
            break
        if time.monotonic() >= deadline:
            break
        if result.returncode:
            diagnostic = result.stdout + result.stderr
            _diagnostic(diagnostic, secrets)
            if not _transient(diagnostic):
                return 1
            print(f"Transient status-query failure ({attempt}/{max_attempts}); retaining {submission_id}")
        else:
            try:
                status = _status(result.stdout, submission_id)
            except (ValueError, TypeError):
                print("Invalid notary status response; refusing to continue", file=sys.stderr)
                return 1
            print(f"Notarization {submission_id}: {status} ({attempt}/{max_attempts})", flush=True)
            if status == "Accepted":
                return 0
            if status in ("Invalid", "Rejected"):
                remaining = deadline - time.monotonic()
                if remaining > 0:
                    try:
                        log = _request(["log", submission_id], credentials, remaining)
                        _diagnostic(log.stdout + log.stderr, secrets)
                    except subprocess.TimeoutExpired:
                        pass
                return 1
        if attempt == max_attempts:
            break
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        time.sleep(min(poll_seconds, remaining))
    print(f"Notarization {submission_id} did not complete within the existing polling bounds", file=sys.stderr)
    return 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive")
    parser.add_argument("--timeout-seconds", type=int, required=True)
    parser.add_argument("--max-attempts", type=int, required=True)
    parser.add_argument("--poll-seconds", type=int, default=30)
    arguments = parser.parse_args()
    if min(arguments.timeout_seconds, arguments.max_attempts, arguments.poll_seconds) <= 0:
        parser.error("Polling bounds must be positive")
    try:
        return notarize(arguments.archive, arguments.timeout_seconds, arguments.max_attempts, arguments.poll_seconds)
    except (ValueError, OSError) as error:
        # These messages are controlled validation/OS errors, never command
        # arguments containing the existing authentication values.
        print(f"Notarization could not start: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

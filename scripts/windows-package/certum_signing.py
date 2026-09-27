#!/usr/bin/env python3
"""Certum SimplySign support for the Windows signing job.

Certum's Open Source Code Signing certificate lives in Certum's SimplySign
cloud HSM. SimplySign Desktop exposes it to Windows as a smart-card
certificate once a user logs in with the account's e-mail address and a
one-time password from the SimplySign mobile app. The mobile app is paired by
scanning a QR code that encodes a standard ``otpauth://totp/...`` URI; the same
URI, stored as the ``CERTUM_SIMPLYSIGN_OTP_URI`` secret, lets CI compute the
one-time password itself (RFC 6238).

This module validates that URI and computes the current code. ``code`` prints
only the code, for ``connect-certum-simplysign.ps1`` to type into SimplySign
Desktop; it reads the URI from the environment and never prints it. The key
never leaves Certum: nothing here or in CI can export it.
"""
import argparse
import base64
import hashlib
import hmac
import os
import struct
import sys
import time
import urllib.parse

TIMESTAMP_URL = "http://time.certum.pl"
OTP_URI_VARIABLE = "CERTUM_SIMPLYSIGN_OTP_URI"
ALGORITHMS = {"SHA1": hashlib.sha1, "SHA256": hashlib.sha256, "SHA512": hashlib.sha512}


class CertumConfigurationError(Exception):
    """The one-time-password seed cannot be used. Messages never contain it."""


def parse_otp_uri(uri):
    """``{"secret": bytes, "algorithm": str, "digits": int, "period": int}`` from an otpauth URI.

    Follows the Key Uri Format: ``algorithm`` defaults to SHA1, ``digits`` to 6
    and ``period`` to 30. Only TOTP is accepted: SimplySign codes are time-based.
    """
    if not isinstance(uri, str):
        raise CertumConfigurationError("the one-time-password seed must be an otpauth:// URI")
    parts = urllib.parse.urlsplit(uri.strip())
    if parts.scheme.lower() != "otpauth" or parts.netloc.lower() != "totp":
        raise CertumConfigurationError("the one-time-password seed must be an otpauth://totp/ URI")
    query = urllib.parse.parse_qs(parts.query, keep_blank_values=True, strict_parsing=False)
    if any(len(values) != 1 for values in query.values()):
        raise CertumConfigurationError("the otpauth URI repeats a parameter")
    values = {key.lower(): value[0] for key, value in query.items()}
    encoded = values.get("secret", "").replace(" ", "").upper()
    try:
        secret = base64.b32decode(encoded + "=" * (-len(encoded) % 8), casefold=False)
    except (ValueError, TypeError):
        raise CertumConfigurationError("the otpauth URI secret is not Base32") from None
    if len(secret) < 10:
        raise CertumConfigurationError("the otpauth URI secret is too short to be a SimplySign seed")
    algorithm = values.get("algorithm", "SHA1").upper().replace("-", "")
    if algorithm not in ALGORITHMS:
        raise CertumConfigurationError("the otpauth URI algorithm must be SHA1, SHA256 or SHA512")
    try:
        digits = int(values.get("digits", "6"))
        period = int(values.get("period", "30"))
    except ValueError:
        raise CertumConfigurationError("the otpauth URI digits and period must be integers") from None
    if digits not in (6, 7, 8) or not 15 <= period <= 120:
        raise CertumConfigurationError("the otpauth URI needs 6-8 digits and a 15-120 second period")
    return {"secret": secret, "algorithm": algorithm, "digits": digits, "period": period}


def totp(secret, at, digits=6, period=30, algorithm="SHA1"):
    """The RFC 6238 time-based one-time password for ``secret`` at Unix time ``at``."""
    counter = struct.pack(">Q", int(at) // period)
    digest = hmac.new(secret, counter, ALGORITHMS[algorithm]).digest()
    offset = digest[-1] & 0x0F
    value = struct.unpack(">I", digest[offset:offset + 4])[0] & 0x7FFFFFFF
    return str(value % (10 ** digits)).zfill(digits)


def current_code(uri, minimum_remaining=8, clock=time.time, sleep=time.sleep):
    """The code for now, waiting for the next period when fewer than
    ``minimum_remaining`` seconds are left, so it cannot expire while typed."""
    settings = parse_otp_uri(uri)
    now = clock()
    remaining = settings["period"] - (now % settings["period"])
    if remaining < minimum_remaining:
        sleep(remaining + 0.5)
        now = clock()
    return totp(settings["secret"], now, settings["digits"], settings["period"], settings["algorithm"])


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    code = commands.add_parser("code", help="print the current one-time password (from %s)" % OTP_URI_VARIABLE)
    code.add_argument("--minimum-remaining", type=int, default=8)
    commands.add_parser("check", help="validate %s without printing anything secret" % OTP_URI_VARIABLE)
    args = parser.parse_args(argv)
    uri = os.environ.get(OTP_URI_VARIABLE, "")
    try:
        if args.command == "check":
            settings = parse_otp_uri(uri)
            print("The SimplySign one-time-password seed is usable (%s, %d digits, %d s)."
                  % (settings["algorithm"], settings["digits"], settings["period"]))
        else:
            sys.stdout.write(current_code(uri, args.minimum_remaining) + "\n")
    except CertumConfigurationError as error:
        print("error: " + OTP_URI_VARIABLE + ": " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

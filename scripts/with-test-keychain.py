#!/usr/bin/env python3
"""Run CI tests with a disposable Keychain; restore the user's configuration."""
import os
import secrets
import signal
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path


def security(*args):
    return subprocess.check_output(['/usr/bin/security', *args], text=True).strip()


def interrupted(signum, frame):
    raise KeyboardInterrupt


def main():
    if len(sys.argv) < 2:
        raise SystemExit('Usage: with-test-keychain.py command [arguments...]')
    signal.signal(signal.SIGTERM, interrupted)
    original_default = shlex.split(security('default-keychain', '-d', 'user'))[0]
    original_search = shlex.split(security('list-keychains', '-d', 'user'))
    with tempfile.TemporaryDirectory(prefix='jsti-ci-keychain-') as directory:
        keychain = str(Path(directory) / 'tests.keychain-db')
        password = secrets.token_urlsafe(32)
        try:
            security('create-keychain', '-p', password, keychain)
            security('set-keychain-settings', '-lut', '21600', keychain)
            security('unlock-keychain', '-p', password, keychain)
            security('list-keychains', '-d', 'user', '-s', keychain)
            security('default-keychain', '-d', 'user', '-s', keychain)
            return subprocess.call(sys.argv[1:])
        finally:
            security('default-keychain', '-d', 'user', '-s', original_default)
            security('list-keychains', '-d', 'user', '-s', *original_search)
            if os.path.exists(keychain):
                security('delete-keychain', keychain)


if __name__ == '__main__':
    sys.exit(main())

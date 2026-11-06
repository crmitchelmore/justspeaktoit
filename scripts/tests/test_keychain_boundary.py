"""Prevent app and fixture Security calls bypassing native CI file isolation."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


class KeychainBoundaryTests(unittest.TestCase):
    def test_app_and_credential_fixtures_use_canonical_security_boundary(self):
        raw = re.compile(r'\bSecItem(?:Add|CopyMatching|Update|Delete)\s*(?:\(|,|$)', re.M)
        paths = []
        for root in ['Sources/SpeakCore', 'Sources/SpeakApp', 'Sources/SpeakiOS',
                     'Tests/SpeakCoreTests', 'Tests/SpeakAppTests', 'Tests/SpeakiOSTests']:
            paths.extend((ROOT / root).rglob('*.swift'))
        offenders = [str(p.relative_to(ROOT)) for p in paths
                     if p.name != 'KeychainAccess.swift' and raw.search(p.read_text())]
        self.assertEqual(offenders, [])

    def test_native_and_hosted_gates_verify_real_process_isolation(self):
        workflow = (ROOT / '.github/workflows/ci.yml').read_text()
        self.assertIn('python3 -B -m unittest scripts.tests.test_private_test_keychain -v', workflow)
        self.assertIn('python3 scripts/with-test-keychain.py bash scripts/run-core-journey-e2e.sh --phase test', workflow)

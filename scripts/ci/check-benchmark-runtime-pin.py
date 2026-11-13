#!/usr/bin/env python3
"""Fail when the benchmark's WhisperKit runtime constants drift from its argmax-oss-swift pin.

    python3 scripts/ci/check-benchmark-runtime-pin.py

The Local Transcription Benchmark workflow runs only after merge on macOS, so a
package update that moves the pin used to turn main red. This text check runs in
the Linux CI Lint job instead and mirrors BenchmarkManifestParityTests.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / 'Benchmarks' / 'LocalTranscription'
RESOLVED = PACKAGE / 'Package.resolved'
RUNNERS = PACKAGE / 'Sources' / 'LocalTranscriptionBenchmark' / 'EngineRunners.swift'


def main() -> int:
    pins = json.loads(RESOLVED.read_text(encoding='utf-8')).get('pins', [])
    pin = next((p for p in pins if p.get('identity') == 'argmax-oss-swift'), None)
    if pin is None:
        print(f'{RESOLVED.relative_to(ROOT)}: argmax-oss-swift pin missing', file=sys.stderr)
        return 1
    version, revision = pin['state'].get('version'), pin['state'].get('revision')
    runners = RUNNERS.read_text(encoding='utf-8')
    errors = []
    if f'"argmax-oss-swift {version}"' not in runners:
        errors.append(f'runtimeVersion must be "argmax-oss-swift {version}"')
    if f'runtimeCommit: String? = "{revision}"' not in runners:
        errors.append(f'runtimeCommit must be "{revision}"')
    for error in errors:
        print(f'{RUNNERS.relative_to(ROOT)}: {error} to match {RESOLVED.relative_to(ROOT)}', file=sys.stderr)
    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())

#!/usr/bin/env python3
"""Fail when .swiftlint-baseline.json holds more entries than it does on the base branch.

    python3 scripts/ci/lint-baseline-ratchet.py [--base REF]

The baseline only records existing debt; new code must lint clean. The base is
REF, else $JSTI_LINT_BASELINE_BASE, else origin/main, compared at its merge base
with HEAD when history allows (a shallow CI checkout compares with the base tip;
an origin/* base missing locally is fetched first). The working-tree baseline is
counted, so uncommitted edits are checked too. A base without a baseline file
has nothing to ratchet against and passes.
"""
from __future__ import annotations

import argparse
import collections
import json
import os
import subprocess
import sys
from pathlib import Path

BASELINE = '.swiftlint-baseline.json'


def git(root: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(['git', *args], cwd=root, text=True, capture_output=True)


def resolve(root: Path, base: str) -> str | None:
    """The commit to compare with: the merge base with HEAD, else the base tip, else None."""
    if git(root, 'rev-parse', '--verify', '--quiet', f'{base}^{{commit}}').returncode != 0:
        remote, _, branch = base.partition('/')
        if remote != 'origin' or not branch:
            return None
        git(root, 'fetch', '--quiet', '--no-tags', '--depth=1', 'origin',
            f'+refs/heads/{branch}:refs/remotes/origin/{branch}')
        if git(root, 'rev-parse', '--verify', '--quiet', f'{base}^{{commit}}').returncode != 0:
            return None
    merge_base = git(root, 'merge-base', 'HEAD', base)
    return merge_base.stdout.strip() if merge_base.returncode == 0 else base


def files(entries: list[dict]) -> collections.Counter:
    return collections.Counter(entry['violation']['location']['file'] for entry in entries)


def main(argv: list[str], root: Path = Path(__file__).resolve().parents[2]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--base', default=os.environ.get('JSTI_LINT_BASELINE_BASE') or 'origin/main')
    args = parser.parse_args(argv)

    ref = resolve(root, args.base)
    if ref is None:
        print(f'lint-baseline-ratchet: base {args.base} is not available; fetch it or pass --base', file=sys.stderr)
        return 1
    before = git(root, 'show', f'{ref}:{BASELINE}')
    if before.returncode != 0:
        print(f'lint-baseline-ratchet: {args.base} has no {BASELINE}; nothing to ratchet against')
        return 0
    old = json.loads(before.stdout)
    path = root / BASELINE
    new = json.loads(path.read_text(encoding='utf-8')) if path.exists() else []
    if len(new) <= len(old):
        print(f'lint-baseline-ratchet: {BASELINE} has {len(new)} entries ({len(new) - len(old):+d} vs {args.base})')
        return 0
    old_files = files(old)
    grown = sorted((count - old_files[name], name) for name, count in files(new).items() if count > old_files[name])
    print(f'lint-baseline-ratchet: {BASELINE} grew from {len(old)} to {len(new)} entries vs {args.base}. '
          'Fix the new SwiftLint violations instead of baselining them.', file=sys.stderr)
    for count, name in reversed(grown[-10:]):
        print(f'  +{count} {name}', file=sys.stderr)
    return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

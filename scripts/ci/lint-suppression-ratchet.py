#!/usr/bin/env python3
"""Fail when Swift sources gain file-wide SwiftLint suppressions, or a lint baseline returns.

    python3 scripts/ci/lint-suppression-ratchet.py [--base REF]

SwiftLint runs strict with no baseline, so every violation fails. What remains is
the suppressions written in source:

- a scoped suppression (`swiftlint:disable:next`, `:this` or `:previous`) covers
  one line and must carry a reason; it is not counted here;
- a file-wide `// swiftlint:disable <rules>` is existing debt. For each rule the
  number of them must not grow against the base, so splitting a file to remove
  one passes, but a new one does not.

No `.swiftlint-baseline.json` may exist. The base is REF, else
$JSTI_LINT_BASELINE_BASE, else origin/main, compared at its merge base with HEAD
when history allows (an origin/* base missing locally is fetched first). The
working tree, including uncommitted and untracked files, is counted.
"""
from __future__ import annotations

import argparse
import collections
import os
import re
import subprocess
import sys
from pathlib import Path

BASELINE = '.swiftlint-baseline.json'
# `swiftlint:disable rule…` without a :next/:this/:previous modifier.
BLANKET = re.compile(r'swiftlint:disable(?![:\w])\s+([\w ]+)')


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


def count(lines: list[tuple[str, str]]) -> collections.Counter:
    """Blanket suppressions per rule, from (file, line text) pairs."""
    rules: collections.Counter = collections.Counter()
    for _, text in lines:
        for match in BLANKET.finditer(text):
            rules.update(match.group(1).split())
    return rules


def grep(root: Path, ref: str | None) -> list[tuple[str, str]]:
    """(file, line) pairs mentioning swiftlint:disable in Swift files at ref, or in the working tree."""
    args = ['grep', '-I', '--no-color', '-e', 'swiftlint:disable']
    args += [ref, '--', '*.swift'] if ref else ['--untracked', '--', '*.swift']
    result = git(root, *args)
    pairs = []
    for line in result.stdout.splitlines():
        if ref:
            line = line.split(':', 1)[1]
        name, _, text = line.partition(':')
        pairs.append((name, text))
    return pairs


def main(argv: list[str], root: Path = Path(__file__).resolve().parents[2]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--base', default=os.environ.get('JSTI_LINT_BASELINE_BASE') or 'origin/main')
    args = parser.parse_args(argv)

    if (root / BASELINE).exists():
        print(f'lint-suppression-ratchet: {BASELINE} must not exist; SwiftLint runs with no baseline. '
              'Fix the violations instead.', file=sys.stderr)
        return 1
    ref = resolve(root, args.base)
    if ref is None:
        print(f'lint-suppression-ratchet: base {args.base} is not available; fetch it or pass --base',
              file=sys.stderr)
        return 1
    old, current = count(grep(root, ref)), count(grep(root, None))
    grown = sorted((current[rule] - old[rule], rule) for rule in current if current[rule] > old[rule])
    if grown:
        print(f'lint-suppression-ratchet: file-wide swiftlint:disable grew vs {args.base}. Fix the violation, or '
              'use a scoped `swiftlint:disable:next <rule>` with a reason where the rule is wrong for that line.',
              file=sys.stderr)
        for delta, rule in reversed(grown):
            print(f'  +{delta} {rule}', file=sys.stderr)
        return 1
    total, before = sum(current.values()), sum(old.values())
    print(f'lint-suppression-ratchet: {total} file-wide suppressions ({total - before:+d} vs {args.base})')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

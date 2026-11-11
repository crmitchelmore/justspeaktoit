#!/usr/bin/env python3
"""Fail when .swiftlint-baseline.json grows, in total or for any one file, against the base branch.

    python3 scripts/ci/lint-baseline-ratchet.py [--base REF]

The baseline only records existing debt; new code must lint clean. Two rules apply:

- the total entry count must not grow;
- no file may gain entries, unless each gained entry is debt that moved: an entry
  with the same rule and source text that left another file (or the same file at a
  different line). So renames and splits pass, but a file cannot trade a fixed
  violation elsewhere for a new one of its own.
 The base is
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


def identity(entry: dict) -> tuple[str, str]:
    """What a violation is, independent of where it sits: its rule and its (trimmed) source line."""
    return entry['violation'].get('ruleIdentifier', ''), entry.get('text', '').strip()


def by_file(entries: list[dict]) -> dict[str, collections.Counter]:
    grouped: dict[str, collections.Counter] = collections.defaultdict(collections.Counter)
    for entry in entries:
        grouped[entry['violation']['location']['file']][identity(entry)] += 1
    return grouped


def grown_files(old: list[dict], new: list[dict]) -> list[tuple[int, str]]:
    """Files whose entry count grew by more than the debt that moved into them, as (unexplained, file).

    Debt that leaves a file (its count of an identity drops) forms a pool; a file that
    grew may draw on that pool for each identity it gained. Whatever it cannot draw is
    new debt.
    """
    old_files, new_files = by_file(old), by_file(new)
    released: collections.Counter = collections.Counter()
    for name, counts in old_files.items():
        released.update(counts - new_files.get(name, collections.Counter()))
    grown = []
    for name in sorted(new_files):
        gained = new_files[name] - old_files.get(name, collections.Counter())
        if sum(new_files[name].values()) <= sum(old_files.get(name, collections.Counter()).values()):
            continue
        unexplained = 0
        for key, count in sorted(gained.items()):
            moved = min(count, released[key])
            released[key] -= moved
            unexplained += count - moved
        if unexplained:
            grown.append((unexplained, name))
    return grown


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
    if len(new) > len(old):
        old_files = files(old)
        grown = sorted((count - old_files[name], name) for name, count in files(new).items() if count > old_files[name])
        print(f'lint-baseline-ratchet: {BASELINE} grew from {len(old)} to {len(new)} entries vs {args.base}. '
              'Fix the new SwiftLint violations instead of baselining them.', file=sys.stderr)
        for count, name in reversed(grown[-10:]):
            print(f'  +{count} {name}', file=sys.stderr)
        return 1
    grown = sorted(grown_files(old, new))
    if grown:
        print(f'lint-baseline-ratchet: {len(grown)} file(s) gained {BASELINE} entries vs {args.base} that did not '
              'move from elsewhere. Fix the new SwiftLint violations instead of baselining them.', file=sys.stderr)
        for count, name in reversed(grown[-10:]):
            print(f'  +{count} {name}', file=sys.stderr)
        return 1
    print(f'lint-baseline-ratchet: {BASELINE} has {len(new)} entries ({len(new) - len(old):+d} vs {args.base})')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

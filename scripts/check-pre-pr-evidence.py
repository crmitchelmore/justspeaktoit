#!/usr/bin/env python3
"""Check a pull request body for the scripts/pre-pr evidence marker.

Reads PR_BODY, PR_HEAD_SHA and PR_AUTHOR from the environment. Prints a GitHub
annotation and exits 0 unless JSTI_REQUIRE_PRE_PR is "true", in which case a
missing or failing record exits 1. Bot authors are exempt.

JSTI_PRE_PR_STRICT=true (the ci.yml gate) also enforces, and treats a record
for another commit as an error: the record must name PR_HEAD_SHA, or carry a
`tree` equal to PR_HEAD_TREE (the head commit's tree, so a run on the
uncommitted tree that was then committed unchanged still counts).
"""
import json
import os
import re
import sys

MARKER = re.compile(r'<!-- pre-pr-summary (\{.*?\}) -->')
BOTS = re.compile(r'(\[bot\]$|^dependabot|^renovate|^devin-ai-integration)', re.I)


def evaluate(body: str, head: str, author: str, head_tree: str = '', strict: bool = False) -> tuple[str, str]:
    """Return (level, message) where level is ok, warning or error."""
    if BOTS.search(author or ''):
        return 'ok', f'{author} is a bot; pre-PR evidence is not expected.'
    records = MARKER.findall(body or '')
    if not records:
        return 'error', ('No scripts/pre-pr record in the PR body. Run `scripts/pre-pr --markdown` and paste '
                         'its output (or .build/pre-pr/summary.md) into the description.')
    try:
        record = json.loads(records[-1])
    except json.JSONDecodeError:
        return 'error', 'The pre-pr-summary marker is not valid JSON; paste the generated summary unchanged.'
    if record.get('result') != 'pass':
        return 'error', f'The recorded scripts/pre-pr result is {record.get("result")!r}, not pass.'
    if record.get('head') != head:
        if head_tree and record.get('tree') == head_tree:
            return 'ok', f'scripts/pre-pr passed on the tree of the current head {head[:12]}.'
        return 'error' if strict else 'warning', (f'scripts/pre-pr passed at {str(record.get("head"))[:12]}, but the head is now {head[:12]}. '
                           'Re-run it after material changes and update the PR body.')
    return 'ok', f'scripts/pre-pr passed at the current head {head[:12]}.'


def main() -> int:
    strict = os.environ.get('JSTI_PRE_PR_STRICT', '').lower() == 'true'
    level, message = evaluate(os.environ.get('PR_BODY', ''), os.environ.get('PR_HEAD_SHA', ''),
                              os.environ.get('PR_AUTHOR', ''), os.environ.get('PR_HEAD_TREE', ''), strict)
    enforce = strict or os.environ.get('JSTI_REQUIRE_PRE_PR', '').lower() == 'true'
    if level == 'ok':
        print(message)
        return 0
    annotation = 'error' if level == 'error' and enforce else 'warning'
    print(f'::{annotation} title=Pre-PR checks::{message}')
    summary = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary:
        with open(summary, 'a', encoding='utf-8') as handle:
            handle.write(f'### Pre-PR checks\n\n{message}\n')
    return 1 if annotation == 'error' else 0


if __name__ == '__main__':
    sys.exit(main())

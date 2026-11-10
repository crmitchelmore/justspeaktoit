#!/usr/bin/env python3
"""Check a pull request body for the scripts/pre-pr evidence marker.

Reads PR_BODY, PR_HEAD_SHA and PR_AUTHOR from the environment. Prints a GitHub
annotation and exits 0 unless JSTI_REQUIRE_PRE_PR is "true", in which case a
missing or failing record exits 1. Bot authors are exempt.
"""
import json
import os
import re
import sys

MARKER = re.compile(r'<!-- pre-pr-summary (\{.*?\}) -->')
BOTS = re.compile(r'(\[bot\]$|^dependabot|^renovate|^devin-ai-integration)', re.I)


def evaluate(body: str, head: str, author: str) -> tuple[str, str]:
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
        return 'warning', (f'scripts/pre-pr passed at {str(record.get("head"))[:12]}, but the head is now {head[:12]}. '
                           'Re-run it after material changes and update the PR body.')
    return 'ok', f'scripts/pre-pr passed at the current head {head[:12]}.'


def main() -> int:
    level, message = evaluate(os.environ.get('PR_BODY', ''), os.environ.get('PR_HEAD_SHA', ''),
                              os.environ.get('PR_AUTHOR', ''))
    enforce = os.environ.get('JSTI_REQUIRE_PRE_PR', '').lower() == 'true'
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

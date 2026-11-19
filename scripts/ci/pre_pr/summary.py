"""The pre-pr record for a PR body: a Markdown table of every check and the
hidden pre-pr-summary marker that check-pre-pr-evidence.py reads in CI."""
from __future__ import annotations

import json

from pre_pr.environment import outcomes

SCHEMA_VERSION = 1


def markdown(summary: dict) -> str:
    icon = outcomes().ICONS
    lines = [f'### Pre-PR checks: {summary["result"].upper()}',
             f'`scripts/pre-pr` at `{summary["head"][:12]}`{" (dirty tree)" if summary["dirty"] else ""} '
             f'against `{summary["base_ref"]}` ({summary["merge_base"][:12]}), '
             f'{summary["changed_file_count"]} changed files, {summary["duration_seconds"]:.0f}s.',
             '', '| Check | Area | Result | Time |', '|---|---|---|---|']
    for check in summary['checks']:
        note = f' ({check["note"]})' if check['note'] else ''
        lines.append(f'| {check["title"]} | {check["area"]} | {icon[check["status"]]} {check["status"]}{note} '
                     f'| {check["duration_seconds"]:.0f}s |')
    if not summary['checks']:
        lines.append('| (no checks apply to these paths) | | ✅ pass | 0s |')
    lines.append('')
    keys = ('schema', 'head', 'tree', 'result')
    lines.append('<!-- pre-pr-summary ' + json.dumps({k: summary[k] for k in keys if k in summary}) + ' -->')
    return '\n'.join(lines)

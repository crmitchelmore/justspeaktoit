#!/usr/bin/env python3
"""The CI path routing in scripts/ci/routing.json: evaluate it, and keep the workflows' copies in step.

    python3 scripts/ci/routing.py           fail when a workflow `paths:` list differs from routing.json
    python3 scripts/ci/routing.py --write   rewrite those workflow lists from routing.json

scripts/pre-pr imports this module to decide which checks a changed path selects; routing.mjs is the
same evaluator for Node tooling (auto-revert.mjs), and both are checked against one truth table.
Patterns follow GitHub's path-filter globs (dorny/paths-filter and `on.<event>.paths`):
`**` spans directories, `*` and `?` stay inside one, and dot files match.
"""
from __future__ import annotations

import functools
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ROUTING = Path(__file__).resolve().with_name('routing.json')


@functools.cache
def routes() -> dict[str, dict]:
    data = json.loads(ROUTING.read_text(encoding='utf-8'))['routes']
    for name, route in data.items():
        if route.get('quantifier', 'some') == 'some' and any(p.startswith('!') for p in route['paths']):
            raise ValueError(f'routing.json: {name}: negated patterns need "quantifier": "every"')
    return data


@functools.cache
def glob_regex(pattern: str) -> re.Pattern:
    out, i = '', 0
    while i < len(pattern):
        if pattern.startswith('**/', i):
            out, i = out + '(?:.*/)?', i + 3
        elif pattern.startswith('**', i):
            out, i = out + '.*', i + 2
        elif pattern[i] == '*':
            out, i = out + '[^/]*', i + 1
        elif pattern[i] == '?':
            out, i = out + '[^/]', i + 1
        else:
            out, i = out + re.escape(pattern[i]), i + 1
    return re.compile(out + r'\Z')


def glob(path: str, pattern: str) -> bool:
    return bool(glob_regex(pattern).match(path))


def matches(name: str, path: str, pre_pr: bool = False) -> bool:
    """Whether path selects the route. pre_pr adds the route's pre-pr-only paths."""
    route = routes()[name]
    if route.get('quantifier') == 'every':
        return all(not glob(path, p[1:]) if p.startswith('!') else glob(path, p) for p in route['paths'])
    extra = route.get('prePrAlso', []) if pre_pr else []
    return any(glob(path, p) for p in [*route['paths'], *extra])


def _locate(lines: list[str], target: dict) -> tuple[int, int, str, str]:
    """(first item line, end line, indent, quote) of a workflow list, comments inside it included."""
    start = lines.index(target['after']) + 1 if 'after' in target else 0
    header = lines.index(target['list'], start)
    first = next(i for i in range(header + 1, len(lines)) if lines[i].lstrip().startswith('- '))
    indent = lines[first][:len(lines[first]) - len(lines[first].lstrip())]
    end = first
    while end < len(lines) and lines[end].startswith(indent) and lines[end].lstrip()[:2] in ('- ', '# '):
        end += 1
    quote = "'" if lines[first].lstrip()[2:3] == "'" else ''
    return header + 1, end, indent, quote


def workflow_lists() -> list[tuple[str, dict, list[str]]]:
    """(route, target, items) for every workflow list routing.json owns."""
    found = []
    for name, route in routes().items():
        for target in route.get('workflows', []):
            lines = (ROOT / target['file']).read_text(encoding='utf-8').split('\n')
            first, end, _, _ = _locate(lines, target)
            items = [line.strip()[2:].strip("'\"") for line in lines[first:end] if line.lstrip().startswith('- ')]
            found.append((name, target, items))
    return found


def drift() -> list[str]:
    return [f'{target["file"]} {target.get("after", "").strip()} {target["list"].strip()} differs from '
            f'routing.json "{name}"' for name, target, items in workflow_lists() if items != routes()[name]['paths']]


def write() -> None:
    for route in routes().values():
        for target in route.get('workflows', []):
            path = ROOT / target['file']
            lines = path.read_text(encoding='utf-8').split('\n')
            first, end, indent, quote = _locate(lines, target)
            lines[first:end] = [f'{indent}- {quote}{p}{quote}' for p in route['paths']]
            path.write_text('\n'.join(lines), encoding='utf-8')


def main(argv: list[str]) -> int:
    if argv == ['--write']:
        write()
        return 0
    if argv:
        print(__doc__, file=sys.stderr)
        return 2
    problems = drift()
    for problem in problems:
        print(f'routing: {problem}; run python3 scripts/ci/routing.py --write', file=sys.stderr)
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

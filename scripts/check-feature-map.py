#!/usr/bin/env python3
"""Keep Docs/feature-map.md honest.

Checks that every feature ID is unique, the summary table and the per-feature
entries agree, every status is a known value, every gap has an issue, every
exclusion has a reason, and every repository path or relative link the map
cites exists.
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAP = ROOT / "Docs/feature-map.md"
PLATFORMS = ("macOS", "iOS", "Windows", "Linux", "Android")
STATUSES = {"Yes", "Partial", "Limited", "No", "N/A"}
FIELDS = ("Platforms", "Excluded", "Gaps", "How", "Refs", "Sunset", "Nuances")
PATH_ROOTS = (
    "Sources/", "Tests/", "Docs/", "scripts/", "android/", "Config/", "Resources/",
    "workers/", "landing-page/", ".github/", "Project.swift", "Package.swift", "Makefile",
)

ROW = re.compile(r"^\| F\d{2} \|")
HEADING = re.compile(r"^### (F\d{2}) (.+)$")
FIELD = re.compile(r"^- \*\*(\w+):\*\* (.*)$")
ISSUE = re.compile(r"#(\d+)")
CODE = re.compile(r"`([^`]+)`")
LINK = re.compile(r"\]\(([^)#:]+)(?:#[^)]*)?\)")


@dataclass
class Entry:
    fid: str
    name: str
    fields: dict[str, str]


def parse(text: str) -> tuple[list[tuple[str, str, dict[str, str], str]], list[Entry]]:
    rows = []
    entries: list[Entry] = []
    for line in text.splitlines():
        if ROW.match(line):
            cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
            fid, name, *statuses = cells[: 2 + len(PLATFORMS)]
            issues = cells[2 + len(PLATFORMS)] if len(cells) > 2 + len(PLATFORMS) else ""
            rows.append((fid, name, dict(zip(PLATFORMS, statuses)), issues))
        elif match := HEADING.match(line):
            entries.append(Entry(match.group(1), match.group(2).strip(), {}))
        elif entries and (match := FIELD.match(line)):
            entries[-1].fields[match.group(1)] = match.group(2)
    return rows, entries


def platform_statuses(value: str) -> dict[str, str]:
    result = {}
    for part in value.split(" · "):
        platform, _, status = part.strip().partition(" ")
        result[platform] = status.strip()
    return result


def cited_paths(text: str) -> list[str]:
    paths = []
    for literal in CODE.findall(text):
        if literal.startswith(PATH_ROOTS) and " " not in literal:
            paths.append(literal.rstrip("/"))
    return paths


def check(text: str, root: Path = ROOT) -> list[str]:
    errors: list[str] = []
    rows, entries = parse(text)
    if not rows:
        errors.append("no summary table rows found")
    for kind, ids in (("table row", [r[0] for r in rows]), ("entry", [e.fid for e in entries])):
        seen = set()
        for fid in ids:
            if fid in seen:
                errors.append(f"duplicate {kind} {fid}")
            seen.add(fid)
    if [r[0] for r in rows] != [e.fid for e in entries]:
        errors.append("summary table IDs and entry headings differ or are out of order")

    by_id = {e.fid: e for e in entries}
    for fid, name, statuses, issues in rows:
        for platform, status in statuses.items():
            if status not in STATUSES:
                errors.append(f"{fid}: unknown {platform} status {status!r}")
        entry = by_id.get(fid)
        if entry is None:
            continue
        if entry.name != name:
            errors.append(f"{fid}: table name {name!r} differs from heading {entry.name!r}")
        missing = [f for f in FIELDS if f not in entry.fields]
        if missing:
            errors.append(f"{fid}: missing fields {', '.join(missing)}")
            continue
        if platform_statuses(entry.fields["Platforms"]) != statuses:
            errors.append(f"{fid}: Platforms line does not match the summary table")
        gaps = [p for p, s in statuses.items() if s in {"No", "Partial"}]
        if gaps and not ISSUE.search(entry.fields["Gaps"]):
            errors.append(f"{fid}: {', '.join(gaps)} gap needs an issue in Gaps")
        if gaps and not ISSUE.search(issues):
            errors.append(f"{fid}: {', '.join(gaps)} gap needs an issue in the summary table")
        if not gaps and entry.fields["Gaps"] != "none":
            errors.append(f"{fid}: Gaps must be 'none' when no platform is No or Partial")
        excluded = [p for p, s in statuses.items() if s == "N/A"]
        reason = entry.fields["Excluded"]
        if excluded and not all(p in reason for p in excluded):
            errors.append(f"{fid}: Excluded must name and explain {', '.join(excluded)}")
        if excluded and not re.search(r"\((OS|owner decision)", reason):
            errors.append(f"{fid}: Excluded must say '(OS' or '(owner decision'")
        if not excluded and reason != "none":
            errors.append(f"{fid}: Excluded must be 'none' when no platform is N/A")
        if not cited_paths(entry.fields["Refs"]):
            errors.append(f"{fid}: Refs cites no repository path")

    for path in sorted(set(cited_paths(text))):
        if not (root / path).exists():
            errors.append(f"cited path does not exist: {path}")
    for link in sorted(set(LINK.findall(text))):
        if not (root / "Docs" / link).resolve().exists():
            errors.append(f"linked file does not exist: {link}")
    return errors


def main() -> int:
    errors = check(MAP.read_text(encoding="utf-8"))
    for error in errors:
        print(f"Docs/feature-map.md: {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())

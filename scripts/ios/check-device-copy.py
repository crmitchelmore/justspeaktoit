#!/usr/bin/env python3
"""Fail on iPhone-only copy in the iOS app, which also runs on iPad (#1598).

Scans the string literals (not comments) of every Swift file under
Sources/SpeakiOS for "iPhone" or "Dynamic Island". Route device names through
DeviceCopy ("this iPhone"/"this iPad"/"this device") and mention the Dynamic
Island only through DeviceCopy.liveActivityPlacement. Copy that is genuinely
iPhone-only and says so (for example the Action Button) goes in ALLOWLIST.
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE_DIR = "Sources/SpeakiOS"
# Case-sensitive "iPhone" so SF Symbol names such as "lock.iphone" pass.
PATTERN = re.compile(r"iPhone|[Dd]ynamic [Ii]sland")

# The helper that owns the idiom-aware wording.
EXEMPT_FILES = {"Sources/SpeakiOS/Views/DeviceCopy.swift"}

# (path, literal substring): conditional copy about hardware only iPhones have.
ALLOWLIST: set[tuple[str, str]] = {
    ("Sources/SpeakiOS/Views/Settings/HardwareTriggerSettingsView.swift", "On an iPhone with an Action Button"),
    ("Sources/SpeakiOS/Views/Settings/HardwareTriggerSettingsView.swift", "On a supported iPhone, open Settings"),
    ("Sources/SpeakiOS/Views/HistoryItemRow.swift", "iPhone or iPad"),
}


@dataclass(frozen=True)
class Finding:
    path: str
    line: int
    literal: str

    def __str__(self) -> str:
        return f"{self.path}:{self.line}: iPhone-only copy in {self.literal!r}"


def string_literals(source: str) -> list[tuple[int, str]]:
    """Return (line, text) for each string literal segment outside comments.

    Interpolated expressions are scanned too, so a literal nested in `\\(…)`
    is still reported.
    """
    literals: list[tuple[int, str]] = []
    i, n, line = 0, len(source), 1

    def scan_string(start: int, start_line: int) -> tuple[int, int]:
        multiline = source.startswith('"""', start)
        quote = '"""' if multiline else '"'
        j, current_line = start + len(quote), start_line
        buffer: list[str] = []
        segment_line = current_line
        while j < n:
            if source.startswith(quote, j):
                literals.append((segment_line, "".join(buffer)))
                return j + len(quote), current_line
            ch = source[j]
            if ch == "\\" and source.startswith("\\(", j):
                literals.append((segment_line, "".join(buffer)))
                buffer = []
                j, current_line = scan_code(j + 2, current_line, until_paren=True)
                segment_line = current_line
                continue
            if ch == "\\" and j + 1 < n:
                buffer.append(source[j : j + 2])
                j += 2
                continue
            if ch == "\n":
                if not multiline:
                    break
                current_line += 1
            buffer.append(ch)
            j += 1
        literals.append((segment_line, "".join(buffer)))
        return j, current_line

    def scan_code(start: int, start_line: int, until_paren: bool) -> tuple[int, int]:
        j, current_line, depth = start, start_line, 0
        while j < n:
            ch = source[j]
            if source.startswith("//", j):
                end = source.find("\n", j)
                j = n if end == -1 else end
                continue
            if source.startswith("/*", j):
                nesting, j = 1, j + 2
                while j < n and nesting:
                    if source.startswith("/*", j):
                        nesting, j = nesting + 1, j + 2
                    elif source.startswith("*/", j):
                        nesting, j = nesting - 1, j + 2
                    else:
                        current_line += source[j] == "\n"
                        j += 1
                continue
            if ch == '"':
                j, current_line = scan_string(j, current_line)
                continue
            if ch == "\n":
                current_line += 1
            elif until_paren and ch == "(":
                depth += 1
            elif until_paren and ch == ")":
                if depth == 0:
                    return j + 1, current_line
                depth -= 1
            j += 1
        return j, current_line

    scan_code(i, line, until_paren=False)
    return literals


def scan_source(path: str, source: str) -> list[Finding]:
    if path in EXEMPT_FILES:
        return []
    allowed = [snippet for allowed_path, snippet in ALLOWLIST if allowed_path == path]
    findings = []
    for line, literal in string_literals(source):
        if PATTERN.search(literal) and not any(snippet in literal for snippet in allowed):
            findings.append(Finding(path, line, literal))
    return findings


def scan(root: Path = ROOT) -> list[Finding]:
    findings: list[Finding] = []
    for file in sorted((root / SOURCE_DIR).rglob("*.swift")):
        relative = file.relative_to(root).as_posix()
        findings.extend(scan_source(relative, file.read_text(encoding="utf-8")))
    return findings


def main() -> int:
    findings = scan()
    for finding in findings:
        print(finding)
    if findings:
        print(
            f"\n{len(findings)} iPhone-only string(s) in {SOURCE_DIR}; the iOS app also runs on iPad. "
            "Use DeviceCopy, or add genuinely iPhone-only copy to ALLOWLIST in scripts/ios/check-device-copy.py.",
            file=sys.stderr,
        )
        return 1
    print(f"Device copy: no iPhone-only strings in {SOURCE_DIR}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

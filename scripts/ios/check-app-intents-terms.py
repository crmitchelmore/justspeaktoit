#!/usr/bin/env python3
"""Fail when App Intents metadata names Siri or an Apple device.

App Store Connect rejects an upload after it has been accepted, with ITMS-90626
"Invalid Siri Support", when any App Intent title, description, parameter,
entity, enum or App Shortcut phrase contains "siri" or "iphone" (case
insensitive). Apple publishes no full list, so this guards those two plus the
other Apple product and assistant names that Apple's intent phrase guidance
forbids. Write "this device", "the watch" or "voice" instead.

Default mode scans the Swift sources of every target that imports AppIntents,
reading only the strings that become metadata (IntentDescription, titles,
@Parameter, AppShortcut phrases, display representations and summaries).
`--metadata` scans built bundles' compiled `Metadata.appintents`, which is
exactly what Apple validates.

Usage: check-app-intents-terms.py [--root DIR] [--metadata PATH ...]
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# "siri" and "iphone" are the terms Apple's validator has reported for this
# app (ITMS-90626, Nov 2026); the rest are the same class of reserved names.
BANNED_TERMS = (
    "siri",
    "iphone",
    "ipad",
    "ipod",
    "apple watch",
    "apple tv",
    "apple vision",
    "vision pro",
    "airpods",
    "homepod",
    "carplay",
)

# Calls whose string arguments are compiled into App Intents metadata.
METADATA_CALLS = (
    "IntentDescription",
    "AppShortcut",
    "DisplayRepresentation",
    "TypeDisplayRepresentation",
    "LocalizedStringResource",
    "Summary",
    "Parameter",
)
# `static var <name>` declarations whose value is metadata.
METADATA_PROPERTIES = (
    "title",
    "description",
    "typeDisplayRepresentation",
    "caseDisplayRepresentations",
    "typeDisplayName",
)
# Labels whose string is an SF Symbol or identifier, never shown as text.
NON_TEXT_LABELS = {"systemImageName", "systemImage", "systemName", "image", "identifier"}


def banned_terms_in(text: str) -> list[str]:
    folded = " ".join(text.casefold().split())
    return [term for term in BANNED_TERMS if term in folded]


# --- Swift source scanning -------------------------------------------------


def _skip_interpolation(source: str, index: int) -> int:
    """Return the index after the `)` closing a `\\(` interpolation."""
    depth = 1
    while index < len(source) and depth:
        char = source[index]
        if char == '"':
            index = _read_string(source, index)[1]
            continue
        depth += {"(": 1, ")": -1}.get(char, 0)
        index += 1
    return index


def _read_string(source: str, index: int) -> tuple[str, int]:
    """Read the literal starting at `index`; return its text and end index."""
    hashes = 0
    while source[index] == "#":
        hashes += 1
        index += 1
    multiline = source.startswith('"""', index)
    delimiter = ('"""' if multiline else '"') + "#" * hashes
    index += 3 if multiline else 1
    escape = "\\" + "#" * hashes
    text = []
    while index < len(source):
        if source.startswith(delimiter, index):
            return "".join(text), index + len(delimiter)
        if source.startswith(escape, index):
            index += len(escape)
            following = source[index] if index < len(source) else ""
            if following == "(":
                index = _skip_interpolation(source, index + 1)
                text.append(" ")
            elif following == "\n":  # Multi-line continuation.
                index += 1
            else:
                text.append({"n": " ", "t": " "}.get(following, following))
                index += 1
            continue
        text.append(" " if source[index] == "\n" else source[index])
        index += 1
    return "".join(text), index


def tokenize(source: str) -> list[tuple[str, str]]:
    """Tokens as (kind, value): kinds are str, ident, punct. Comments drop."""
    tokens: list[tuple[str, str]] = []
    index = 0
    while index < len(source):
        char = source[index]
        if source.startswith("//", index):
            index = source.find("\n", index)
            index = len(source) if index < 0 else index
        elif source.startswith("/*", index):
            end = source.find("*/", index + 2)
            index = len(source) if end < 0 else end + 2
        elif char == '"' or (char == "#" and re.match(r'#+"', source[index:])):
            text, index = _read_string(source, index)
            tokens.append(("str", text))
        elif char.isalpha() or char == "_":
            match = re.match(r"[A-Za-z_][A-Za-z0-9_]*", source[index:])
            tokens.append(("ident", match.group()))
            index += len(match.group())
        elif char.isspace():
            index += 1
        else:
            tokens.append(("punct", char))
            index += 1
    return tokens


def _balanced_end(tokens, start: int) -> int:
    """Index just past the group opened at `start` ((, [ or {)."""
    pairs = {"(": ")", "[": "]", "{": "}"}
    depth = 0
    for index in range(start, len(tokens)):
        kind, value = tokens[index]
        if kind != "punct":
            continue
        if value in pairs:
            depth += 1
        elif value in pairs.values():
            depth -= 1
            if depth == 0:
                return index + 1
    return len(tokens)


def _strings(tokens, start: int, end: int) -> list[str]:
    """Text literals in tokens[start:end], joining `"a" + "b"` concatenations."""
    found: list[str] = []
    joining = False
    for index in range(start, end):
        kind, value = tokens[index]
        if kind == "str":
            label = tokens[index - 2][1] if index >= 2 and tokens[index - 1] == ("punct", ":") else None
            if label in NON_TEXT_LABELS:
                joining = False
                continue
            if joining and found:
                found[-1] += value
            else:
                found.append(value)
            joining = index + 1 < end and tokens[index + 1] == ("punct", "+")
        elif (kind, value) != ("punct", "+"):
            joining = False
    return found


def _property_value_end(tokens, index: int) -> int:
    """End of a property's value whose `=` or `{` is at `index`."""
    if tokens[index][1] == "{":
        return _balanced_end(tokens, index)
    index += 1
    end = index
    while end < len(tokens):
        kind, value = tokens[end]
        if kind == "str" or value == "+":
            end += 1
        elif value in ("(", "["):
            end = _balanced_end(tokens, end)
        elif kind == "ident" and end + 1 < len(tokens) and tokens[end + 1][1] in ("(", "."):
            end += 1
        elif value == ".":
            end += 1
        else:
            break
    return end


def metadata_strings(source: str) -> list[str]:
    tokens = tokenize(source)
    found: list[str] = []
    for index, (kind, value) in enumerate(tokens):
        if kind != "ident":
            continue
        following = tokens[index + 1] if index + 1 < len(tokens) else ("", "")
        if value in METADATA_CALLS and following == ("punct", "("):
            if value == "Parameter" and (index == 0 or tokens[index - 1] != ("punct", "@")):
                continue
            found += _strings(tokens, index + 1, _balanced_end(tokens, index + 1))
        elif value in METADATA_PROPERTIES and "static" in (tok[1] for tok in tokens[max(0, index - 3) : index - 1]):
            cursor = index + 1
            if tokens[cursor] == ("punct", ":"):  # Skip the type annotation.
                while cursor < len(tokens) and tokens[cursor][1] not in ("=", "{"):
                    cursor = _balanced_end(tokens, cursor) if tokens[cursor][1] == "[" else cursor + 1
            if cursor < len(tokens) and tokens[cursor][1] in ("=", "{"):
                found += _strings(tokens, cursor, _property_value_end(tokens, cursor))
    return found


def intent_sources(root: Path) -> list[Path]:
    listed = subprocess.run(["git", "ls-files", "*.swift"], cwd=root, capture_output=True, text=True, check=True)
    paths = [root / line for line in listed.stdout.splitlines() if not line.startswith("Tests/")]
    return [path for path in paths if path.is_file()
            and re.search(r"^\s*(@preconcurrency\s+)?import\s+AppIntents\b", path.read_text(), re.M)]


def scan_sources(root: Path) -> list[str]:
    findings = []
    for path in intent_sources(root):
        for text in dict.fromkeys(" ".join(text.split()) for text in metadata_strings(path.read_text())):
            for term in banned_terms_in(text):
                findings.append(f'{path.relative_to(root)}: "{term}" in App Intents metadata: "{text}"')
    return findings


# --- Compiled Metadata.appintents scanning ---------------------------------


def localized_strings(node, path="$"):
    """Yield (json path, text) for every localized string in actionsdata."""
    if isinstance(node, dict):
        if isinstance(node.get("key"), str) and isinstance(node.get("alternatives"), list):
            yield path, node["key"]
            for offset, alternative in enumerate(node["alternatives"]):
                if isinstance(alternative, str):
                    yield f"{path}.alternatives[{offset}]", alternative
        for key, value in node.items():
            yield from localized_strings(value, f"{path}.{key}")
    elif isinstance(node, list):
        for offset, value in enumerate(node):
            yield from localized_strings(value, f"{path}[{offset}]")


def metadata_findings(metadata) -> list[str]:
    return [f'{path}: "{term}" in "{text}"'
            for path, text in localized_strings(metadata) for term in banned_terms_in(text)]


def scan_metadata(paths: list[Path]) -> list[str]:
    files = []
    for path in paths:
        if path.name == "extract.actionsdata":
            files.append(path)
        else:
            files += sorted(path.rglob("Metadata.appintents/extract.actionsdata"))
    if not files:
        raise SystemExit(f"No Metadata.appintents found under {', '.join(map(str, paths))}")
    findings = []
    for file in files:
        try:
            metadata = json.loads(file.read_text())
        except (OSError, ValueError) as error:
            raise SystemExit(f"Unreadable App Intents metadata: {file}: {error}") from error
        findings += [f"{file}: {finding}" for finding in metadata_findings(metadata)]
    return findings


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--metadata", type=Path, nargs="+", help="built bundles or extract.actionsdata files")
    args = parser.parse_args(argv)
    findings = scan_metadata(args.metadata) if args.metadata else scan_sources(args.root)
    for finding in findings:
        print(f"error: {finding}", file=sys.stderr)
    if findings:
        print(f"ITMS-90626: {len(findings)} App Intents metadata string(s) name Siri or an Apple device. "
              "Apple rejects the upload; describe the action without them.", file=sys.stderr)
        return 1
    print("App Intents metadata names no Siri or Apple device terms")
    return 0


if __name__ == "__main__":
    sys.exit(main())

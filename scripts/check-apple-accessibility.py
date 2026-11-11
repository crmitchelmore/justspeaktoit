#!/usr/bin/env python3
"""Static accessibility guard for the Apple SwiftUI apps.

Fails when an interactive SwiftUI view cannot be named by VoiceOver or by an
agent driving the accessibility tree. See Docs/accessibility.md.

Rules (each finding names the rule):
  icon-only-control   Button/Menu/Link whose label is only an Image, with no
                      .accessibilityLabel in its modifier chain.
  unlabelled-image-button
                      Image(systemName:)/Image(_:) passed straight to
                      Button(action:label:) shorthand without a label.
  empty-control-label Toggle/Picker/TextField/SecureField/Slider/Stepper/
                      DatePicker/ColorPicker titled "" with no
                      .accessibilityLabel.
  tap-without-trait   .onTapGesture/.onLongPressGesture on a view that has
                      neither the .isButton trait nor an accessibility action.
  icon-only-missing-id
                      icon-only control (labelled) with no
                      .accessibilityIdentifier, so agents cannot target it
                      stably.
  unlabelled-segmented-picker
                      iOS Picker with .pickerStyle(.segmented) and no
                      .accessibilityLabel or .accessibilityIdentifier: UIKit's
                      segmented control drops the Picker title, so the control
                      itself has no name.

Suppress a deliberate exception with `// a11y-ignore: <reason>` on the line of
the control or the line above it.
"""
from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCAN_DIRS = (
    "Sources/SpeakApp",
    "Sources/SpeakiOS",
    "SpeakiOSApp",
    "JustSpeakKeyboard",
    "JustSpeakShare",
    "JustSpeakToItWidgetExtension",
    "JustSpeakWatch",
    "JustSpeakWatchWidget",
)

LABEL_MODIFIERS = (".accessibilityLabel(", ".accessibilityElement(children: .combine")
ID_MODIFIER = ".accessibilityIdentifier("
TAP_OK = (
    ".isButton",
    ".accessibilityAction",
    ".accessibilityHidden(true)",
    ".accessibilityRepresentation",
)
TEXTUAL = re.compile(r'\b(Text|Label|TextField|LabeledContent)\s*\(|"')
ICON = re.compile(r"\bImage\s*\(")
EMPTY_TITLE = re.compile(
    r'\b(Toggle|Picker|TextField|SecureField|DatePicker|ColorPicker|Stepper)\s*\(\s*""'
)


@dataclass(frozen=True)
class Finding:
    path: str
    line: int
    rule: str
    detail: str

    def __str__(self) -> str:
        return f"{self.path}:{self.line}: {self.rule}: {self.detail}"


def mask(source: str) -> str:
    """Blank comments and string contents (keeping quotes and newlines)."""
    out = list(source)
    i, n = 0, len(source)
    while i < n:
        c = source[i]
        if source.startswith("//", i):
            while i < n and source[i] != "\n":
                out[i] = " "
                i += 1
        elif source.startswith("/*", i):
            while i < n and not source.startswith("*/", i):
                if source[i] != "\n":
                    out[i] = " "
                i += 1
            for k in range(i, min(i + 2, n)):
                out[k] = " "
            i += 2
        elif source.startswith('"""', i):
            j = source.find('"""', i + 3)
            j = n if j < 0 else j
            for k in range(i + 3, j):
                if source[k] != "\n":
                    out[k] = " "
            i = j + 3
        elif c == '"':
            j = i + 1
            depth = 0
            while j < n and source[j] != "\n":
                if source[j] == "\\" and j + 1 < n and source[j + 1] == "(":
                    depth += 1
                    j += 2
                    continue
                if depth and source[j] == ")":
                    depth -= 1
                elif source[j] == "\\":
                    j += 1
                elif source[j] == '"' and not depth:
                    break
                j += 1
            # Keep a marker so `Text("")` still reads as textual and `""` stays detectable.
            for k in range(i + 1, j):
                out[k] = "x"
            i = j + 1
        else:
            i += 1
    return "".join(out)


def match_close(text: str, start: int) -> int:
    """Index after the bracket that closes text[start]."""
    pairs = {"(": ")", "{": "}", "[": "]"}
    stack = [pairs[text[start]]]
    i = start + 1
    while i < len(text) and stack:
        c = text[i]
        if c in pairs:
            stack.append(pairs[c])
        elif stack and c == stack[-1]:
            stack.pop()
        i += 1
    return i


def strip_images(label: str) -> str:
    """Drop Image(...) calls so their asset/symbol names do not read as titles."""
    out, i = [], 0
    for m in ICON.finditer(label):
        if m.start() < i:
            continue
        out.append(label[i:m.start()])
        i = match_close(label, m.end() - 1)
    out.append(label[i:])
    return "".join(out)


def skip_ws(text: str, i: int) -> int:
    while i < len(text) and text[i] in " \t\r\n":
        i += 1
    return i


def control_extent(text: str, start: int) -> tuple[int, str]:
    """Return (end index, label text) for a control call starting at `start`."""
    i = start
    while i < len(text) and (text[i].isalnum() or text[i] == "_"):
        i += 1
    label = ""
    args = ""
    if i < len(text) and text[i] == "(":
        end = match_close(text, i)
        args = text[i + 1:end - 1]
        i = end
    closures = []
    while True:
        j = skip_ws(text, i)
        m = re.match(r"[A-Za-z_]+\s*:\s*\{", text[j:])
        if j < len(text) and text[j] == "{":
            end = match_close(text, j)
            closures.append(("", text[j + 1:end - 1]))
            i = end
        elif m and closures:
            b = j + m.end() - 1
            end = match_close(text, b)
            closures.append((m.group(0).split(":")[0].strip(), text[b + 1:end - 1]))
            i = end
        else:
            break
    named = {name: body for name, body in closures if name}
    if "label" in named:
        label = named["label"]
    elif closures and LABEL_IN_CLOSURE.search(args):
        label = closures[0][1]
    else:
        label = args
    return i, label


LABEL_IN_CLOSURE = re.compile(r"\b(action|destination|intent|item|primaryAction)\s*:")


def modifier_chain(text: str, i: int) -> str:
    """Text of the `.modifier(...)` chain that follows index i."""
    start = i
    while True:
        j = skip_ws(text, i)
        if j < len(text) and text[j] == "." and j + 1 < len(text) and text[j + 1].isalpha():
            k = j + 1
            while k < len(text) and (text[k].isalnum() or text[k] == "_"):
                k += 1
            while k < len(text) and text[k] in "({":
                k = match_close(text, k)
                k2 = skip_ws(text, k)
                if k2 < len(text) and text[k2] == "{":
                    k = k2
            i = k
        else:
            return text[start:i]


def enclosing_chain(text: str, pos: int) -> str:
    """Modifier chain containing a modifier at `pos`, walking back to the view."""
    line_start = text.rfind("\n", 0, pos) + 1
    indent = len(text[line_start:pos]) - len(text[line_start:pos].lstrip())
    # Walk back over sibling modifier lines (and their nested bodies).
    cur = line_start
    while cur > 0:
        prev_start = text.rfind("\n", 0, cur - 1) + 1
        line = text[prev_start:cur]
        stripped = line.lstrip()
        ind = len(line) - len(stripped)
        if not stripped.strip():
            cur = prev_start
            continue
        if ind > indent or (ind == indent and stripped.startswith(".")) or stripped.startswith("}") or stripped.startswith(")"):
            cur = prev_start
            continue
        cur = prev_start
        break
    # Forward over the chain.
    end = pos
    while end < len(text):
        nl = text.find("\n", end)
        if nl < 0:
            end = len(text)
            break
        nxt_end = text.find("\n", nl + 1)
        nxt_end = len(text) if nxt_end < 0 else nxt_end
        line = text[nl + 1:nxt_end]
        stripped = line.lstrip()
        ind = len(line) - len(stripped)
        if stripped and (ind > indent or (ind == indent and (stripped.startswith(".") or stripped[0] in "})]"))):
            end = nxt_end
            continue
        end = nl
        break
    return text[cur:end]


def ignored(lines: list[str], line_no: int) -> bool:
    for k in (line_no - 1, line_no - 2):
        if 0 <= k < len(lines) and "a11y-ignore:" in lines[k]:
            return True
    return False


# macOS draws and exposes a segmented Picker's title; iOS does not.
SEGMENTED_UNNAMED_DIRS = tuple(d for d in SCAN_DIRS if d != "Sources/SpeakApp")
PICKER = re.compile(r"(?<![\w.])Picker\s*\(")


CONTROL = re.compile(r"(?<![\w.])(Button|Menu|Link|ShareLink)\s*[({]")


def scan_source(path: str, source: str) -> list[Finding]:
    text = mask(source)
    lines = source.splitlines()
    findings: list[Finding] = []

    def line_of(pos: int) -> int:
        return text.count("\n", 0, pos) + 1

    for m in CONTROL.finditer(text):
        start = m.start()
        end, label = control_extent(text, start)
        if not ICON.search(label) or TEXTUAL.search(strip_images(label)):
            continue
        # A label built from a helper (e.g. `rowLabel`) is opaque; only flag
        # labels that are visibly just images.
        chain = modifier_chain(text, end)
        ln = line_of(start)
        if ignored(lines, ln):
            continue
        if not any(mod in chain or mod in label for mod in LABEL_MODIFIERS):
            findings.append(Finding(path, ln, "icon-only-control",
                                    f"{m.group(1)} shows only an image; add .accessibilityLabel"))
        elif ID_MODIFIER not in chain:
            findings.append(Finding(path, ln, "icon-only-missing-id",
                                    f"{m.group(1)} is icon-only; add .accessibilityIdentifier"))

    for m in EMPTY_TITLE.finditer(text):
        end, _ = control_extent(text, m.start())
        chain = modifier_chain(text, end)
        ln = line_of(m.start())
        if ignored(lines, ln) or any(mod in chain for mod in LABEL_MODIFIERS):
            continue
        findings.append(Finding(path, ln, "empty-control-label",
                                f'{m.group(1)}("") has no accessible name; add .accessibilityLabel'))

    if path.startswith(SEGMENTED_UNNAMED_DIRS):
        for m in PICKER.finditer(text):
            end, _ = control_extent(text, m.start())
            chain = modifier_chain(text, end)
            ln = line_of(m.start())
            if ".pickerStyle(.segmented)" not in chain or ignored(lines, ln):
                continue
            missing = [mod for mod in (".accessibilityLabel(", ID_MODIFIER) if mod not in chain]
            if missing:
                findings.append(Finding(path, ln, "unlabelled-segmented-picker",
                                        "segmented Picker needs " + " and ".join(m[1:-1] for m in missing)))

    for m in re.finditer(r"\.(onTapGesture|onLongPressGesture)\b", text):
        chain = enclosing_chain(text, m.start())
        ln = line_of(m.start())
        if ignored(lines, ln) or any(ok in chain for ok in TAP_OK):
            continue
        findings.append(Finding(path, ln, "tap-without-trait",
                                f".{m.group(1)} needs .accessibilityAddTraits(.isButton) or an accessibility action"))
    return findings


def scan(root: Path = ROOT) -> list[Finding]:
    findings: list[Finding] = []
    for d in SCAN_DIRS:
        for f in sorted((root / d).rglob("*.swift")):
            source = f.read_text(encoding="utf-8")
            if "SwiftUI" not in source:
                continue
            findings.extend(scan_source(str(f.relative_to(root)), source))
    return findings


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.parse_args()
    findings = scan()
    for f in findings:
        print(f)
    if findings:
        print(f"\n{len(findings)} accessibility finding(s). See Docs/accessibility.md.", file=sys.stderr)
        return 1
    print("Apple accessibility check passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

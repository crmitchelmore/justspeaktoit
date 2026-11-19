#!/usr/bin/env python3
"""Fail when a GTK control has no usable accessible name.

GTK uses an icon button's tooltip only as its description, so Orca and
AT-SPI agents see an unnamed button unless the code sets
GTK_ACCESSIBLE_PROPERTY_LABEL on the same widget.

GtkDropDown labels itself by its selected value, which outranks
GTK_ACCESSIBLE_PROPERTY_LABEL, so a drop-down is named with
jsti_accessible_set_name or a mnemonic label instead.

GTK drops an announcement from a widget whose accessibility context is not
realised yet, which is usual for child widgets, so announcements go through
jsti_accessible_announce, which speaks through the window. See Docs/accessibility.md.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ICON_ONLY = re.compile(
    r"(?P<target>[\w.\->\[\]]+)\s*=\s*(?:GTK_\w+\()?\s*"
    r"(?:gtk_button_new_from_icon_name|gtk_toggle_button_new_from_icon_name)\s*\("
)
SET_ICON = re.compile(r"(?:gtk_button_set_icon_name|gtk_menu_button_set_icon_name)\s*\(\s*(?:GTK_\w+\()?\s*(?P<target>[\w.\->\[\]]+)")
DROP_DOWN = re.compile(
    r"(?:(?P<target>[\w.\->\[\]]+)\s*=\s*(?:GTK_\w+\()?\s*)?\bgtk_drop_down_new(?:_from_strings)?\s*\("
)
DROP_DOWN_NAMED = re.compile(r"\b(?:jsti_accessible_set_name|gtk_label_set_mnemonic_widget)\s*\((?P<arguments>[^;]*)\)\s*;")
RAW_ANNOUNCE = re.compile(r"\bgtk_accessible_announce\s*\(")
# The helper that wraps gtk_accessible_announce.
ANNOUNCE_HELPER_FILE = "LinuxWindowStyle.c"
# Lines after a drop-down's construction that may hold its naming call.
DROP_DOWN_WINDOW = 10


def labelled(source: str, target: str) -> bool:
    escaped = re.escape(target)
    return re.search(
        rf"gtk_accessible_update_property\(\s*GTK_ACCESSIBLE\(\s*{escaped}\s*\)\s*,\s*GTK_ACCESSIBLE_PROPERTY_LABEL",
        source,
    ) is not None


def references(arguments: str, names: set[str]) -> bool:
    return any(re.search(rf"(?<![\w.>]){re.escape(name)}(?![\w\[])", arguments) for name in names)


def drop_down_named(target: str | None, window: str) -> bool:
    """True when a naming call in the window refers to this drop-down (or a plain alias of it)."""
    if target is None:
        return False
    names = {target}
    for alias in re.finditer(r"(?P<alias>[\w.\->\[\]]+)\s*=\s*(?P<source>[\w.\->\[\]]+)\s*;", window):
        if alias.group("source") in names:
            names.add(alias.group("alias"))
    return any(references(call.group("arguments"), names) for call in DROP_DOWN_NAMED.finditer(window))


def violations(path: Path) -> list[str]:
    source = path.read_text(encoding="utf-8")
    found = []
    for pattern in (ICON_ONLY, SET_ICON):
        for match in pattern.finditer(source):
            target = match.group("target")
            if not labelled(source, target):
                line = source.count("\n", 0, match.start()) + 1
                found.append(f"{path}:{line}: icon-only control {target} needs GTK_ACCESSIBLE_PROPERTY_LABEL")
    lines = source.splitlines()
    for match in DROP_DOWN.finditer(source):
        line = source.count("\n", 0, match.start())
        window = "\n".join(lines[line:line + DROP_DOWN_WINDOW])
        if not drop_down_named(match.group("target"), window):
            found.append(f"{path}:{line + 1}: drop-down needs jsti_accessible_set_name or a mnemonic label")
    if path.name != ANNOUNCE_HELPER_FILE:
        for match in RAW_ANNOUNCE.finditer(source):
            line = source.count("\n", 0, match.start()) + 1
            found.append(f"{path}:{line}: announce with jsti_accessible_announce, not gtk_accessible_announce")
    return found


def main(arguments: list[str]) -> int:
    roots = [Path(argument) for argument in arguments] or [Path("Sources/CLinuxSupport")]
    files = sorted(file for root in roots for file in ([root] if root.is_file() else root.rglob("*.c")))
    problems = [problem for file in files for problem in violations(file)]
    for problem in problems:
        print(problem, file=sys.stderr)
    print(f"Checked {len(files)} GTK sources: {len(problems)} accessibility problem(s).")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

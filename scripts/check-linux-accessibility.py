#!/usr/bin/env python3
"""Fail when a GTK control has no usable accessible name.

GTK uses an icon button's tooltip only as its description, so Orca and
AT-SPI agents see an unnamed button unless the code sets
GTK_ACCESSIBLE_PROPERTY_LABEL on the same widget.

GtkDropDown labels itself by its selected value, which outranks
GTK_ACCESSIBLE_PROPERTY_LABEL, so a drop-down is named with
jsti_accessible_set_name or a mnemonic label instead. See Docs/accessibility.md.
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
DROP_DOWN = re.compile(r"\bgtk_drop_down_new(?:_from_strings)?\s*\(")
DROP_DOWN_NAMED = re.compile(r"\b(?:jsti_accessible_set_name|gtk_label_set_mnemonic_widget)\s*\(")
# Lines after a drop-down's construction that may hold its naming call.
DROP_DOWN_WINDOW = 10


def labelled(source: str, target: str) -> bool:
    escaped = re.escape(target)
    return re.search(
        rf"gtk_accessible_update_property\(\s*GTK_ACCESSIBLE\(\s*{escaped}\s*\)\s*,\s*GTK_ACCESSIBLE_PROPERTY_LABEL",
        source,
    ) is not None


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
        if DROP_DOWN_NAMED.search(window) is None:
            found.append(f"{path}:{line + 1}: drop-down needs jsti_accessible_set_name or a mnemonic label")
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

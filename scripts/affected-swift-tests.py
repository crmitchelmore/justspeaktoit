#!/usr/bin/env python3
"""Select the SwiftPM test targets a change can affect.

Usage: scripts/affected-swift-tests.py <base-ref> [--skip-target NAME ...]

Maps every changed file under a target's directory to that target, then
selects each test target that depends on it directly or transitively
(`swift package dump-package` supplies the graph). Changes to the package
manifest, shared test support, CI wiring or any file that cannot be mapped
select every test target. --skip-target removes targets proven elsewhere
(the Linux portable job) from the selection.

Prints GitHub output lines:
  mode=all|filtered|none
  filter=<swift test --filter regex>   (mode=filtered)
  skip=<swift test --skip regex>       (mode=all with skipped targets)
  targets=<space-separated selection>
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import re
import subprocess
import sys

GLOBAL = [
    "Package.swift", "Package.resolved", "Makefile", ".github/workflows/ci.yml",
    "Config/*", "Resources/*", "Tests/SpeakTestSupport/*", "Tests/Fixtures/*",
    "scripts/with-test-keychain.py", "scripts/private-test-keychain.py", "scripts/affected-swift-tests.py",
]


def target_paths(package: dict) -> dict[str, str]:
    paths = {}
    for target in package["targets"]:
        if target["type"] in ("plugin", "binary", "macro"):
            continue
        default = "Tests" if target["type"] == "test" else "Sources"
        path = target.get("path") or f"{default}/{target['name']}"
        paths[target["name"]] = path.rstrip("/") + "/"
    return paths


def dependencies(target: dict) -> set[str]:
    names = set()
    for dependency in target["dependencies"]:
        for kind in ("byName", "target"):
            if kind in dependency:
                names.add(dependency[kind][0])
    return names


def select(changed: list[str], package: dict, skip: set[str]) -> tuple[str, list[str]]:
    tests = sorted(t["name"] for t in package["targets"] if t["type"] == "test")
    paths = target_paths(package)
    touched: set[str] = set()
    for path in changed:
        if any(fnmatch.fnmatchcase(path, pattern) for pattern in GLOBAL):
            return "all", [t for t in tests if t not in skip]
        if not path.startswith(("Sources/", "Tests/")):
            continue
        owners = [name for name, prefix in paths.items() if path.startswith(prefix)]
        if not owners:
            return "all", [t for t in tests if t not in skip]
        touched.add(max(owners, key=lambda name: len(paths[name])))
    reverse: dict[str, set[str]] = {}
    for target in package["targets"]:
        for dependency in dependencies(target):
            reverse.setdefault(dependency, set()).add(target["name"])
    affected, queue = set(touched), list(touched)
    while queue:
        for dependent in reverse.get(queue.pop(), ()):
            if dependent not in affected:
                affected.add(dependent)
                queue.append(dependent)
    selected = [t for t in tests if t in affected and t not in skip]
    return ("filtered" if selected else "none"), selected


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("base")
    parser.add_argument("--skip-target", action="append", default=[])
    args = parser.parse_args()
    package = json.loads(subprocess.run(["swift", "package", "dump-package"], check=True,
                                        capture_output=True, text=True).stdout)
    skip = set(args.skip_target)
    diff = subprocess.run(["git", "diff", "--name-only", f"{args.base}...HEAD"], capture_output=True, text=True)
    if diff.returncode != 0:
        # No merge base (shallow or missing base): fail safe by testing everything.
        print(f"::warning::Cannot diff against {args.base} ({diff.stderr.strip()}); running every test target",
              file=sys.stderr)
        changed = ["Package.swift"]
    else:
        changed = diff.stdout.split()
    mode, selected = select(changed, package, skip)
    print(f"mode={mode}")
    print(f"targets={' '.join(selected)}")
    if mode == "filtered":
        print("filter=^(" + "|".join(map(re.escape, selected)) + r")\.")
    elif mode == "all" and skip:
        print("skip=^(" + "|".join(map(re.escape, sorted(skip))) + r")\.")
    print(f"Changed files: {len(changed)}; tests: {mode} {' '.join(selected)}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())

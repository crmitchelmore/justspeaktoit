#!/usr/bin/env python3
"""Select the SwiftPM test targets a change can affect.

Usage: scripts/affected-swift-tests.py <base-ref> [--skip-target NAME ...]

Maps every changed file under a target's directory to that target, then
selects each test target that depends on it directly or transitively
(`swift package dump-package` supplies the graph). Changes to the package
manifest, shared test support, CI wiring or any file that cannot be mapped
select every test target. --skip-target removes targets proven elsewhere
(the Linux portable job) from the selection.

`TargetGraph` is the one reading of the SwiftPM graph: scripts/pre-pr loads
this file and builds its finer type-level selection on the same graph.

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


class TargetGraph:
    """Target ownership and reverse dependencies of one `dump-package` graph."""

    def __init__(self, package: dict):
        self.types = {target["name"]: target["type"] for target in package["targets"]}
        self.paths = target_paths(package)
        self.dependencies = {target["name"]: dependencies(target) for target in package["targets"]}
        self.tests = sorted(name for name, kind in self.types.items() if kind == "test")
        self._dependants: dict[str, set[str]] = {}
        for name, names in self.dependencies.items():
            for dependency in names:
                self._dependants.setdefault(dependency, set()).add(name)

    def owner(self, path: str) -> str | None:
        """The target whose directory most specifically contains path."""
        owners = [name for name, prefix in self.paths.items() if path.startswith(prefix)]
        return max(owners, key=lambda name: len(self.paths[name])) if owners else None

    def dependants(self, names: set[str]) -> set[str]:
        """names plus every target that depends on one of them, transitively."""
        found, queue = set(names), list(names)
        while queue:
            for dependent in self._dependants.get(queue.pop(), ()):
                if dependent not in found:
                    found.add(dependent)
                    queue.append(dependent)
        return found


def select(changed: list[str], package: dict, skip: set[str]) -> tuple[str, list[str]]:
    graph = TargetGraph(package)
    touched: set[str] = set()
    for path in changed:
        if any(fnmatch.fnmatchcase(path, pattern) for pattern in GLOBAL):
            return "all", [t for t in graph.tests if t not in skip]
        if not path.startswith(("Sources/", "Tests/")):
            continue
        owner = graph.owner(path)
        if owner is None:
            return "all", [t for t in graph.tests if t not in skip]
        touched.add(owner)
    affected = graph.dependants(touched)
    selected = [t for t in graph.tests if t in affected and t not in skip]
    return ("filtered" if selected else "none"), selected


def changed_files(base: str) -> list[str] | None:
    """Files the change touches, or None when git cannot tell (fail safe).

    Uses the three-dot merge-base diff when history allows; in a shallow
    checkout of a PR merge commit, the two-dot diff against the base commit
    is exactly the pull request's changes.
    """
    def git(*command: str) -> subprocess.CompletedProcess:
        return subprocess.run(["git", *command], capture_output=True, text=True)

    ranges = [f"{base}...HEAD", base] if git("merge-base", base, "HEAD").returncode == 0 else [base]
    for revision in ranges:
        diff = git("diff", "--name-only", revision, *(["HEAD"] if revision == base else []))
        if diff.returncode == 0:
            return diff.stdout.split()
    return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("base")
    parser.add_argument("--skip-target", action="append", default=[])
    args = parser.parse_args()
    package = json.loads(subprocess.run(["swift", "package", "dump-package"], check=True,
                                        capture_output=True, text=True).stdout)
    skip = set(args.skip_target)
    changed = changed_files(args.base)
    if changed is None:
        print(f"::warning::Cannot diff against {args.base}; running every test target", file=sys.stderr)
        changed = ["Package.swift"]
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

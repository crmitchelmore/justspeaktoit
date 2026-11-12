"""Which Swift unit tests a change can affect, from the SwiftPM target graph.

A changed test file runs its own test types; a changed source file runs every
test file, in a covering test target, that names a type it declares or extends.
The target graph itself is CI's (scripts/ci/affected-swift-tests.py), so
pre-pr's finer selection starts from the targets CI's macOS job would pick.
"""
from __future__ import annotations

import fnmatch
import json
import os
import re
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

from pre_pr.environment import ROOT, affected_selector, read

# Test targets that drive real UI. They are never selected, whatever changed.
UI_TEST_TARGETS = {'SpeakAppUITests', 'SpeakiOSUITests'}

# Test targets the macOS job leaves to Portable Swift (Linux), as ci-macos-debug.yml passes them to
# affected-swift-tests.py.
CI_MACOS_SKIP_TARGETS = {'SpeakDesktopTests', 'SpeakAutomationKitTests'}

# Top-level declarations a test can reference. Private and fileprivate types are invisible to tests.
DECL = re.compile(r'^(?:@[\w.]+(?:\([^)\n]*\))?\s+)*(?:(?:public|package|internal|open|final|indirect|nonisolated)\s+)*'
                  r'(class|struct|enum|protocol|actor|typealias|extension)\s+([A-Za-z_]\w*)', re.M)
TEST_TYPE = re.compile(r'^(?:@[\w.]+(?:\([^)\n]*\))?\s+)*(?:(?:public|internal|private|fileprivate|final)\s+)*'
                       r'(?:class|struct|actor|enum|extension)\s+([A-Za-z_]\w*)', re.M)
# Opt-in test files are wrapped in `#if JSTI_<NAME>_INTEGRATION` and only compile on request.
OPT_IN = re.compile(r'^#if JSTI_\w+_INTEGRATION\b', re.M)
# Imports and line comments name modules and prose, not the types a test exercises.
NOT_CODE = re.compile(r'^\s*(?:@testable\s+)?import\s+.*$|//.*$', re.M)


@dataclass
class Graph:
    """SwiftPM targets of one package graph, from `swift package dump-package`.

    Ownership and dependency walks come from affected-swift-tests.py's TargetGraph, the graph CI's
    macOS job selects with, so pre-pr's finer selection starts from the same targets.
    """
    targets: dict[str, dict]  # name -> {'type', 'path'}
    dump: dict = field(default_factory=dict)
    shared: object = None

    @classmethod
    def from_dump(cls, dump: dict) -> Graph:
        shared = affected_selector().TargetGraph(dump)
        targets = {name: {'type': shared.types[name], 'path': shared.paths[name].rstrip('/')}
                   for name in shared.paths}
        return cls(targets, dump, shared)

    def module_for(self, path: str) -> str | None:
        return self.shared.owner(path)

    def test_targets(self) -> list[str]:
        return [name for name in self.shared.tests if name not in UI_TEST_TARGETS]

    def covering(self, module: str) -> set[str]:
        """Test targets that are, or transitively depend on, module."""
        return self.shared.dependants({module}) & set(self.test_targets())


_GRAPHS: dict[bool, Graph | None] = {}


def load_graph(portable: bool) -> Graph | None:
    """The Apple (portable=False) or portable package graph, or None when SwiftPM can't evaluate it."""
    if portable not in _GRAPHS:
        env = {**os.environ, **({'SPEAK_PORTABLE_CORE': '1'} if portable else {})}
        env.pop('SPEAK_WINDOWS_TARGET', None)
        try:
            result = subprocess.run(['swift', 'package', 'dump-package'], cwd=ROOT, env=env, text=True,
                                    capture_output=True, timeout=300)
            _GRAPHS[portable] = Graph.from_dump(json.loads(result.stdout)) if result.returncode == 0 else None
        except (OSError, ValueError, subprocess.TimeoutExpired):
            _GRAPHS[portable] = None
    return _GRAPHS[portable]


@dataclass
class Selection:
    filters: list[str] = field(default_factory=list)
    targets: set[str] = field(default_factory=set)  # every test target the filters touch


def select_tests(files: list[str], full: bool, graph: Graph, exclude: set[str] = frozenset(),
                 root: Path = ROOT) -> Selection:
    """Pick the unit tests a change can affect.

    A changed test file runs its own test types. A changed source file runs every test file, in any
    test target that depends on its module, that names a type the file declares or extends (or is
    named after it, e.g. Foo+Bar.swift -> Foo*Tests). When nothing names it, the module's own test
    target runs, or every covering target if it has none. --full runs whole covering targets.
    """
    whole: set[str] = set()
    classes: dict[str, set[str]] = {}
    selection = Selection()
    corpus: dict[str, list[tuple[Path, str]]] = {}

    def test_files(target: str) -> list[tuple[Path, str]]:
        if target not in corpus:
            directory = root / graph.targets[target]['path']
            corpus[target] = [(p, NOT_CODE.sub('', read(p))) for p in sorted(directory.rglob('*.swift'))]
        return corpus[target]

    def add_file(target: str, path: Path, text: str) -> bool:
        if OPT_IN.search(text):  # compiled out by default, so it has no tests to run
            return False
        names = TEST_TYPE.findall(text) or [path.stem.split('+')[0]]
        classes.setdefault(target, set()).update(re.escape(name) for name in names)
        return True

    for path in files:
        if not path.endswith('.swift') or not path.startswith(('Sources/', 'Tests/')):
            continue
        module = graph.module_for(path)
        covering = graph.covering(module) - set(exclude) if module else set()
        if not covering:
            continue
        if full:
            whole |= covering
            continue
        file = root / path
        if module in covering:  # a test file: run the types it declares
            if file.is_file():
                add_file(module, file, NOT_CODE.sub('', read(file)))
            continue
        text = read(file)
        local = {name for kind, name in DECL.findall(text) if kind != 'extension'}
        module_dir = root / graph.targets[module]['path']
        declared_in_module = None
        for kind, name in DECL.findall(text):
            if kind == 'extension' and name not in local:
                if declared_in_module is None:
                    declared_in_module = {n for p in module_dir.rglob('*.swift')
                                          for k, n in DECL.findall(read(p)) if k != 'extension'}
                if name in declared_in_module:
                    local.add(name)
        prefix = Path(path).stem.split('+')[0]
        mention = re.compile(r'\b(?:' + '|'.join(sorted(map(re.escape, local))) + r')\b') if local else None
        matched = False
        for target in sorted(covering):
            for test_path, test_text in test_files(target):
                named = fnmatch.fnmatchcase(test_path.name, f'{prefix}*Tests.swift')
                if named or (mention and mention.search(test_text)):
                    matched = add_file(target, test_path, test_text) or matched
        # No fallback when an excluded (already run) target covers the module: that run owns it.
        if not matched and not graph.covering(module) & set(exclude):
            own = f'{module}Tests'
            whole |= {own} if own in covering else covering

    for target in sorted(whole):
        selection.filters.append(f'{target}\\.')
    for target, names in sorted(classes.items()):
        if target in whole or not names:
            continue
        selection.filters.append(f'{target}\\.(?:{"|".join(sorted(names))})\\b')
    selection.targets = whole | {t for t, n in classes.items() if n}
    return selection


def uncovered_modules(files: list[str], graphs: list[Graph]) -> list[str]:
    """Changed modules that no runnable unit-test target covers, in any graph this host can build."""
    missing = set()
    for path in files:
        if Path(path).parts[1] in UI_TEST_TARGETS:
            continue
        modules = {g.module_for(path) for g in graphs} - {None}
        if modules and not any(g.covering(m) for g in graphs for m in modules if m in g.targets):
            missing |= modules
    return sorted(missing)


def test_title(selection: Selection, kind: str = 'Swift') -> str:
    targets = ', '.join(sorted(selection.targets)) or 'none'
    return f'{kind} unit tests ({targets})'


def ci_macos_tests(files: list[str], graph: Graph) -> Selection:
    """The macOS job's pull-request selection: scripts/ci/affected-swift-tests.py over the same changed files."""
    _, selected = affected_selector().select(files, graph.dump, CI_MACOS_SKIP_TARGETS)
    selected = [t for t in selected if t not in UI_TEST_TARGETS]
    return Selection([f'^({"|".join(map(re.escape, selected))})\\.'], set(selected)) if selected else Selection()

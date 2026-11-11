"""Characterises the SwiftPM test-target selection shared by pre-pr and CI.

scripts/ci/affected-swift-tests.py (ci-macos-debug.yml's macOS job) and scripts/pre-pr walk the
same target graph. This truth table pins what both select for representative
changes over a snapshot of the real package graph, so refactoring the shared
graph code cannot quietly change which tests CI or pre-pr runs.

Regenerate the table only for an intended routing change, and review the diff.
"""
import importlib.machinery
import importlib.util
import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = Path(__file__).resolve().parent / 'fixtures'
_loader = importlib.machinery.SourceFileLoader('pre_pr', str(ROOT / 'scripts' / 'pre-pr'))
_spec = importlib.util.spec_from_loader('pre_pr', _loader)
pre_pr = importlib.util.module_from_spec(_spec)
sys.modules['pre_pr'] = pre_pr
_loader.exec_module(pre_pr)
affected = pre_pr.affected_selector()

PACKAGE = json.loads((FIXTURES / 'swift-package-graph.json').read_text())
TABLE = json.loads((FIXTURES / 'swift-target-selection.json').read_text())


def observe(files):
    graph = pre_pr.Graph.from_dump(PACKAGE)
    modules = [graph.module_for(f) for f in files]
    swift = [f for f in files if f.endswith('.swift') and f.startswith(('Sources/', 'Tests/'))]
    return {
        'files': files,
        'affected': list(affected.select(files, PACKAGE, set())),
        'affected_ci_skip': list(affected.select(files, PACKAGE, set(pre_pr.CI_MACOS_SKIP_TARGETS))),
        'modules': modules,
        'covering': {m: sorted(graph.covering(m)) for m in sorted({m for m in modules if m})},
        'ci_macos': sorted(pre_pr.ci_macos_tests(files, graph).targets),
        'uncovered': pre_pr.uncovered_modules(swift, [graph]),
    }


class SelectionTruthTableTests(unittest.TestCase):
    def test_every_row_selects_exactly_what_it_did(self):
        self.assertGreaterEqual(len(TABLE), 15)
        for row in TABLE:
            with self.subTest(files=row['files']):
                self.assertEqual(observe(row['files']), row)

    def test_pre_pr_and_ci_agree_on_the_covering_targets(self):
        graph = pre_pr.Graph.from_dump(PACKAGE)
        for row in TABLE:
            mode, selected = affected.select(row['files'], PACKAGE, set())
            if mode != 'filtered':
                continue
            covered = set().union(*(graph.covering(m) for m in row['modules'] if m))
            with self.subTest(files=row['files']):
                self.assertEqual(set(selected) - pre_pr.UI_TEST_TARGETS, covered)


if __name__ == '__main__':
    unittest.main()

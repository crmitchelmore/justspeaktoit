"""The repository, output directory and host scripts/pre-pr checks, and the git
and GitHub queries its planner and runner share."""
from __future__ import annotations

import functools
import importlib.util
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCRIPTS = ROOT / 'scripts'
OUT = Path(os.environ.get('JSTI_PRE_PR_OUT') or ROOT / '.build' / 'pre-pr')
IS_MAC = sys.platform == 'darwin'


def git(*args: str, check: bool = True) -> str:
    result = subprocess.run(['git', *args], cwd=ROOT, text=True, capture_output=True)
    if check and result.returncode != 0:
        raise SystemExit(f'pre-pr: git {" ".join(args)} failed: {result.stderr.strip()}')
    return result.stdout.strip()


def changed_files(base: str) -> tuple[str, list[str]]:
    merge_base = git('merge-base', 'HEAD', base)
    files = set(filter(None, git('diff', '--name-only', merge_base).splitlines()))
    files |= set(filter(None, git('ls-files', '--others', '--exclude-standard').splitlines()))
    return merge_base, sorted(files)


def merge_base_or(base: str) -> str:
    """The merge base with base, or base itself when history can't tell (a shallow CI checkout)."""
    return git('merge-base', 'HEAD', base, check=False) or base


def worktree_tree() -> str:
    """The git tree of the working tree as checked: tracked, modified and untracked (not ignored) files."""
    with tempfile.TemporaryDirectory() as scratch:
        env = {**os.environ, 'GIT_INDEX_FILE': str(Path(scratch) / 'index')}
        for command in (['read-tree', 'HEAD'], ['add', '-A', '--', '.'], ['write-tree']):
            result = subprocess.run(['git', *command], cwd=ROOT, env=env, text=True, capture_output=True)
            if result.returncode != 0:
                return ''
    return result.stdout.strip()


def pr_title_env() -> dict[str, str]:
    """The open PR's title, whose '!' marker declares an intended API break; else commit subjects decide."""
    if os.environ.get('PR_TITLE'):
        return {'PR_TITLE': os.environ['PR_TITLE']}
    try:
        result = subprocess.run(['gh', 'pr', 'view', '--json', 'title', '--jq', '.title'], cwd=ROOT, text=True,
                                capture_output=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return {}
    return {'PR_TITLE': result.stdout.strip()} if result.returncode == 0 and result.stdout.strip() else {}


def android_runs_locally() -> bool:
    """A JDK that actually runs (macOS ships a /usr/bin/java stub) and an approved Maven feed."""
    if os.environ.get('JSTI_ANDROID_LOCAL') in ('0', '1'):
        return os.environ['JSTI_ANDROID_LOCAL'] == '1'
    try:
        jdk = subprocess.run(['java', '-version'], capture_output=True, timeout=30).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        jdk = False
    feed = bool(os.environ.get('JSTI_MAVEN_MIRROR')) or 'jsti.mavenMirror=' in read(
        Path.home() / '.gradle' / 'gradle.properties')
    return jdk and feed


def read(path: Path) -> str:
    try:
        return path.read_text(encoding='utf-8', errors='replace')
    except OSError:
        return ''


def display(path: Path) -> str:
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


def _load(name: str, path: Path, register: bool = False):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    if register:  # dataclasses resolve their module's annotations through sys.modules
        sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


@functools.cache
def routing():
    """scripts/ci/routing.py: the path routes CI's workflow filters are generated from."""
    return _load('ci_routing', SCRIPTS / 'ci' / 'routing.py')


@functools.cache
def quality():
    """scripts/quality: which files each autofixer and linter owns."""
    from importlib.machinery import SourceFileLoader
    loader = SourceFileLoader('jsti_quality', str(SCRIPTS / 'quality'))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


@functools.cache
def outcomes():
    """scripts/ci/pre_pr_outcome.py: the one classifier of check and run outcomes."""
    return _load('pre_pr_outcome', SCRIPTS / 'ci' / 'pre_pr_outcome.py', register=True)


@functools.cache
def affected_selector():
    """scripts/ci/affected-swift-tests.py: the target graph and selection CI's macOS job uses."""
    return _load('affected_swift_tests', SCRIPTS / 'ci' / 'affected-swift-tests.py')

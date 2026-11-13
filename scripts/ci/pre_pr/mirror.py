"""The build mirror: one persistent git worktree per repository where pre-pr's
SwiftPM checks build, so a new worktree's first run is incremental, not cold.

Each worktree starts with an empty .build, and a cold SwiftPM build of this
package takes minutes. Under the machine lock, pre-pr checks the exact snapshot
it is testing (the working tree, including uncommitted and untracked files) out
in the mirror. git rewrites only the files that differ, so unchanged files keep
their timestamps and the mirror's .build stays warm across worktrees.

The mirror holds what CI sees, without ignored local files. Logs name the
worktree's own paths, not the mirror's. Each machine-lock slot (pre_pr.lock)
has its own mirror, so runs holding different slots never share one.
JSTI_PRE_PR_MIRROR=off builds in place, and JSTI_PRE_PR_MIRROR=DIR picks the
directory (DIR-N for slot N)."""
from __future__ import annotations

import hashlib
import os
import shutil
import subprocess
from pathlib import Path

from pre_pr.environment import ROOT, git

SUBJECT = 'pre-pr build mirror snapshot'


def location(slot: int = 0) -> Path | None:
    suffix = f'-{slot}' if slot else ''
    setting = os.environ.get('JSTI_PRE_PR_MIRROR', '').strip()
    if setting.lower() in ('off', '0', 'no', 'false'):
        return None
    if setting:
        return Path(setting + suffix).expanduser().resolve()
    common = git('rev-parse', '--path-format=absolute', '--git-common-dir', check=False, cwd=ROOT)
    if not common:
        return None
    key = hashlib.sha256(str(Path(common).resolve()).encode()).hexdigest()[:12]
    return Path.home() / '.cache' / 'jsti-pre-pr' / f'mirror-{key}{suffix}'


def _ours(path: Path) -> bool:
    """path is a working worktree of this repository."""
    ours = git('rev-parse', '--path-format=absolute', '--git-common-dir', check=False, cwd=ROOT)
    theirs = git('rev-parse', '--path-format=absolute', '--git-common-dir', check=False, cwd=path)
    top = git('rev-parse', '--show-toplevel', check=False, cwd=path)
    return bool(ours) and ours == theirs and bool(top) and Path(top).resolve() == path.resolve()


def _recreate(path: Path, commit: str) -> bool:
    """Add the mirror worktree afresh, keeping a previous mirror's .build."""
    kept = path.with_name(path.name + '.build-kept')
    shutil.rmtree(kept, ignore_errors=True)
    if (path / '.build').is_dir():
        (path / '.build').rename(kept)
    shutil.rmtree(path, ignore_errors=True)
    path.parent.mkdir(parents=True, exist_ok=True)
    added = subprocess.run(['git', 'worktree', 'add', '--detach', '--force', str(path), commit], cwd=ROOT,
                           text=True, capture_output=True)
    if kept.is_dir():
        if added.returncode == 0:
            kept.rename(path / '.build')
        else:
            shutil.rmtree(kept, ignore_errors=True)
    return added.returncode == 0


def sync(tree: str, head: str, slot: int = 0) -> Path | None:
    """Check the snapshot tree out in the slot's mirror, or None (build in place) when there is no mirror.

    Call it holding that machine-lock slot: one run at a time owns each mirror."""
    path = location(slot)
    if path is None or not tree or path == ROOT:
        return None
    # A fixed identity: CI runners and fresh machines may have none, and nobody reads this commit's author.
    commit = git('-c', 'user.name=pre-pr', '-c', 'user.email=pre-pr@localhost', 'commit-tree', tree, '-p', head,
                 '-m', SUBJECT, check=False, cwd=ROOT) if head else ''
    if not commit:
        return None
    if path.is_dir() and _ours(path):
        moved = subprocess.run(['git', 'checkout', '--detach', '--force', '--quiet', commit], cwd=path,
                               text=True, capture_output=True)
        if moved.returncode == 0:
            # Leftovers a check created; ignored files (.build) stay.
            subprocess.run(['git', 'clean', '-fdq'], cwd=path, capture_output=True)
            return path
    return path if _recreate(path, commit) and _ours(path) else None


def relocate(command: list[str], mirror: Path) -> list[str]:
    """The command with this worktree's paths (such as its scratch path) moved into the mirror."""
    root = str(ROOT)
    return [mirror.as_posix() + arg[len(root):] if arg == root or arg.startswith(root + os.sep) else arg
            for arg in command]


def unmirror(text: str, mirror: Path) -> str:
    """Log text with mirror paths shown as this worktree's, so a failure points at files you can edit."""
    return text.replace(str(mirror), str(ROOT))

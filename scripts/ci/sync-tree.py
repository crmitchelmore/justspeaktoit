#!/usr/bin/env python3
"""Make DEST an exact copy of SRC, rewriting only files whose content differs.

scripts/linux-precheck runs it inside the Linux container. It copies the
checked commit, freshly unpacked, over the previous run's sources in the
container's persistent build volume. Unchanged files keep their timestamps and
inodes, so SwiftPM's next build there is incremental. (Builds can't run straight
off a macOS bind mount: SwiftPM fails to copy resource directories that carry
extended attributes.) Python 3.8+ (the CI image's), standard library only.

    sync-tree.py SRC DEST [--exclude NAME ...]   # NAME: a top-level entry to leave alone (.build, .git)
"""
from __future__ import annotations

import argparse
import filecmp
import os
import shutil
import stat
import sys
from pathlib import Path


def entries(root: Path, exclude: set[str]) -> dict[str, os.stat_result]:
    found = {}
    for directory, dirs, files in os.walk(root):
        relative = os.path.relpath(directory, root)
        if relative == '.':
            dirs[:] = [d for d in dirs if d not in exclude]
            files = [f for f in files if f not in exclude]
        for name in dirs + files:
            path = os.path.join(directory, name)
            found[os.path.normpath(os.path.join(relative, name))] = os.lstat(path)
    return found


def same(source: Path, target: Path, info: os.stat_result, existing: os.stat_result | None) -> bool:
    if existing is None or stat.S_IFMT(info.st_mode) != stat.S_IFMT(existing.st_mode):
        return False
    if stat.S_ISLNK(info.st_mode):
        return os.readlink(source) == os.readlink(target)
    if stat.S_ISDIR(info.st_mode):
        return True
    return info.st_size == existing.st_size and filecmp.cmp(source, target, shallow=False)


def remove(path: Path) -> None:
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    else:
        path.unlink()


def sync(source: Path, target: Path, exclude: set[str]) -> tuple[int, int]:
    """(files written, entries removed)."""
    target.mkdir(parents=True, exist_ok=True)
    wanted, present = entries(source, exclude), entries(target, exclude)
    removed = 0
    for name in sorted(set(present) - set(wanted), reverse=True):
        path = target / name
        if os.path.lexists(path):
            remove(path)
            removed += 1
    written = 0
    for name in sorted(wanted):
        info, src, dst = wanted[name], source / name, target / name
        if same(src, dst, info, present.get(name)):
            if not stat.S_ISLNK(info.st_mode) and stat.S_IMODE(info.st_mode) != stat.S_IMODE(present[name].st_mode):
                os.chmod(dst, stat.S_IMODE(info.st_mode))
            continue
        if os.path.lexists(dst):
            remove(dst)
        if stat.S_ISDIR(info.st_mode):
            dst.mkdir()
        elif stat.S_ISLNK(info.st_mode):
            os.symlink(os.readlink(src), dst)
        else:
            shutil.copyfile(src, dst)  # contents only: no extended attributes
            written += 1
        if not stat.S_ISLNK(info.st_mode):
            os.chmod(dst, stat.S_IMODE(info.st_mode))
    return written, removed


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('source', type=Path)
    parser.add_argument('target', type=Path)
    parser.add_argument('--exclude', action='append', default=[])
    args = parser.parse_args(argv)
    written, removed = sync(args.source, args.target, set(args.exclude))
    print(f'sync-tree: {written} file(s) written, {removed} removed in {args.target}', flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())

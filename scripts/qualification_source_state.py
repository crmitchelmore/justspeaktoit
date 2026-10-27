#!/usr/bin/env python3
"""Read-only, content-free source observations; never compiled-product attestation.

Requires the qualification caller's exclusive checkout ownership. A snapshot is
not atomic against outside writers. Git ignores are respected; ignored outputs,
external dependencies, compiler caches and the compiler's actual reads are not
inventoried. Collection errors/limits are evidence gaps, never clean-source proof.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import time


MAX_RECORDS = 512
MAX_HASH_BYTES = 32 * 1024 * 1024
INPUT_ROOTS = ("Sources/", "Tests/", "scripts/", "SpeakiOSApp/", "JustSpeak", "Config/")
INPUT_FILES = {"Package.swift", "Package.resolved", "Project.swift", "Workspace.swift", "Tuist.swift"}


def is_input(path):
    return path in INPUT_FILES or path.startswith(INPUT_ROOTS)


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def git(root, *arguments):
    return subprocess.check_output(
        ["git", "--no-optional-locks", "-c", "core.fsmonitor=false", *arguments], cwd=root,
        stderr=subprocess.DEVNULL, timeout=5,
    )


def parse_status(raw):
    """Porcelain v1 -z uses destination NUL source for a rename/copy."""
    fields = iter(raw.split(b"\0"))
    records = []
    for field in fields:
        if not field:
            continue
        if len(field) < 4 or field[2:3] != b" ":
            raise ValueError("malformed porcelain entry")
        status = field[:2].decode("ascii")
        record = {"status": status, "path": os.fsdecode(field[3:])}
        if "R" in status or "C" in status:
            original = next(fields, b"")
            if not original:
                raise ValueError("missing rename source")
            record["originalPath"] = os.fsdecode(original)
        records.append(record)
    return records


def regular_state(root, path, object_format, budget):
    """Hash regular in-repository bytes without following a leaf symlink."""
    target = root / path
    try:
        info = target.lstat()
    except FileNotFoundError:
        return {"kind": "missing"}
    if not stat.S_ISREG(info.st_mode):
        return {"kind": "symlink" if stat.S_ISLNK(info.st_mode) else "nonregular"}
    if not target.resolve().is_relative_to(root.resolve()):
        return {"kind": "outside-repository", "hashUnavailable": True}
    if info.st_size > budget[0]:
        return {"kind": "regular", "bytes": info.st_size, "hashUnavailable": "byte-limit"}
    descriptor = os.open(target, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode):
            return {"kind": "nonregular"}
        digest = hashlib.sha256()
        blob = hashlib.new(object_format)
        blob.update(f"blob {before.st_size}\0".encode())
        count = 0
        while block := stream.read(min(1024 * 1024, budget[0] + 1)):
            count += len(block)
            budget[0] -= len(block)
            if budget[0] < 0:
                return {"kind": "regular", "hashUnavailable": "byte-limit"}
            digest.update(block)
            blob.update(block)
        after = os.fstat(stream.fileno())
    stable = (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) == (
        after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns)
    return {"kind": "regular", "bytes": count, "sha256": digest.hexdigest(),
            "rawGitBlob": blob.hexdigest(), "stableDuringRead": stable}


def observed_regular_state(root, path, object_format, budget):
    try:
        return regular_state(root, path, object_format, budget)
    except OSError as error:
        return {"kind": "unreadable", "hashUnavailable": type(error).__name__}


def capture(root, phase, output_dir=None, command_outcome=None):
    started = time.monotonic_ns()
    result = {"phase": phase, "startedUTC": utc_now(), "startedMonotonicNS": started,
              "commandOutcome": command_outcome, "head": None, "gitDirty": None,
              "records": [], "collectionErrors": [], "collectionComplete": False,
              "limitations": ["Observation window only; not compiled-product binding",
                              "Requires exclusive checkout; cannot prove no intervening writer",
                              "Untracked inventory excludes ignored paths; no untracked contents read",
                              "Worktree hashes cover changed selected inputs and Package.resolved only"]}
    errors = result["collectionErrors"]
    root = Path(root)
    try:
        head = git(root, "rev-parse", "--verify", "HEAD").decode().strip()
        result["head"] = head
        head_rows = git(root, "ls-tree", "-r", "-z", head).split(b"\0")
        tree = {}
        for row in filter(None, head_rows):
            metadata, path = row.split(b"\t", 1)
            mode, kind, blob = metadata.decode().split()
            tree[os.fsdecode(path)] = {"mode": mode, "kind": kind, "blob": blob}
        index = {}
        for row in filter(None, git(root, "ls-files", "--stage", "-z").split(b"\0")):
            metadata, path = row.split(b"\t", 1)
            mode, blob, stage = metadata.decode().split()
            index.setdefault(os.fsdecode(path), []).append({"mode": mode, "blob": blob, "stage": stage})
        manifest = {path: value for path, value in tree.items() if is_input(path)}
        result["headInputInventory"] = {"count": len(manifest), "sha256": hashlib.sha256(
            json.dumps(manifest, sort_keys=True, ensure_ascii=True).encode()).hexdigest(),
            "roots": INPUT_ROOTS, "files": sorted(INPUT_FILES)}
        raw = git(root, "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=none")
        records = parse_status(raw)
        result.update(gitDirty=bool(records), porcelainSHA256=hashlib.sha256(raw).hexdigest(),
                      totalRecords=len(records), recordsTruncated=len(records) > MAX_RECORDS)
        budget = [MAX_HASH_BYTES]
        output_relative = None
        if output_dir is not None:
            try:
                output_relative = Path(output_dir).resolve().relative_to(root.resolve()).as_posix()
            except ValueError:
                pass
        for record in records[:MAX_RECORDS]:
            path = record["path"]
            record.update(tracked=record["status"] != "??", selectedInput=is_input(path),
                          headEntry=tree.get(path), indexEntries=index.get(path, []),
                          insideOwnedOutputDirectory=bool(output_relative and (
                              path == output_relative or path.startswith(output_relative + "/"))))
            if "originalPath" in record:
                record["originalHeadEntry"] = tree.get(record["originalPath"])
            # Output membership does not establish harmlessness. Never read untracked bytes.
            if record["tracked"] and record["selectedInput"]:
                record["worktree"] = observed_regular_state(
                    root, path, "sha1" if len(head) == 40 else "sha256", budget)
            result["records"].append(record)
        if "Package.resolved" in tree or "Package.resolved" in index:
            lock = observed_regular_state(root, "Package.resolved", "sha1" if len(head) == 40 else "sha256", budget)
        else:
            try:
                mode = (root / "Package.resolved").lstat().st_mode
                kind = "regular" if stat.S_ISREG(mode) else ("symlink" if stat.S_ISLNK(mode) else "nonregular")
            except FileNotFoundError:
                kind = "missing"
            lock = {"kind": kind, "contentsNotRead": True}
        lock["headEntry"] = tree.get("Package.resolved")
        lock["indexEntries"] = index.get("Package.resolved", [])
        lock["matchesHEADRawBytes"] = (lock.get("stableDuringRead") and
                                      lock.get("rawGitBlob") == tree.get("Package.resolved", {}).get("blob"))
        result["packageResolved"] = lock
        if result["recordsTruncated"]:
            errors.append("status-record-limit")
        for value in [lock] + [record.get("worktree", {}) for record in result["records"]]:
            if value.get("hashUnavailable") or value.get("stableDuringRead") is False:
                errors.append("incomplete-or-changing-worktree-hash")
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        # Do not echo exception messages, command stdout/stderr, contents or environment.
        errors.append(type(error).__name__)
    result["collectionComplete"] = not errors
    result["finishedUTC"] = utc_now()
    result["finishedMonotonicNS"] = time.monotonic_ns()
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--phase", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--command-outcome")
    args = parser.parse_args()
    evidence = capture(Path.cwd(), args.phase, command_outcome=args.command_outcome)
    try:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with args.output.open("x") as destination:
            destination.write(json.dumps(evidence, indent=2, sort_keys=True) + "\n")
    except OSError as error:
        evidence["collectionErrors"].append("write-" + type(error).__name__)
        evidence["collectionComplete"] = False
    print(json.dumps({"phase": args.phase, "head": evidence["head"],
                      "collectionComplete": evidence["collectionComplete"],
                      "collectionErrors": evidence["collectionErrors"]}, sort_keys=True))
    return 0  # Advisory evidence, never a new qualification gate.


if __name__ == "__main__":
    raise SystemExit(main())

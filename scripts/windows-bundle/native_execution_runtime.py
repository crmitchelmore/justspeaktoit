"""The pinned Swift runtime a standalone diagnostic copies into its private directory.

Part of verify-native-execution.py, which owns the command line.
"""
import hashlib
import json
import ntpath
import os
import pathlib
import re
import stat

import windows_pe
import windows_targets
from native_execution_process import diagnostic_preparation_phase

HERE = pathlib.Path(__file__).resolve().parent


def diagnostic_runtime_request(rows):
    """Optional internal observations only; paths never become receipt fields."""
    if type(rows) is not list or len(rows) != 14:
        raise ValueError("runtime unavailable")
    parents, names, total = set(), set(), 0
    for row in rows:
        if type(row) is not dict or set(row) != {"name", "path", "bytes", "sha256"}:
            raise ValueError("runtime unavailable")
        name, location = row["name"], row["path"]
        if type(name) is not str or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*\.dll", name) or \
                name.casefold() in names or type(location) is not str or len(location) > 4096 or \
                not re.match(r"^[A-Za-z]:\\", location) or ntpath.normpath(location) != location or \
                ntpath.basename(location) != name or any(ord(c) < 32 for c in location) or \
                any(c in location for c in '\";') or ":" in location[2:] or \
                type(row["bytes"]) is not int or not 0 < row["bytes"] <= 64 << 20 or \
                type(row["sha256"]) is not str or not re.fullmatch(r"[0-9a-f]{64}", row["sha256"]):
            raise ValueError("runtime unavailable")
        names.add(name.casefold()); parents.add(ntpath.dirname(location).casefold()); total += row["bytes"]
    if len(parents) != 1 or total > 64 << 20:
        raise ValueError("runtime unavailable")
    return rows


def diagnostic_runtime_layout():
    """Use the canonical ARM installer pin, lock and runtime-name policy."""
    version, pin, _ = windows_targets.swift_runtime_installer("arm64")
    lock = json.loads((HERE / windows_targets.target("arm64")["swiftRuntimeLock"]).read_text(encoding="utf-8"))
    installer = lock.get("installer") or {}
    if lock.get("architecture") != "arm64" or lock.get("swiftVersion") != version or \
            any(installer.get(key) != pin[key] for key in ("name", "url", "sha256")) or \
            not windows_targets.installer_size_matches(pin, installer.get("bytes")):
        raise ValueError("runtime unavailable")
    policy = json.loads((HERE / "runtime-policy.json").read_text(encoding="utf-8"))["swiftRuntimeModules"]
    layout = {row["path"]: row for row in lock["files"]}
    if len(layout) != len(lock["files"]) or len(set(policy)) != len(policy):
        raise ValueError("runtime unavailable")
    return version, {name: layout[name] for name in policy}


def diagnostic_runtime_stamp(path, directory=False):
    for component in (path, *path.parents):
        info = component.lstat()
        if getattr(info, "st_file_attributes", 0) & 0x400 or stat.S_ISLNK(info.st_mode):
            raise ValueError("runtime unavailable")
    info = path.lstat()
    if not (stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode)):
        raise ValueError("runtime unavailable")
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns


def diagnostic_runtime_bytes(path, row, budget):
    before = diagnostic_runtime_stamp(path)
    if before[2] != row["bytes"]:
        raise ValueError("runtime unavailable")
    stamp = lambda info: (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns)
    with path.open("rb") as stream:
        if stamp(os.fstat(stream.fileno())) != before:
            raise ValueError("runtime unavailable")
        data = bytearray()
        while len(data) < row["bytes"]:
            if budget.remaining() <= 2:
                raise TimeoutError()
            chunk = stream.read(min(1 << 20, row["bytes"] - len(data)))
            if not chunk:
                raise ValueError("runtime unavailable")
            data.extend(chunk)
        if stamp(os.fstat(stream.fileno())) != before:
            raise ValueError("runtime unavailable")
    if diagnostic_runtime_stamp(path) != before or hashlib.sha256(data).hexdigest() != row["sha256"]:
        raise ValueError("runtime unavailable")
    image = windows_pe.PEImage(data, "owned-diagnostic-runtime")
    if image.architecture != "arm64" or not image.is_dll:
        raise ValueError("runtime unavailable")
    return data, before


def prepare_diagnostic_runtime(rows, directory, budget):
    """Copy only pinned snapshots; never admit a user-writable source to PATH."""
    diagnostic_preparation_phase(budget, "runtime-layout")
    diagnostic_runtime_request(rows)
    version, layout = diagnostic_runtime_layout()
    parent = ntpath.dirname(rows[0]["path"])
    prefix = r'^[A-Za-z]:\\Users\\[^\\/:;"<>|?*\x00-\x1f]{1,128}\\AppData\\Local\\Programs\\Swift\\Runtimes\\'
    if not re.fullmatch(prefix + re.escape(version) + r'\\usr\\bin', parent, re.IGNORECASE):
        raise ValueError("runtime unavailable")
    diagnostic_preparation_phase(budget, "runtime-source")
    source_parent = pathlib.Path(parent)
    parent_stamp = diagnostic_runtime_stamp(source_parent, directory=True)
    diagnostic_preparation_phase(budget, "runtime-copy")
    private = pathlib.Path(directory) / "runtime"
    private.mkdir(mode=0o700)
    sources, copies = [], []
    for row in rows:
        diagnostic_preparation_phase(budget, "runtime-layout")
        pinned = layout.get(row["name"])
        if pinned is None or row["bytes"] != pinned["bytes"] or row["sha256"] != pinned["sha256"]:
            raise ValueError("runtime unavailable")
        diagnostic_preparation_phase(budget, "runtime-source")
        path = pathlib.Path(row["path"])
        data, source_stamp = diagnostic_runtime_bytes(path, row, budget)
        diagnostic_preparation_phase(budget, "runtime-copy")
        destination = private / row["name"]
        with destination.open("xb") as stream:
            for offset in range(0, len(data), 1 << 20):
                if budget.remaining() <= 2:
                    raise TimeoutError()
                stream.write(memoryview(data)[offset:offset + (1 << 20)])
        sources.append((path, source_stamp))
        copies.append((destination, row, diagnostic_runtime_stamp(destination)))
    diagnostic_preparation_phase(budget, "runtime-recheck")
    if diagnostic_runtime_stamp(source_parent, directory=True) != parent_stamp or \
            any(diagnostic_runtime_stamp(path) != stamp for path, stamp in sources):
        raise ValueError("runtime unavailable")
    for path, row, stamp in copies:
        _, current = diagnostic_runtime_bytes(path, row, budget)
        if current != stamp:
            raise ValueError("runtime unavailable")
    # Enumerate only our newly created private directory, at most15 entries;
    # source/toolchain siblings are never scanned or admitted.
    copied_names = set()
    with os.scandir(private) as entries:
        for entry in entries:
            if len(copied_names) >= 14 or not entry.is_file(follow_symlinks=False):
                raise ValueError("runtime unavailable")
            copied_names.add(entry.name)
    if copied_names != {row["name"] for row in rows}:
        raise ValueError("runtime unavailable")
    if budget.remaining() <= 2:
        raise TimeoutError()
    return str(private)

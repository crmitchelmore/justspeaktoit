"""Lossless, verified ZIP recompression. The optimizer is build tooling, never payload."""
import hashlib
import pathlib
import shutil
import stat
import subprocess
import tempfile
import zipfile


VERSION = "2.6"


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def regular_identity(path):
    try:
        info = path.lstat()
    except OSError as error:
        raise ValueError("Cannot inspect ZIP optimization input: " + str(path)) from error
    if not stat.S_ISREG(info.st_mode) or getattr(info, "st_file_attributes", 0) & 0x400:
        raise ValueError("ZIP optimization requires a regular, non-reparse file: " + str(path))
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns


def inventory(path):
    """Compare extraction semantics, not compressor-specific sizes or version hints."""
    try:
        with zipfile.ZipFile(path) as archive:
            entries = []
            seen = set()
            for entry in archive.infolist():
                if entry.filename in seen:
                    raise ValueError("Duplicate ZIP member: " + entry.filename)
                seen.add(entry.filename)
                if entry.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
                    raise ValueError("Unsupported ZIP compression: " + entry.filename)
                if entry.flag_bits & ~(0x800 | 0x8 | 0x6) or entry.extract_version > 20:
                    raise ValueError("Unsupported ZIP extraction requirements: " + entry.filename)
                with archive.open(entry) as stream:
                    payload = hashlib.file_digest(stream, "sha256").hexdigest()
                entries.append((
                    entry.filename, entry.date_time, entry.CRC, entry.file_size, payload,
                    entry.create_system, entry.create_version, entry.internal_attr, entry.external_attr,
                    entry.comment, entry.extra, entry.volume, entry.reserved,
                    entry.flag_bits & ~0x6,  # Only DEFLATE compression-level hints may change.
                ))
            return archive.comment, entries
    except zipfile.BadZipFile as error:
        raise ValueError("Invalid ZIP during optimization: " + str(error)) from error


def optimize_archive(archive, tool):
    archive, tool = pathlib.Path(archive), pathlib.Path(tool)
    if not archive.is_absolute() or not tool.is_absolute():
        raise ValueError("ZIP optimization requires absolute archive and tool paths")
    original_identity, tool_identity = regular_identity(archive), regular_identity(tool)
    original_sha, tool_sha = digest(archive), digest(tool)
    expected = inventory(archive)
    try:
        version = subprocess.run([str(tool), "--version"], check=True, capture_output=True,
                                 text=True, encoding="utf-8", timeout=15).stdout.strip()
        if not version.startswith("advancecomp v" + VERSION + " "):
            raise ValueError("Expected AdvanceCOMP " + VERSION + ", got: " + version)
        with tempfile.TemporaryDirectory(prefix=".zip-optimization-", dir=archive.parent) as directory:
            candidate = pathlib.Path(directory) / "candidate.zip"
            shutil.copyfile(archive, candidate)
            subprocess.run([str(tool), "--recompress", "--shrink-normal", "--keep-file-time",
                            "--quiet", str(candidate)], check=True, capture_output=True,
                           text=True, encoding="utf-8", timeout=300)
            regular_identity(candidate)
            if inventory(candidate) != expected:
                raise ValueError("ZIP optimizer changed payloads, ordering or member metadata")
            after = candidate.stat().st_size
            if after > original_identity[2]:
                raise ValueError("ZIP optimizer increased archive size")
            if regular_identity(tool) != tool_identity or digest(tool) != tool_sha:
                raise ValueError("ZIP optimizer changed during execution")
            if regular_identity(archive) != original_identity or digest(archive) != original_sha:
                raise ValueError("Original ZIP changed during optimization")
            candidate.replace(archive)
    except subprocess.CalledProcessError as error:
        raise ValueError("ZIP optimizer failed: " + (error.stderr or error.stdout or str(error)).strip()) from error
    except subprocess.TimeoutExpired as error:
        raise ValueError("ZIP optimizer exceeded its execution budget") from error
    return {
        "tool": "AdvanceCOMP", "version": VERSION, "toolSHA256": tool_sha,
        "mode": "shrink-normal (libdeflate)", "beforeBytes": original_identity[2],
        "afterBytes": after, "savedBytes": original_identity[2] - after,
        "verifiedEntries": len(expected[1]), "inputSHA256": original_sha,
    }

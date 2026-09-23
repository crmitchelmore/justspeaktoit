#!/usr/bin/env python3
"""Synthetic user data and negative controls for the MSIX lifecycle test.

``fixture`` writes what an existing portable install leaves in
%LOCALAPPDATA%\\JustSpeakToIt, in the app's own on-disk formats: settings, a
completed History record with its WAV, an interrupted record whose WAV header
still has zero lengths, and unknown user files. ``check`` compares a data
directory with those expectations, including the installed app's own
interrupted-recording recovery. ``tamper`` flips one payload byte of a signed
package. Nothing here contains or creates a credential or key.
"""
import argparse
import hashlib
import json
import pathlib
import struct
import sys
import zipfile
import zlib

sys.dont_write_bytecode = True

MODEL = "google/gemini-2.0-flash-001"  # ModelCatalog.defaultBatchTranscriptionModel
COMPLETED_ID = "7D3E8A10-5C2B-4F6E-9A41-0C1D2E3F4A5B"
INTERRUPTED_ID = "2B9F4C6D-8E1A-4D3B-B5C7-9E0F1A2B3C4D"
TRANSCRIPT = ("Lifecycle fixture transcript: \N{GREEK SMALL LETTER KAPPA}\N{GREEK SMALL LETTER OMICRON WITH TONOS}"
              "\N{GREEK SMALL LETTER SIGMA}\N{GREEK SMALL LETTER MU}\N{GREEK SMALL LETTER EPSILON} \N{EM DASH} "
              "kept through install, upgrade and uninstall.")
RECOVERED_FAILURE = "Recording was interrupted. Audio recovered for retry."  # DesktopRecordingStore
SAMPLE_RATE = 16_000
# Files the app itself may create beside user data; never user data.
APP_CREATED_FILES = {"OpenRouterAudioCatalog.json"}


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def wav_header(payload_bytes, sample_rate=SAMPLE_RATE):
    """PCMWaveWriter's canonical 44-byte mono PCM16 header."""
    return (b"RIFF" + struct.pack("<I", 36 + payload_bytes) + b"WAVE" + b"fmt " + struct.pack("<I", 16)
            + struct.pack("<HHIIHH", 1, 1, sample_rate, sample_rate * 2, 2, 16)
            + b"data" + struct.pack("<I", payload_bytes))


def pcm(samples, period):
    # A deterministic, non-silent triangle wave.
    values = []
    for index in range(samples):
        phase = index % period
        level = phase if phase < period // 2 else period - phase
        values.append((level * 16000) // (period // 2) - 8000)
    return struct.pack("<%dh" % samples, *values)


def fixture_files():
    completed_audio = pcm(8000, 64)
    interrupted_payload = pcm(4000, 50)
    # An interrupted capture: PCMRecordingFile writes the header with zero
    # lengths first and only patches it when a recording finishes.
    interrupted_audio = wav_header(0) + interrupted_payload
    completed = {"audioFilename": COMPLETED_ID + ".wav", "createdAt": 780000000.0, "id": COMPLETED_ID,
                 "modelIdentifier": MODEL, "result": {"duration": 0.5, "modelIdentifier": MODEL, "segments": [],
                                                      "text": TRANSCRIPT}}
    interrupted = {"audioFilename": INTERRUPTED_ID + ".wav", "createdAt": 779990000.0, "id": INTERRUPTED_ID,
                   "modelIdentifier": MODEL}

    def encode(value):
        return (json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode("utf-8")

    files = {
        "settings.json": encode({"model": MODEL}),
        "History/%s.json" % COMPLETED_ID: encode(completed),
        "History/%s.wav" % COMPLETED_ID: wav_header(len(completed_audio)) + completed_audio,
        "History/%s.json" % INTERRUPTED_ID: encode(interrupted),
        "History/%s.wav" % INTERRUPTED_ID: interrupted_audio,
        "keep-user-notes.txt": b"User file kept by the lifecycle fixture. The installer must never touch it.\n",
        "History/keep-history-note.txt": b"Unknown History file; the app ignores it and uninstall must keep it.\n",
    }
    recovery = {"record": "History/%s.json" % INTERRUPTED_ID, "audio": "History/%s.wav" % INTERRUPTED_ID,
                "failure": RECOVERED_FAILURE, "payloadBytes": len(interrupted_payload),
                "payloadSHA256": sha256(interrupted_payload), "sampleRate": SAMPLE_RATE,
                "recordFields": interrupted}
    return files, recovery


def write_fixture(directory, expectations_path):
    directory = pathlib.Path(directory)
    if directory.exists():
        raise SystemExit("fixture destination already exists: " + str(directory))
    files, recovery = fixture_files()
    for path, data in sorted(files.items()):
        destination = directory / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
    expectations = {
        "schemaVersion": 1,
        "files": {path: {"bytes": len(data), "sha256": sha256(data)} for path, data in sorted(files.items())},
        "unchanged": sorted(path for path in files if path != recovery["record"] and path != recovery["audio"]),
        "recovery": recovery,
        "history": {"rows": 2, "selectedTranscript": TRANSCRIPT},
        "appCreatedFiles": sorted(APP_CREATED_FILES),
    }
    pathlib.Path(expectations_path).write_text(json.dumps(expectations, indent=2, sort_keys=True, ensure_ascii=False)
                                               + "\n", encoding="utf-8")
    return expectations


def snapshot(directory):
    directory = pathlib.Path(directory)
    result = {}
    for path in sorted(directory.rglob("*")):
        if path.is_file():
            data = path.read_bytes()
            result[path.relative_to(directory).as_posix()] = {"bytes": len(data), "sha256": sha256(data)}
    return result


def check_data(directory, expectations, state):
    """Compare a data directory with the fixture. ``state`` is ``seeded`` or ``recovered``.

    ``seeded``: every fixture file is byte-identical. ``recovered``: the
    installed app has rewritten only the interrupted record, in place, adding
    its recovery failure and patching the WAV lengths while keeping every audio
    sample; everything else is byte-identical.
    """
    directory = pathlib.Path(directory)
    failures, current = [], snapshot(directory)
    recovery = expectations["recovery"]
    for path, expected in sorted(expectations["files"].items()):
        if path not in current:
            failures.append("missing " + path)
        elif state == "seeded" or path in expectations["unchanged"]:
            if current[path] != expected:
                failures.append("changed " + path)
    if state == "recovered" and not failures:
        record = json.loads((directory / recovery["record"]).read_text(encoding="utf-8"))
        fields = recovery["recordFields"]
        for key in ("id", "audioFilename", "modelIdentifier"):
            if str(record.get(key, "")).upper() != str(fields[key]).upper():
                failures.append("recovered record changed " + key)
        if record.get("createdAt") != fields["createdAt"]:
            failures.append("recovered record changed createdAt")
        if record.get("failure") != recovery["failure"] or "result" in record:
            failures.append("interrupted record was not recovered in the real data directory")
        audio = (directory / recovery["audio"]).read_bytes()
        payload = audio[44:]
        if len(payload) != recovery["payloadBytes"] or sha256(payload) != recovery["payloadSHA256"]:
            failures.append("recovered audio samples changed")
        elif audio[:44] != wav_header(len(payload), recovery["sampleRate"]):
            failures.append("recovered WAV header was not patched to the payload length")
    elif state not in ("seeded", "recovered"):
        raise SystemExit("unknown state: " + state)
    extra = sorted(path for path in current if path not in expectations["files"])
    unexpected = [path for path in extra if path not in expectations["appCreatedFiles"]]
    if unexpected:
        failures.append("unexpected files: " + ", ".join(unexpected))
    return {"state": state, "failures": failures, "appCreatedFiles": [path for path in extra if path not in unexpected],
            "files": current}


def tamper(source, destination, reference=None):
    """Flip one payload byte of a package while keeping the archive readable.

    Prefers a stored entry, so the change is a pure content change that only
    the CRC, block hashes and signature can detect. With a reference package
    (the version already installed), only entries whose content differs from
    the reference are candidates: an upgrade reuses installed files whose
    block hashes match, so a flipped byte in an unchanged file is never read
    and would not exercise the upgrade's integrity check.
    """
    data = bytearray(pathlib.Path(source).read_bytes())
    installed = {}
    if reference is not None:
        with zipfile.ZipFile(reference) as archive:
            installed = {info.filename: (info.CRC, info.file_size) for info in archive.infolist()}
    with zipfile.ZipFile(source) as archive:
        infos = [info for info in archive.infolist() if info.filename not in (
            "AppxBlockMap.xml", "[Content_Types].xml", "AppxSignature.p7x", "AppxManifest.xml",
            "AppxMetadata/CodeIntegrity.cat")
            and info.compress_size > 64
            and installed.get(info.filename) != (info.CRC, info.file_size)]
        if not infos:
            raise SystemExit("no payload entry differs from the reference package")
        stored = [info for info in infos if info.compress_type == zipfile.ZIP_STORED]
        chosen = max(stored or infos, key=lambda info: (info.compress_size, info.filename))
    header = chosen.header_offset
    if data[header:header + 4] != b"PK\x03\x04":
        raise SystemExit("unexpected local header for " + chosen.filename)
    name_length, extra_length = struct.unpack_from("<HH", data, header + 26)
    offset = header + 30 + name_length + extra_length + chosen.compress_size // 2
    data[offset] ^= 0x01
    pathlib.Path(destination).write_bytes(bytes(data))
    with zipfile.ZipFile(destination) as archive:
        try:
            archive.read(chosen.filename)
        except (zipfile.BadZipFile, zlib.error, EOFError):
            return {"entry": chosen.filename, "stored": chosen.compress_type == zipfile.ZIP_STORED, "offset": offset}
    raise SystemExit("tampering did not change the readable content of " + chosen.filename)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    make = commands.add_parser("fixture")
    make.add_argument("--directory", required=True, type=pathlib.Path)
    make.add_argument("--expectations", required=True, type=pathlib.Path)
    check = commands.add_parser("check")
    check.add_argument("--directory", required=True, type=pathlib.Path)
    check.add_argument("--expectations", required=True, type=pathlib.Path)
    check.add_argument("--state", required=True, choices=("seeded", "recovered"))
    check.add_argument("--report", type=pathlib.Path)
    corrupt = commands.add_parser("tamper")
    corrupt.add_argument("--package", required=True, type=pathlib.Path)
    corrupt.add_argument("--output", required=True, type=pathlib.Path)
    corrupt.add_argument("--reference", type=pathlib.Path,
                         help="installed package; only entries that differ from it are tampered")
    args = parser.parse_args()
    if args.command == "fixture":
        write_fixture(args.directory, args.expectations)
        print("Wrote the synthetic portable-install fixture to " + str(args.directory))
    elif args.command == "check":
        expectations = json.loads(args.expectations.read_text(encoding="utf-8"))
        report = check_data(args.directory, expectations, args.state)
        text = json.dumps(report, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
        if args.report:
            args.report.write_text(text, encoding="utf-8")
        print(text)
        if report["failures"]:
            raise SystemExit("user data check failed: " + "; ".join(report["failures"]))
    else:
        if args.output.exists():
            raise SystemExit("output exists: " + str(args.output))
        print(json.dumps(tamper(args.package, args.output, args.reference), sort_keys=True))


if __name__ == "__main__":
    main()

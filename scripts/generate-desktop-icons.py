#!/usr/bin/env python3
"""Export native desktop icons from the canonical Mac PNGs; no image libraries."""
import argparse
import importlib.util
import pathlib
import struct
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location(
    "desktop_icon_images", ROOT / "scripts/windows-package/windows_msix.py")
IMAGES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(IMAGES)
SIZES = (16, 20, 24, 32, 40, 48, 64, 128, 256)
APP_ID = "com.justspeaktoit.JustSpeakToIt"
IDLE_ID, RECORDING_ID = 101, 102


def canonical_png(size):
    available = (16, 32, 64, 128, 256, 512)
    source_size = next(value for value in available if value >= size)
    data = (ROOT / f"Resources/AppIcon.iconset/icon_{source_size}x{source_size}.png").read_bytes()
    width, height, rgba = IMAGES.decode_png(data)
    if (width, height) != (source_size, source_size):
        raise ValueError("canonical Mac icon has unexpected dimensions")
    if size == source_size:
        return data
    return IMAGES.encode_png(size, size, IMAGES.resample_rgba(width, height, rgba, size, size))


def recording_png(data):
    size, height, rgba = IMAGES.decode_png(data)
    if size != height:
        raise ValueError("recording icon must be square")
    pixels = bytearray(rgba)
    # The existing tray's recording indicator, composited onto the real artwork.
    dot = max(6, size * 7 // 16)
    centre = size - dot / 2
    for y in range(size - dot, size):
        for x in range(size - dot, size):
            outer = inner = 0
            for sy in range(4):
                for sx in range(4):
                    distance = (x + (sx + .5) / 4 - centre) ** 2 + (y + (sy + .5) / 4 - centre) ** 2
                    outer += distance <= (dot / 2) ** 2
                    inner += distance <= (dot / 2 - 1) ** 2
            if outer:
                offset = (y * size + x) * 4
                old_alpha = rgba[offset + 3] * (16 - outer)
                alpha = 255 * outer + old_alpha
                for channel, value in enumerate((217, 42, 42)):
                    colour = value * inner + 255 * (outer - inner)
                    pixels[offset + channel] = IMAGES._rounded_quotient(
                        255 * colour + rgba[offset + channel] * old_alpha, alpha)
                pixels[offset + 3] = IMAGES._rounded_quotient(alpha, 16)
    return IMAGES.encode_png(size, size, bytes(pixels))


def ico(frames):
    offset = 6 + 16 * len(frames)
    entries, payload = [], []
    for size, data in frames:
        entries.append(struct.pack("<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(data), offset))
        payload.append(data)
        offset += len(data)
    return struct.pack("<HHH", 0, 1, len(frames)) + b"".join(entries + payload)


def resource(kind, identifier, data):
    # Win32 .res, ordinal type/name, language-neutral, DWORD-aligned. Unlike a
    # COFF object this is architecture-independent and links on x64 and ARM64.
    header = struct.pack("<IIHHHHIHHII", len(data), 32, 0xffff, kind, 0xffff, identifier,
                         0, 0x1030 if kind else 0, 0, 0, 0)
    return header + data + bytes(-len(data) % 4)


def windows_resources(idle, recording):
    output = resource(0, 0, b"")
    identifier = 1
    for group_id, frames in ((IDLE_ID, idle), (RECORDING_ID, recording)):
        entries = []
        for size, data in frames:
            output += resource(3, identifier, data)  # RT_ICON
            entries.append(struct.pack("<BBBBHHIH", size % 256, size % 256, 0, 0, 1, 32, len(data), identifier))
            identifier += 1
        output += resource(14, group_id, struct.pack("<HHH", 0, 1, len(entries)) + b"".join(entries))
    return output


def exports():
    idle = [(size, canonical_png(size)) for size in SIZES]
    recording = [(size, recording_png(data)) for size, data in idle]
    files = {
        "Resources/Desktop/AppIcon.ico": ico(idle),
        "Resources/Desktop/AppIcon.res": windows_resources(idle, recording),
    }
    theme = "Sources/SpeakLinux/Resources/hicolor"
    sizes = (16, 24, 32, 48, 64, 128, 256, 512)
    directories = [f"{size}x{size}/apps" for size in sizes]
    index = ("[Icon Theme]\nName=Just Speak to It\nComment=Canonical application icon\n"
             "Hidden=true\nDirectories=" + ",".join(directories) + "\n")
    for size, directory in zip(sizes, directories):
        index += f"\n[{directory}]\nSize={size}\nContext=Applications\nType=Fixed\n"
        files[f"{theme}/{directory}/{APP_ID}.png"] = canonical_png(size)
    files[f"{theme}/index.theme"] = index.encode("utf-8")
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail if a checked-in export is stale or missing")
    args = parser.parse_args()
    stale = []
    for name, data in exports().items():
        path = ROOT / name
        if args.check:
            if not path.is_file() or path.read_bytes() != data:
                stale.append(name)
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
    if stale:
        print("Stale desktop icons; run scripts/generate-desktop-icons.py:\n" + "\n".join(stale), file=sys.stderr)
        return 1
    print("Canonical desktop icon exports " + ("verified." if args.check else "generated."))
    return 0


if __name__ == "__main__":
    sys.exit(main())

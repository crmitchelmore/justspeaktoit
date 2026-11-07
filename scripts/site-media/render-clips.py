#!/usr/bin/env python3
"""Render the website's marketing clips from real app captures.

Usage: render-clips.py <captures> <output> [--only name ...]

<captures> holds one folder per platform, produced on hosted CI runners by
.github/workflows/site-media.yml:
  mac/      screen.mov, marks.json, recording-start.txt  (real Debug app, UI test)
  ios/      screen.mp4, marks.json, recording-start.txt  (Simulator, UI test)
  windows/  NN-page.bmp or .png  (windows.yml --ui-screenshots tour)
  linux/    NN-page.png          (linux.yml page screenshots)

Recorded scenes are cut from the unedited screen recordings at the UI tests'
scene marks; stills are shown unretouched and never enlarged beyond 1x. The
only additions are title cards and a platform badge. Every clip is silent and
gets an H.264 MP4, an AV1 WebM (VP9 if no AV1 encoder), a WebP poster and
WebVTT captions. Rendering is deterministic for the same inputs and fonts.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[2]
ICON = ROOT / "landing-page" / "icon-512.png"
GROUND, SURFACE, TEXT, DIM = (18, 20, 23), (25, 28, 33), (245, 243, 240), (173, 180, 189)
ACCENT, LAGOON = (255, 107, 61), (46, 212, 191)
FPS = 30
LANDSCAPE, PORTRAIT = (1280, 720), (640, 1280)

FONT_CANDIDATES = {
    "bold": ["/usr/share/fonts/opentype/inter/Inter-Bold.otf", "/usr/share/fonts/truetype/inter/Inter-Bold.ttf",
             "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", "/System/Library/Fonts/HelveticaNeue.ttc"],
    "regular": ["/usr/share/fonts/opentype/inter/Inter-Regular.otf",
                "/usr/share/fonts/truetype/inter/Inter-Regular.ttf",
                "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", "/System/Library/Fonts/HelveticaNeue.ttc"],
}


def card(title, subtitle, seconds, caption):
    return {"kind": "card", "title": title, "subtitle": subtitle, "seconds": seconds, "caption": caption}


def cut(start, start_offset, end, end_offset, caption, crop=None):
    """crop: None (whole screen), "app" (main window) or "fixture" (target app and recording HUD)."""
    return {"kind": "cut", "start": (start, start_offset), "end": (end, end_offset), "caption": caption,
            "crop": crop}


def still(name, seconds, caption):
    return {"kind": "still", "name": name, "seconds": seconds, "caption": caption}


MAC_END = card("Just Speak to It", "Download for Mac at justspeaktoit.com", 2.5,
               "Just Speak to It for Mac. Download at justspeaktoit.com")
SYNTHETIC = "Sample data: fictional History and fixed test text."

CLIPS = {
    "hero": {
        "source": "mac", "size": LANDSCAPE, "badge": None, "poster": 4,
        "alt": "Dictating into a text field on a Mac, then finding the text in History",
        "scenes": [
            card("Speak. It\u2019s typed.", "Just Speak to It for Mac", 2.5,
                 "Just Speak to It for Mac. " + SYNTHETIC),
            cut("recording", -4.0, "recording", 0.3,
                "In any app, double-tap your global shortcut to start (sent here by the test driver)", "fixture"),
            cut("recording", 0.3, "recording-captured", 1.2,
                "Speak naturally. This demo plays a synthetic audio clip, not a live microphone", "fixture"),
            cut("completed", -1.0, "paste", 0.0, "Tap again to stop. A test fixture returns fixed text", "fixture"),
            cut("paste", 0.0, "delivered", 0.0, "The text lands where you were typing", "fixture"),
            cut("show-mac-history-after", 0.0, "end", 0.0, "Every dictation is saved to History", "app"),
            cut("show-mac-transcription", 0.3, "shown-mac-transcription", -1.0,
                "Pick on-device models that keep audio on your Mac, or a cloud provider with your own key", "app"),
            cut("show-mac-post-processing", 0.3, "shown-mac-post-processing", -1.0,
                "Optional clean-up polishes punctuation and filler words", "app"),
            MAC_END,
        ],
    },
    "corrections": {
        "source": "mac", "size": LANDSCAPE, "badge": None, "poster": 1,
        "alt": "The Corrections page on Mac listing preferred spellings for names and jargon",
        "scenes": [
            card("Your words, spelled your way", "Personal corrections", 2.0,
                 "Personal corrections teach the app your names and jargon. " + SYNTHETIC),
            cut("show-mac-corrections", 0.3, "shown-mac-corrections", 0.0,
                "Add a preferred spelling once and every later dictation uses it", "app"),
            MAC_END,
        ],
    },
    "history": {
        "source": "mac", "size": LANDSCAPE, "badge": None, "poster": 1,
        "alt": "History on Mac and Linux: every past dictation with its model, length and actions",
        "scenes": [
            card("Nothing you said is lost", "History and recovery", 2.0,
                 "History keeps every dictation. " + SYNTHETIC),
            cut("show-mac-history", 0.3, "shown-mac-history", 0.0,
                "Search past dictations, see the raw and polished text and which model made it", "app"),
            still("linux:02-history", 3.5, "Play, retry, export or read aloud any session (Linux beta shown)"),
            MAC_END,
        ],
    },
    "models": {
        "source": "mac", "size": LANDSCAPE, "badge": None, "poster": 1,
        "alt": "Transcription and clean-up settings: on-device models alongside cloud providers",
        "scenes": [
            card("On-device or cloud. Your call.", "Choosing models", 2.0,
                 "Choose the speech model per session. " + SYNTHETIC),
            cut("show-mac-transcription", 0.3, "shown-mac-transcription", 0.0,
                "Run downloaded or Apple models on your Mac, or bring your own cloud provider key", "app"),
            cut("show-mac-post-processing", 0.3, "shown-mac-post-processing", 0.0,
                "Optional clean-up with on-device rules, Apple Intelligence or a model you choose", "app"),
            still("linux:05-transcription", 3.5, "Local whisper.cpp models on the Linux beta too"),
            MAC_END,
        ],
    },
    "iphone": {
        "source": "ios", "size": PORTRAIT, "badge": "iPhone", "poster": 2,
        "alt": "The iPhone app: tap record, see the words, copy them, then the Action Button settings",
        "scenes": [
            card("Speak on the go", "Just Speak to It for iPhone", 2.0,
                 "Just Speak to It for iPhone, recorded in the iOS Simulator. " + SYNTHETIC),
            cut("ready", 0.5, "recording", 0.3, "Tap the button to start"),
            cut("recording", 0.3, "stopped", 0.5,
                "Words appear as you speak. The Simulator uses fixed test text, not a microphone"),
            cut("stopped", 0.5, "copied", 2.0, "Stop, then copy the text into any app"),
            cut("history", 0.3, "settings", 0.0, "Every capture is kept in History"),
            cut("models", 0.0, "action-button", 0.0, "Use Apple\u2019s on-device speech, or a cloud model"),
            cut("action-button", 0.0, "end", 0.0,
                "Set what the Action Button and Shortcuts do with the words"),
            card("Just Speak to It", "On the App Store", 2.0, "Just Speak to It for iPhone"),
        ],
    },
    "windows": {
        "source": "windows", "size": LANDSCAPE, "badge": "Windows \u00b7 Beta", "poster": 2,
        "alt": "The Windows beta: dashboard, recording overlay, completed overlay and settings",
        "scenes": [
            card("Now on Windows", "Native beta \u00b7 unsigned developer build", 2.5,
                 "Just Speak to It for Windows, in beta. " + SYNTHETIC),
            still("windows:13-dashboard-dark", 3.0, "The dashboard shows your shortcut, model and recent text"),
            still("windows:15-dashboard-recording", 3.0, "Press Ctrl+Alt+Space in any app to start"),
            still("windows:16-hud-recording", 3.0, "A small overlay shows the words as you speak"),
            still("windows:17-hud-completed", 2.5, "Stop, and the text goes back into the window you were in"),
            still("windows:23-general-dark", 3.0, "Choose the microphone, text output, and the speak CLI and MCP"),
            card("Windows beta", "Download at justspeaktoit.com", 2.5,
                 "Windows beta. Download at justspeaktoit.com"),
        ],
    },
    "linux": {
        "source": "linux", "size": LANDSCAPE, "badge": "Linux \u00b7 Beta", "poster": 2,
        "alt": "The Linux beta: GTK dashboard, recording overlay, History and on-device models",
        "scenes": [
            card("Now on Linux", "Native GTK beta \u00b7 Flatpak", 2.5,
                 "Just Speak to It for Linux, in beta. " + SYNTHETIC),
            still("linux:01-dashboard", 3.0, "A native GTK 4 app with the same dashboard"),
            still("linux:16-dashboard-recording", 3.0, "Start dictation with a global shortcut"),
            still("linux:17-hud-recording", 3.0, "A small overlay shows the words as you speak"),
            still("linux:18-hud-completed", 2.5, "Stop, and the text is pasted into the original window"),
            still("linux:05-transcription", 3.0, "Use on-device whisper.cpp models or your own provider key"),
            card("Linux beta", "Download at justspeaktoit.com", 2.5,
                 "Linux beta. Download at justspeaktoit.com"),
        ],
    },
}


def font(kind, size):
    for path in FONT_CANDIDATES[kind]:
        if Path(path).exists():
            return ImageFont.truetype(path, size)
    raise SystemExit(f"No {kind} font found; install fonts-inter or fonts-dejavu-core")


def background(size):
    width, height = size
    image = Image.new("RGB", size, GROUND)
    glow = Image.new("RGB", size, GROUND)
    ImageDraw.Draw(glow).ellipse(
        (-width * 0.3, height * 0.45, width * 0.7, height * 1.6), fill=(70, 34, 24))
    return Image.blend(image, glow.filter(ImageFilter.GaussianBlur(width // 6)), 0.9)


def draw_badge(image, badge):
    if not badge:
        return image
    draw = ImageDraw.Draw(image)
    face = font("bold", 22)
    left, top, right, bottom = draw.textbbox((0, 0), badge, font=face)
    box = (24, 22, 24 + right - left + 32, 22 + bottom - top + 20)
    draw.rounded_rectangle(box, radius=(box[3] - box[1]) // 2, fill=(13, 15, 17), outline=LAGOON, width=2)
    draw.text((box[0] + 16 - left, box[1] + 10 - top), badge, font=face, fill=LAGOON)
    return image


def render_card(scene, size, badge, path):
    image = background(size)
    width, height = size
    draw = ImageDraw.Draw(image)
    icon = Image.open(ICON).convert("RGBA").resize((96, 96), Image.LANCZOS)
    title_face = font("bold", 60 if width > height else 44)
    sub_face = font("regular", 28 if width > height else 24)
    lines = wrap(draw, scene["title"], title_face, width - 120)
    line_height = title_face.size + 12
    block = 96 + 36 + line_height * len(lines) + 18 + sub_face.size
    y = (height - block) // 2
    image.paste(icon, ((width - 96) // 2, y), icon)
    y += 96 + 36
    for line in lines:
        text_width = draw.textlength(line, font=title_face)
        draw.text(((width - text_width) / 2, y), line, font=title_face, fill=TEXT)
        y += line_height
    y += 18
    draw.rectangle(((width - 64) // 2, y - 10, (width + 64) // 2, y - 6), fill=ACCENT)
    text_width = draw.textlength(scene["subtitle"], font=sub_face)
    draw.text(((width - text_width) / 2, y + 6), scene["subtitle"], font=sub_face, fill=DIM)
    draw_badge(image, badge).save(path)


def wrap(draw, text, face, limit):
    words, lines = text.split(), [""]
    for word in words:
        trial = f"{lines[-1]} {word}".strip()
        if draw.textlength(trial, font=face) <= limit or not lines[-1]:
            lines[-1] = trial
        else:
            lines.append(word)
    return lines


def render_still(source, size, badge, path):
    image = background(size)
    shot = Image.open(source).convert("RGB")
    width, height = size
    scale = min(1.0, (width - 120) / shot.width, (height - 130) / shot.height)
    if scale < 1.0:
        shot = shot.resize((round(shot.width * scale), round(shot.height * scale)), Image.LANCZOS)
    x, y = (width - shot.width) // 2, (height - shot.height) // 2 + 20
    shadow = Image.new("L", size, 0)
    ImageDraw.Draw(shadow).rounded_rectangle((x, y + 10, x + shot.width, y + shot.height + 10), radius=14, fill=150)
    image.paste((0, 0, 0), (0, 0), shadow.filter(ImageFilter.GaussianBlur(18)))
    mask = Image.new("L", shot.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, shot.width - 1, shot.height - 1), radius=10, fill=255)
    image.paste(shot, (x, y), mask)
    draw_badge(image, badge).save(path)


def overlay(size, badge, path):
    image = Image.new("RGBA", size, (0, 0, 0, 0))
    draw_badge(image, badge).save(path)


def run(*args):
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL, env={**os.environ, "SVT_LOG": "1"})


def encoders():
    output = subprocess.run(["ffmpeg", "-hide_banner", "-encoders"], capture_output=True, text=True).stdout
    return output


def find_still(captures, reference):
    platform, stem = reference.split(":")
    for extension in (".png", ".bmp"):
        candidate = captures / platform / f"{stem}{extension}"
        if candidate.exists():
            return candidate
    return None


def load_marks(folder):
    start = float((folder / "recording-start.txt").read_text())
    marks = {}
    for item in json.loads((folder / "marks.json").read_text()):
        marks.setdefault(item["name"], item["time"] - start)
    return marks


def recording(folder):
    for name in ("screen.mov", "screen.mp4"):
        if (folder / name).exists():
            return folder / name
    return None


# Measured from the 4 November 2026 hosted-runner recording (1600 x 900 points at 1x),
# used only when a capture predates the UI test's layout.json attachment.
FALLBACK_LAYOUT = {"screen": [0, 0, 1600, 900], "app": [262, 105, 1080, 720], "fixture": [0, 500, 640, 400]}


def crop_filter(kind, folder, screen, size):
    if not kind:
        return ""
    layout_file = folder / "layout.json"
    layout = dict(FALLBACK_LAYOUT)
    if layout_file.exists():
        layout.update(json.loads(layout_file.read_text()))
    probe = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                            "stream=width,height", "-of", "csv=p=0", str(screen)],
                           capture_output=True, text=True, check=True).stdout.strip().split(",")
    video_width, video_height = int(probe[0]), int(probe[1])
    screen_width, screen_height = layout["screen"][2], layout["screen"][3]
    scale = video_width / screen_width
    box_width, box_height = min(size[0], screen_width), min(size[1], screen_height)
    x, y, width, height = layout[kind]
    if kind == "app":
        left, top = x + width / 2 - box_width / 2, y + height / 2 - box_height / 2
    else:
        left, top = x, y + height - box_height
    left = max(0, min(left, screen_width - box_width))
    top = max(0, min(top, screen_height - box_height))
    width_px = min(video_width, round(box_width * scale))
    height_px = min(video_height, round(box_height * scale))
    return f"crop={width_px}:{height_px}:{round(left * scale)}:{round(top * scale)},"


def segment_filter(size, fade_in, length):
    width, height = size
    fades = f"fade=t=in:st=0:d=0.25,fade=t=out:st={max(length - 0.25, 0):.3f}:d=0.25" if fade_in else ""
    chain = (f"scale={width}:{height}:force_original_aspect_ratio=decrease:flags=lanczos,"
             f"pad={width}:{height}:(ow-iw)/2:(oh-ih)/2:color=0x121417,fps={FPS},format=yuv420p")
    return f"{chain},{fades}" if fades else chain


def render_clip(name, spec, captures, output, work):
    size, badge = spec["size"], spec["badge"]
    folder = captures / spec["source"]
    marks, screen = {}, None
    if spec["source"] in ("mac", "ios"):
        screen = recording(folder)
        if screen is None or not (folder / "marks.json").exists():
            print(f"skip {name}: no {spec['source']} recording", file=sys.stderr)
            return None
        marks = load_marks(folder)
    parts, cues, cursor = [], [], 0.0
    for index, scene in enumerate(spec["scenes"]):
        part = work / f"{name}-{index:02d}.mp4"
        if scene["kind"] == "card":
            frame = work / f"{name}-{index:02d}.png"
            render_card(scene, size, badge, frame)
            length = scene["seconds"]
            run("ffmpeg", "-y", "-loglevel", "error", "-loop", "1", "-t", f"{length}", "-i", str(frame),
                "-vf", segment_filter(size, True, length), "-c:v", "libx264", "-crf", "12", str(part))
        elif scene["kind"] == "still":
            source = find_still(captures, scene["name"])
            if source is None:
                print(f"{name}: missing still {scene['name']}, skipped", file=sys.stderr)
                continue
            frame = work / f"{name}-{index:02d}.png"
            render_still(source, size, badge, frame)
            length = scene["seconds"]
            run("ffmpeg", "-y", "-loglevel", "error", "-loop", "1", "-t", f"{length}", "-i", str(frame),
                "-vf", segment_filter(size, True, length), "-c:v", "libx264", "-crf", "12", str(part))
        else:
            (first, first_offset), (last, last_offset) = scene["start"], scene["end"]
            if first not in marks or last not in marks:
                print(f"{name}: marks {first}/{last} missing, scene skipped", file=sys.stderr)
                continue
            begin, end = marks[first] + first_offset, marks[last] + last_offset
            length = end - begin
            if length < 0.5:
                print(f"{name}: scene {first}->{last} too short ({length:.2f}s), skipped", file=sys.stderr)
                continue
            badge_png = work / f"{name}-badge.png"
            overlay(size, badge, badge_png)
            crop = crop_filter(scene.get("crop"), folder, screen, size)
            graph = (f"[0:v]trim=start={begin:.3f}:end={end:.3f},setpts=PTS-STARTPTS,{crop}"
                     f"{segment_filter(size, False, length)}[v];[1:v]format=rgba[b];"
                     f"[v][b]overlay=0:0,fade=t=in:st=0:d=0.2,fade=t=out:st={length - 0.2:.3f}:d=0.2,"
                     "format=yuv420p[out]")
            run("ffmpeg", "-y", "-loglevel", "error", "-i", str(screen), "-loop", "1", "-i", str(badge_png),
                "-filter_complex", graph, "-map", "[out]", "-t", f"{length:.3f}", "-an",
                "-c:v", "libx264", "-crf", "12", str(part))
        parts.append(part)
        cues.append((cursor, cursor + length, scene["caption"]))
        cursor += length
    if len(parts) < 3:
        print(f"skip {name}: only {len(parts)} scenes available", file=sys.stderr)
        return None

    listing = work / f"{name}.txt"
    listing.write_text("".join(f"file '{part}'\n" for part in parts))
    joined = work / f"{name}-joined.mp4"
    run("ffmpeg", "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", str(listing),
        "-c", "copy", str(joined))
    mp4, webm = output / f"{name}.mp4", output / f"{name}.webm"
    run("ffmpeg", "-y", "-loglevel", "error", "-i", str(joined), "-an", "-c:v", "libx264", "-preset", "veryslow",
        "-crf", "30", "-tune", "animation", "-profile:v", "high", "-pix_fmt", "yuv420p",
        "-g", str(FPS * 4), "-movflags", "+faststart", str(mp4))
    available = encoders()
    if "libsvtav1" in available:
        av = ["-c:v", "libsvtav1", "-preset", "4", "-crf", "52", "-g", str(FPS * 4)]
    elif "libaom-av1" in available:
        av = ["-c:v", "libaom-av1", "-cpu-used", "4", "-crf", "42", "-b:v", "0", "-row-mt", "1"]
    else:
        av = ["-c:v", "libvpx-vp9", "-crf", "40", "-b:v", "0", "-row-mt", "1"]
    run("ffmpeg", "-y", "-loglevel", "error", "-i", str(joined), "-an", *av, "-pix_fmt", "yuv420p", str(webm))

    lines = ["WEBVTT", ""]
    for begin, end, caption in cues:
        lines += [f"{stamp(begin)} --> {stamp(end)}", caption, ""]
    (output / f"{name}.en.vtt").write_text("\n".join(lines))

    poster_scene = min(spec["poster"], len(cues) - 1)
    begin, end, _ = cues[poster_scene]
    poster_png = work / f"{name}-poster.png"
    run("ffmpeg", "-y", "-loglevel", "error", "-ss", f"{begin + (end - begin) * 0.7:.3f}", "-i", str(joined),
        "-frames:v", "1", str(poster_png))
    Image.open(poster_png).convert("RGB").save(output / f"{name}-poster.webp", "WEBP", quality=72, method=6)
    width, height = size
    codec = av[1]
    return {
        "name": name, "duration": round(cursor, 2), "width": width, "height": height, "alt": spec["alt"],
        "badge": spec["badge"], "scenes": len(parts), "webm_codec": codec,
        "bytes": {path.name: path.stat().st_size for path in sorted(output.glob(f"{name}[.-]*"))},
    }


def stamp(seconds):
    minutes, rest = divmod(seconds, 60)
    return f"00:{int(minutes):02d}:{rest:06.3f}"


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("captures", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--only", nargs="*")
    args = parser.parse_args()
    if not shutil.which("ffmpeg"):
        raise SystemExit("ffmpeg is required")
    args.output.mkdir(parents=True, exist_ok=True)
    manifest = []
    with tempfile.TemporaryDirectory() as temporary:
        for name, spec in CLIPS.items():
            if args.only and name not in args.only:
                continue
            result = render_clip(name, spec, args.captures, args.output, Path(temporary))
            if result:
                manifest.append(result)
                print(json.dumps(result))
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()

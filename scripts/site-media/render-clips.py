#!/usr/bin/env python3
"""Render the website's narrated marketing clips, in light and dark, from real app captures.

Usage: render-clips.py <captures> <output> --voices <dir> [--only name ...]

<captures> holds one folder per source, produced on hosted CI runners by
.github/workflows/site-media.yml:
  mac-light/, mac-dark/  screen.mov, marks.json, layout.json, recording-start/stop.txt
  ios-light/, ios-dark/  ios-*.png  (full-screen Simulator screenshots from the UI test)
  windows/               NN-page.bmp or .png  (windows.yml --ui-screenshots tour)
  linux/                 NN-page.png          (linux.yml page screenshots)

Mac scenes are cut from the unedited screen recording at the UI test's scene marks;
stills are shown unretouched and never enlarged beyond 1x. (The Simulator's own
recorder writes variable-frame-rate video that drifts 9-17 s from the test clock, so
iPhone scenes use the test's exact screenshots instead.) The only additions are title
cards, a platform badge and narration.

Each scene's caption is also its narration, spoken by the Piper voice en_GB-cori-high
(trained on public-domain LibriVox recordings) with its two noise generators seeded,
so the same text always produces the same audio. A scene lasts at least as long as
its narration; a recorded scene that is shorter holds its last frame. Both
appearances share one timeline, so one caption file and one narration track serve
both. Each variant gets an H.264/AAC MP4, an AV1/Opus WebM (VP9 if no AV1 encoder)
and a WebP poster.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import wave
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[2]
ICON = ROOT / "landing-page" / "icon-512.png"
ACCENT = (255, 107, 61)
PALETTES = {
    "dark": {"ground": (18, 20, 23), "glow": (70, 34, 24), "text": (245, 243, 240), "dim": (173, 180, 189),
             "badge": (13, 15, 17), "badge_text": (46, 212, 191), "shadow": 150},
    "light": {"ground": (247, 245, 242), "glow": (255, 222, 205), "text": (23, 25, 28), "dim": (84, 91, 99),
              "badge": (255, 255, 255), "badge_text": (18, 128, 115), "shadow": 70},
}
APPEARANCES = ("light", "dark")
FPS = 30
LANDSCAPE, PORTRAIT = (1280, 720), (640, 1280)
NARRATION_LEAD, NARRATION_TAIL = 0.3, 0.6

VOICE = "en_GB-cori-high"
VOICE_URL = "https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/en/en_GB/cori/high/"
VOICE_SHA256 = {
    ".onnx": "470b4dd634c98f8a4850d7626ffc3dfc90774628eeef6605a6dd8f88f30a5903",
    ".onnx.json": "9e7fb5b5671612c22f3c81cbe46c1ae87b031a4632bcb509e499dad6f1e2adec",
}

FONT_CANDIDATES = {
    "bold": ["/usr/share/fonts/opentype/inter/Inter-Bold.otf", "/usr/share/fonts/truetype/inter/Inter-Bold.ttf",
             "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", "/System/Library/Fonts/HelveticaNeue.ttc"],
    "regular": ["/usr/share/fonts/opentype/inter/Inter-Regular.otf",
                "/usr/share/fonts/truetype/inter/Inter-Regular.ttf",
                "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", "/System/Library/Fonts/HelveticaNeue.ttc"],
}


def card(title, subtitle, caption, spoken=None, seconds=2.0):
    return {"kind": "card", "title": title, "subtitle": subtitle, "seconds": seconds, "caption": caption,
            "spoken": spoken}


def cut(start, start_offset, end, end_offset, caption, crop=None, spoken=None):
    """crop: None (whole screen), "app" (main window) or "fixture" (target app and recording HUD)."""
    return {"kind": "cut", "start": (start, start_offset), "end": (end, end_offset), "caption": caption,
            "crop": crop, "spoken": spoken}


def still(names, caption, spoken=None, seconds=2.5):
    """names: one "<source>:<page>" for both appearances, or a (light, dark) pair."""
    pair = names if isinstance(names, tuple) else (names, names)
    return {"kind": "still", "names": dict(zip(APPEARANCES, pair)), "seconds": seconds, "caption": caption,
            "spoken": spoken}


SITE = "justspeaktoit.com"
SITE_SPOKEN = "just speak to it dot com"
MAC_END = card("Just Speak to It", f"Download for Mac at {SITE}", f"Download it for Mac at {SITE}.",
               f"Download it for Mac at {SITE_SPOKEN}.")

CLIPS = {
    "hero": {
        "source": "mac", "size": LANDSCAPE, "badge": None, "poster": 4,
        "alt": "Dictating into a text field on a Mac, then finding the text in History",
        "scenes": [
            card("Speak. It\u2019s typed.", "Just Speak to It for Mac",
                 "Just Speak to It for Mac. Everything here is sample data."),
            cut("recording", -4.0, "recording", 0.3,
                "In any app, double-tap your shortcut to start. Here, a test driver presses it.", "fixture"),
            cut("recording", 0.3, "recording-captured", 1.2,
                "Speak naturally. This demo plays a synthetic clip, not a live microphone.", "fixture"),
            cut("completed", -1.0, "paste", 0.0, "Tap again to stop. A test fixture returns fixed text.", "fixture"),
            cut("paste", 0.0, "delivered", 0.0, "The text lands right where you were typing.", "fixture"),
            cut("show-mac-history-after", 0.0, "end", 0.0, "Every dictation is saved to History.", "app"),
            cut("show-mac-transcription", 0.3, "shown-mac-transcription", -1.0,
                "Pick on-device models that keep audio on your Mac, or a cloud provider with your own key.", "app"),
            MAC_END,
        ],
    },
    "corrections": {
        "source": "mac", "size": LANDSCAPE, "badge": None, "poster": 2,
        "alt": "The Corrections page on Mac listing preferred spellings for names and jargon",
        "scenes": [
            card("Your words, spelled your way", "Personal corrections",
                 "Personal corrections teach the app your names and jargon."),
            cut("show-mac-corrections", 0.3, "scrolled-mac-corrections", 0.0,
                "Add a preferred spelling once,", "app"),
            cut("scrolled-mac-corrections", 0.0, "shown-mac-corrections", 0.0,
                "and every later dictation uses it. These three rules are samples.", "app"),
            MAC_END,
        ],
    },
    "history": {
        "source": "mac", "size": LANDSCAPE, "badge": None, "poster": 1,
        "alt": "History on Mac and Linux: every past dictation with its model, length and actions",
        "scenes": [
            card("Nothing you said is lost", "History and recovery", "History keeps every dictation."),
            cut("show-mac-history", 0.3, "shown-mac-history", 0.0,
                "Search past dictations, and see the raw text, the polished text and the model that made it.",
                "app"),
            still(("linux:history", "linux:history-dark"),
                  "Replay, retry, export or read aloud any session. This frame is from the Linux beta."),
            MAC_END,
        ],
    },
    "models": {
        "source": "mac", "size": LANDSCAPE, "badge": None, "poster": 1,
        "alt": "Transcription and clean-up settings on Mac: on-device models alongside cloud providers",
        "scenes": [
            card("On-device or cloud. Your call.", "Choosing models", "Choose the speech model for each session."),
            cut("show-mac-transcription", 0.3, "shown-mac-transcription", 0.0,
                "Run downloaded or Apple models on your Mac, or bring your own cloud provider key.", "app"),
            cut("show-mac-post-processing", 0.3, "shown-mac-post-processing", 0.0,
                "Clean up with on-device rules, Apple Intelligence, or a model you choose.", "app"),
            MAC_END,
        ],
    },
    "iphone": {
        "source": "ios", "size": PORTRAIT, "badge": None, "poster": 2,
        "alt": "The iPhone app: tap record, see the words, copy them, then on-device and Action Button settings",
        "scenes": [
            card("Speak on the go", "Just Speak to It for iPhone",
                 "Just Speak to It for iPhone, in the iOS Simulator with sample text."),
            still("ios:ios-ready", "Tap the button to start."),
            still("ios:ios-recording", "Words appear as you speak. The Simulator uses fixed text, not a microphone."),
            still("ios:ios-transcript", "Stop, then copy the text into any app."),
            still("ios:ios-models", "Use Apple\u2019s on-device speech, or a cloud model."),
            still("ios:ios-action-button", "Choose what the Action Button and Shortcuts do with your words."),
            card("Just Speak to It", f"iPhone details at {SITE}", f"Find out more at {SITE}.",
                 f"Find out more at {SITE_SPOKEN}."),
        ],
    },
    "windows": {
        "source": "windows", "size": LANDSCAPE, "badge": "Windows \u00b7 Beta", "poster": 2,
        "alt": "The Windows beta: dashboard, shortcut, recording overlay, completed overlay and settings",
        "scenes": [
            card("Now on Windows", "Native beta \u00b7 unsigned developer build",
                 "Just Speak to It is now on Windows, in beta. Everything here is sample data."),
            still(("windows:dashboard", "windows:dashboard-dark"),
                  "The dashboard shows your shortcut, model and latest text."),
            still(("windows:keyboard", "windows:dashboard-recording"), "Press Ctrl+Alt+Space in any app to start.",
                  "Press control, alt, space, in any app to start."),
            still("windows:hud-recording", "A small overlay shows the words as you speak."),
            still("windows:hud-completed", "Stop, and the text goes back into the window you were in."),
            still(("windows:general", "windows:general-dark"),
                  "Settings cover the microphone, text output, and the speak CLI and MCP server.",
                  "Settings cover the microphone, text output, and the speak command line and M C P server."),
            card("Windows beta", f"Download at {SITE}", f"Download the Windows beta at {SITE}.",
                 f"Download the Windows beta at {SITE_SPOKEN}."),
        ],
    },
    "linux": {
        "source": "linux", "size": LANDSCAPE, "badge": "Linux \u00b7 Beta", "poster": 2,
        "alt": "The Linux beta: GTK dashboard, shortcut, recording overlay, completed overlay and settings",
        "scenes": [
            card("Now on Linux", "Native GTK beta \u00b7 Flatpak",
                 "Just Speak to It is now on Linux, in beta. Everything here is sample data."),
            still(("linux:dashboard", "linux:dashboard-dark"), "A native GTK app, with the same dashboard."),
            still(("linux:keyboard", "linux:dashboard-recording"),
                  "Start dictating from any app with a global shortcut."),
            still("linux:hud-recording", "A small overlay shows the words as you speak."),
            still("linux:hud-completed", "Stop, and the text is pasted into the original window."),
            still(("linux:general", "linux:general-dark"),
                  "Settings cover your microphone, how text is inserted, and more."),
            card("Linux beta", f"Download at {SITE}", f"Download the Linux beta at {SITE}.",
                 f"Download the Linux beta at {SITE_SPOKEN}."),
        ],
    },
}


def font(kind, size):
    for path in FONT_CANDIDATES[kind]:
        if Path(path).exists():
            return ImageFont.truetype(path, size)
    raise SystemExit(f"No {kind} font found; install fonts-inter or fonts-dejavu-core")


def background(size, palette):
    width, height = size
    image = Image.new("RGB", size, palette["ground"])
    glow = Image.new("RGB", size, palette["ground"])
    ImageDraw.Draw(glow).ellipse((-width * 0.3, height * 0.45, width * 0.7, height * 1.6), fill=palette["glow"])
    return Image.blend(image, glow.filter(ImageFilter.GaussianBlur(width // 6)), 0.9)


def draw_badge(image, badge, palette):
    if not badge:
        return image
    draw = ImageDraw.Draw(image)
    face = font("bold", 22)
    left, top, right, bottom = draw.textbbox((0, 0), badge, font=face)
    box = (24, 22, 24 + right - left + 32, 22 + bottom - top + 20)
    draw.rounded_rectangle(box, radius=(box[3] - box[1]) // 2, fill=palette["badge"],
                           outline=palette["badge_text"], width=2)
    draw.text((box[0] + 16 - left, box[1] + 10 - top), badge, font=face, fill=palette["badge_text"])
    return image


def wrap(draw, text, face, limit):
    lines = [""]
    for word in text.split():
        trial = f"{lines[-1]} {word}".strip()
        if draw.textlength(trial, font=face) <= limit or not lines[-1]:
            lines[-1] = trial
        else:
            lines.append(word)
    return lines


def render_card(scene, size, badge, palette, path):
    image = background(size, palette)
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
        draw.text(((width - draw.textlength(line, font=title_face)) / 2, y), line, font=title_face,
                  fill=palette["text"])
        y += line_height
    y += 18
    draw.rectangle(((width - 64) // 2, y - 10, (width + 64) // 2, y - 6), fill=ACCENT)
    for line in wrap(draw, scene["subtitle"], sub_face, width - 80):
        draw.text(((width - draw.textlength(line, font=sub_face)) / 2, y + 6), line, font=sub_face,
                  fill=palette["dim"])
        y += sub_face.size + 8
    draw_badge(image, badge, palette).save(path)


def render_still(source, size, badge, palette, path):
    image = background(size, palette)
    shot = Image.open(source).convert("RGB")
    width, height = size
    scale = min(1.0, (width - 120) / shot.width, (height - 130) / shot.height)
    if scale < 1.0:
        shot = shot.resize((round(shot.width * scale), round(shot.height * scale)), Image.LANCZOS)
    x, y = (width - shot.width) // 2, (height - shot.height) // 2 + 20
    shadow = Image.new("L", size, 0)
    ImageDraw.Draw(shadow).rounded_rectangle((x, y + 10, x + shot.width, y + shot.height + 10), radius=14,
                                             fill=palette["shadow"])
    image.paste((0, 0, 0), (0, 0), shadow.filter(ImageFilter.GaussianBlur(18)))
    mask = Image.new("L", shot.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, shot.width - 1, shot.height - 1), radius=10, fill=255)
    image.paste(shot, (x, y), mask)
    draw_badge(image, badge, palette).save(path)


def overlay(size, badge, palette, path):
    draw_badge(Image.new("RGBA", size, (0, 0, 0, 0)), badge, palette).save(path)


def run(*args):
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL, env={**os.environ, "SVT_LOG": "1"})


def probe_duration(path):
    return float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0",
                                 str(path)], capture_output=True, text=True, check=True).stdout.strip())


def find_still(captures, reference, appearance):
    source, page = reference.split(":")
    for folder in (captures / f"{source}-{appearance}", captures / source):
        if not folder.is_dir():
            continue
        if (folder / f"{page}.png").exists():
            return folder / f"{page}.png"
        # Tour screenshots are numbered (NN-page); match the page name, not the number.
        for candidate in sorted(folder.iterdir()):
            if re.fullmatch(rf"\d\d-{re.escape(page)}\.(png|bmp)", candidate.name):
                return candidate
    return None


def load_marks(folder, screen):
    start = float((folder / "recording-start.txt").read_text())
    shift = 0.0
    stop_file = folder / "recording-stop.txt"
    if stop_file.exists():
        # screencapture writes its first frame some seconds after it starts, so its
        # timeline is anchored to the stop request: video end == stop.
        shift = max(0.0, float(stop_file.read_text()) - start - probe_duration(screen))
    marks = {}
    for item in json.loads((folder / "marks.json").read_text()):
        marks.setdefault(item["name"], item["time"] - start - shift)
    return marks


# Measured from the 4 November 2026 hosted-runner recording (1600 x 900 points at 1x),
# used only when a capture predates the UI test's layout.json attachment.
FALLBACK_LAYOUT = {"screen": [0, 0, 1600, 900], "app": [262, 105, 1080, 720], "fixture": [0, 500, 640, 400]}


def crop_filter(kind, folder, screen, size):
    if not kind:
        return ""
    layout = dict(FALLBACK_LAYOUT)
    if (folder / "layout.json").exists():
        layout.update(json.loads((folder / "layout.json").read_text()))
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


def frame_filter(size, palette, length, hold=0.0):
    width, height = size
    colour = "0x%02x%02x%02x" % palette["ground"]
    chain = (f"scale={width}:{height}:force_original_aspect_ratio=decrease:flags=lanczos,"
             f"pad={width}:{height}:(ow-iw)/2:(oh-ih)/2:color={colour},fps={FPS}")
    if hold > 0:
        chain += f",tpad=stop_mode=clone:stop_duration={hold:.3f}"
    return (f"{chain},format=yuv420p,fade=t=in:st=0:d=0.2:color={colour},"
            f"fade=t=out:st={max(length - 0.2, 0):.3f}:d=0.2:color={colour}")


class Narrator:
    """Piper TTS with its noise generators seeded, so narration is reproducible."""

    def __init__(self, voices):
        voices.mkdir(parents=True, exist_ok=True)
        for suffix, digest in VOICE_SHA256.items():
            target = voices / f"{VOICE}{suffix}"
            if not target.exists() or hashlib.sha256(target.read_bytes()).hexdigest() != digest:
                print(f"downloading {VOICE}{suffix}", file=sys.stderr)
                urllib.request.urlretrieve(VOICE_URL + f"{VOICE}{suffix}", target)
                if hashlib.sha256(target.read_bytes()).hexdigest() != digest:
                    raise SystemExit(f"{target.name} does not match its pinned SHA-256")
        seeded = voices / f"{VOICE}-seeded.onnx"
        if not seeded.exists():
            import onnx
            model = onnx.load(voices / f"{VOICE}.onnx")
            for index, node in enumerate(model.graph.node):
                if node.op_type == "RandomNormalLike":
                    node.attribute.append(onnx.helper.make_attribute("seed", float(1358 + index)))
            onnx.save(model, seeded)
        from piper import PiperVoice
        self.voice = PiperVoice.load(seeded, config_path=voices / f"{VOICE}.onnx.json")

    def speak(self, text, path):
        with wave.open(str(path), "wb") as output:
            self.voice.synthesize_wav(text, output)
        return probe_duration(path)


def frames(seconds):
    return round(seconds * FPS) / FPS


def render_clip(name, spec, captures, output, work, narrator):
    size, badge, source = spec["size"], spec["badge"], spec["source"]
    recordings = {}
    if source == "mac":
        for appearance in APPEARANCES:
            folder = captures / f"mac-{appearance}"
            screen = folder / "screen.mov"
            if not screen.exists() or not (folder / "marks.json").exists():
                print(f"skip {name}: no {appearance} Mac recording", file=sys.stderr)
                return None
            recordings[appearance] = (folder, screen, load_marks(folder, screen))

    # Plan: a scene is kept only if both appearances can show it, and lasts as long as
    # the longest of its two visuals and its narration.
    plan = []
    for index, scene in enumerate(spec["scenes"]):
        visuals = {}
        for appearance in APPEARANCES:
            if scene["kind"] == "card":
                visuals[appearance] = (scene["seconds"], None)
            elif scene["kind"] == "still":
                path = find_still(captures, scene["names"][appearance], appearance)
                visuals[appearance] = (scene["seconds"], path) if path else None
            else:
                _, _, marks = recordings[appearance]
                (first, first_offset), (last, last_offset) = scene["start"], scene["end"]
                if first in marks and last in marks and marks[last] + last_offset - marks[first] - first_offset >= 0.5:
                    begin = marks[first] + first_offset
                    visuals[appearance] = (marks[last] + last_offset - begin, begin)
                else:
                    visuals[appearance] = None
        if not all(visuals.values()):
            print(f"{name}: scene {index} unavailable in {[a for a, v in visuals.items() if not v]}, skipped",
                  file=sys.stderr)
            continue
        voice = work / f"{name}-{index:02d}.wav"
        print(f"{name}: narrating scene {index}", flush=True)
        spoken = narrator.speak(scene["spoken"] or scene["caption"], voice)
        length = frames(max(max(value[0] for value in visuals.values()),
                            NARRATION_LEAD + spoken + NARRATION_TAIL))
        plan.append((index, scene, visuals, voice, length))
    if len(plan) < 3:
        print(f"skip {name}: only {len(plan)} scenes available", file=sys.stderr)
        return None

    audio_parts = []
    for index, _, _, voice, length in plan:
        part = work / f"{name}-{index:02d}-narration.wav"
        run("ffmpeg", "-y", "-loglevel", "error", "-i", str(voice), "-af",
            f"adelay={round(NARRATION_LEAD * 1000)}:all=1,apad=whole_dur={length:.3f},atrim=0:{length:.3f}",
            "-ar", "48000", "-ac", "1", str(part))
        audio_parts.append(part)
    narration = work / f"{name}-narration.wav"
    listing = work / f"{name}-narration.txt"
    listing.write_text("".join(f"file '{part}'\n" for part in audio_parts))
    run("ffmpeg", "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", str(listing), "-c", "copy",
        str(narration))

    available = subprocess.run(["ffmpeg", "-hide_banner", "-encoders"], capture_output=True, text=True).stdout
    if "libsvtav1" in available:
        av = ["-c:v", "libsvtav1", "-preset", "6", "-crf", "50", "-g", str(FPS * 4)]
    elif "libaom-av1" in available:
        av = ["-c:v", "libaom-av1", "-cpu-used", "4", "-crf", "46", "-b:v", "0", "-row-mt", "1"]
    else:
        av = ["-c:v", "libvpx-vp9", "-crf", "40", "-b:v", "0", "-row-mt", "1"]

    result = {"name": name, "width": size[0], "height": size[1], "alt": spec["alt"], "badge": badge,
              "scenes": len(plan), "webm_codec": av[1], "bytes": {}}
    for appearance in APPEARANCES:
        print(f"{name}: rendering {appearance} ({len(plan)} scenes, {sum(p[4] for p in plan):.1f}s)", flush=True)
        palette = PALETTES[appearance]
        parts = []
        for index, scene, visuals, _, length in plan:
            part = work / f"{name}-{appearance}-{index:02d}.mp4"
            visual_length, detail = visuals[appearance]
            if scene["kind"] in ("card", "still"):
                frame = work / f"{name}-{appearance}-{index:02d}.png"
                if scene["kind"] == "card":
                    render_card(scene, size, badge, palette, frame)
                else:
                    render_still(detail, size, badge, palette, frame)
                run("ffmpeg", "-y", "-loglevel", "error", "-loop", "1", "-t", f"{length:.3f}", "-i", str(frame),
                    "-vf", frame_filter(size, palette, length), "-t", f"{length:.3f}", "-c:v", "libx264",
                    "-crf", "12", str(part))
            else:
                folder, screen, _ = recordings[appearance]
                badge_png = work / f"{name}-{appearance}-badge.png"
                overlay(size, badge, palette, badge_png)
                crop = crop_filter(scene["crop"], folder, screen, size)
                graph = (f"[0:v]setpts=PTS-STARTPTS,{crop}"
                         f"{frame_filter(size, palette, length, length - visual_length)}[v];"
                         "[1:v]format=rgba[b];[v][b]overlay=0:0:eof_action=repeat,format=yuv420p[out]")
                run("ffmpeg", "-y", "-loglevel", "error", "-ss", f"{detail:.3f}", "-t", f"{visual_length:.3f}",
                    "-i", str(screen), "-i", str(badge_png), "-filter_complex", graph, "-map", "[out]",
                    "-t", f"{length:.3f}", "-an", "-c:v", "libx264", "-crf", "12", str(part))
            parts.append(part)
        listing = work / f"{name}-{appearance}.txt"
        listing.write_text("".join(f"file '{part}'\n" for part in parts))
        joined = work / f"{name}-{appearance}-joined.mp4"
        run("ffmpeg", "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", str(listing),
            "-c", "copy", str(joined))
        stem = output / f"{name}-{appearance}"
        run("ffmpeg", "-y", "-loglevel", "error", "-i", str(joined), "-i", str(narration), "-map", "0:v",
            "-map", "1:a", "-c:v", "libx264", "-preset", "veryslow", "-crf", "30", "-tune", "animation",
            "-profile:v", "high", "-pix_fmt", "yuv420p", "-g", str(FPS * 4), "-c:a", "aac", "-b:a", "48k",
            "-ac", "1", "-shortest", "-movflags", "+faststart", f"{stem}.mp4")
        run("ffmpeg", "-y", "-loglevel", "error", "-i", str(joined), "-i", str(narration), "-map", "0:v",
            "-map", "1:a", *av, "-pix_fmt", "yuv420p", "-c:a", "libopus", "-b:a", "32k", "-ac", "1",
            "-shortest", f"{stem}.webm")
        start = sum(length for _, _, _, _, length in plan[:spec["poster"]])
        poster_length = plan[min(spec["poster"], len(plan) - 1)][4]
        poster_png = work / f"{name}-{appearance}-poster.png"
        run("ffmpeg", "-y", "-loglevel", "error", "-ss", f"{start + poster_length * 0.7:.3f}", "-i", str(joined),
            "-frames:v", "1", str(poster_png))
        Image.open(poster_png).convert("RGB").save(f"{stem}-poster.webp", "WEBP", quality=72, method=6)

    lines, cursor = ["WEBVTT", ""], 0.0
    for _, scene, _, _, length in plan:
        lines += [f"{stamp(cursor)} --> {stamp(cursor + length)}", scene["caption"], ""]
        cursor += length
    (output / f"{name}.en.vtt").write_text("\n".join(lines))
    result["duration"] = round(cursor, 2)
    result["bytes"] = {path.name: path.stat().st_size for path in sorted(output.glob(f"{name}[.-]*"))}
    return result


def stamp(seconds):
    minutes, rest = divmod(seconds, 60)
    return f"00:{int(minutes):02d}:{rest:06.3f}"


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("captures", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--voices", type=Path, required=True, help="cache directory for the Piper voice")
    parser.add_argument("--only", nargs="*")
    args = parser.parse_args()
    if not shutil.which("ffmpeg"):
        raise SystemExit("ffmpeg is required")
    args.output.mkdir(parents=True, exist_ok=True)
    narrator = Narrator(args.voices)
    manifest = []
    with tempfile.TemporaryDirectory() as temporary:
        for name, spec in CLIPS.items():
            if args.only and name not in args.only:
                continue
            result = render_clip(name, spec, args.captures, args.output, Path(temporary), narrator)
            if result:
                manifest.append(result)
                print(json.dumps(result))
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()

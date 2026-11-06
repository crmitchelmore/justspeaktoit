#!/usr/bin/env python3
"""Cut the raw screen recording into the website demo using the UI test's scene marks.

Only scheduling time is removed (launch, the wait before the gesture driver starts,
the driver's 15 s stop window);
every kept frame is the unedited screen. Writes MP4, WebM, poster and WebVTT captions.
"""
import json
import subprocess
import sys
from pathlib import Path

capture = Path(sys.argv[1])
recording = capture / "screen.mov"
start = float((capture / "recording-start.txt").read_text())
marks = {item["name"]: item["time"] - start for item in json.loads((capture / "marks.json").read_text())}
out = capture / "demo"
out.mkdir(exist_ok=True)

# (from mark, offset, to mark, offset, caption)
SCENES = [
    ("show-mac-dashboard", 0.3, "show-mac-history", 0.0,
     "Dashboard in the real macOS app, filled with fictional sample History"),
    ("show-mac-history", 0.0, "tour-finished", 0.0, "History keeps every dictation, searchable"),
    ("recording", -4.0, "recording", 0.3,
     "In another app, a double-tap of the shortcut starts dictation (sent by the test driver)"),
    ("recording", 0.3, "recording-captured", 1.2,
     "Recording. This demo plays a synthetic audio clip, not a live microphone"),
    ("completed", -1.0, "paste", 0.0,
     "Stop with one tap. A test fixture returns fixed text instead of a speech provider"),
    ("paste", 0.0, "delivered", 0.0, "Clipboard output mode: Speak copies the text, then \u2318V pastes it"),
    ("show-mac-history-after", 0.0, "end", 0.0, "The new dictation is saved to History"),
]

segments = []
for first, first_offset, last, last_offset, caption in SCENES:
    begin, end = marks[first] + first_offset, marks[last] + last_offset
    if end - begin < 0.5:
        raise SystemExit(f"Scene {first}->{last} is too short ({end - begin:.2f}s)")
    segments.append((begin, end, caption))

filters, labels = [], []
for index, (begin, end, _) in enumerate(segments):
    filters.append(f"[0:v]trim=start={begin:.3f}:end={end:.3f},setpts=PTS-STARTPTS,fps=30[v{index}]")
    labels.append(f"[v{index}]")
filters.append(f"{''.join(labels)}concat=n={len(segments)}:v=1:a=0,scale='min(1280,iw)':-2:flags=lanczos,"
               "format=yuv420p[out]")
graph = ";".join(filters)


def run(*args):
    print(" ".join(args), flush=True)
    subprocess.run(args, check=True)


run("ffmpeg", "-y", "-loglevel", "error", "-i", str(recording), "-filter_complex", graph, "-map", "[out]",
    "-an", "-c:v", "libx264", "-preset", "slow", "-crf", "26", "-movflags", "+faststart",
    str(out / "speak-demo.mp4"))
run("ffmpeg", "-y", "-loglevel", "error", "-i", str(out / "speak-demo.mp4"), "-an", "-c:v", "libvpx-vp9",
    "-b:v", "0", "-crf", "38", "-row-mt", "1", str(out / "speak-demo.webm"))

cues, cursor = ["WEBVTT", ""], 0.0


def stamp(seconds):
    minutes, rest = divmod(seconds, 60)
    return f"00:{int(minutes):02d}:{rest:06.3f}"


poster_at = 0.0
for begin, end, caption in segments:
    length = end - begin
    cues += [f"{stamp(cursor)} --> {stamp(cursor + length)}", caption, ""]
    if caption.startswith("Clipboard output"):
        poster_at = cursor + length - 0.5
    cursor += length
(out / "speak-demo.en.vtt").write_text("\n".join(cues))
run("ffmpeg", "-y", "-loglevel", "error", "-ss", f"{poster_at:.2f}", "-i", str(out / "speak-demo.mp4"),
    "-frames:v", "1", str(out / "speak-demo-poster.png"))
print(json.dumps({"duration": round(cursor, 2), "segments": len(segments)}))

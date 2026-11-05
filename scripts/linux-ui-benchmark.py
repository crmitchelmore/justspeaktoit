#!/usr/bin/env python3
"""Measure an owned app on the current Hyprland session, without input injection.

Run with no existing Just Speak to It instance or competing build/benchmark.
Results measure compositor mapping (not first usable transcript), warm-cache
launches, and one settled idle sample. The app gets a disposable data directory;
logs are private files and only aggregate process metrics are printed.
"""
import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess
import tempfile
import time


def process_metrics(pid):
    fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
    status = Path(f"/proc/{pid}/status").read_text().splitlines()
    rss = next(int(line.split()[1]) * 1024 for line in status if line.startswith("VmRSS:"))
    return (int(fields[11]) + int(fields[12])) / os.sysconf("SC_CLK_TCK"), rss


def benchmark(binary, runs=7, idle_seconds=10):
    existing = json.loads(subprocess.check_output(["hyprctl", "clients", "-j"]))
    if any(item["class"] == "com.justspeaktoit.JustSpeakToIt" for item in existing):
        raise RuntimeError("Close Just Speak to It first; the benchmark never closes someone else's window")
    samples = []
    with tempfile.TemporaryDirectory(prefix="jsti-ui-benchmark-") as scratch:
        root = Path(scratch)
        data = root / "JustSpeakToIt"
        data.mkdir()
        # Skip the first-run guide in the disposable fixture only.
        (data / "onboarding.json").write_text('{"hasCompletedOnboarding":true,"lastStep":"done"}')
        environment = dict(os.environ, XDG_DATA_HOME=str(root), GDK_BACKEND="wayland", GGML_NO_BACKTRACE="1")
        for index in range(runs):
            with (root / f"run-{index}.log").open("w") as log:
                started = time.monotonic()
                child = subprocess.Popen([str(binary)], env=environment, stdout=log, stderr=log)
                try:
                    while True:
                        if child.poll() is not None:
                            raise RuntimeError(f"app exited before mapping: {child.returncode}")
                        if time.monotonic() - started > 15:
                            raise TimeoutError("owned app did not map within 15 seconds")
                        clients = json.loads(subprocess.check_output(["hyprctl", "clients", "-j"]))
                        if any(item["pid"] == child.pid and item["mapped"] for item in clients):
                            break
                        time.sleep(0.025)
                    mapped = time.monotonic() - started
                    time.sleep(2)
                    cpu_before, rss = process_metrics(child.pid)
                    cpu_percent = None
                    if index == runs - 1:
                        before = time.monotonic()
                        time.sleep(idle_seconds)
                        cpu_after, rss = process_metrics(child.pid)
                        cpu_percent = 100 * (cpu_after - cpu_before) / (time.monotonic() - before)
                    samples.append({"map_seconds": round(mapped, 4), "rss_bytes": rss,
                                    "idle_cpu_percent_one_core": cpu_percent})
                finally:
                    if child.poll() is None:
                        child.terminate()
                        try:
                            child.wait(timeout=10)
                        except subprocess.TimeoutExpired:
                            child.kill()
                            child.wait()
    return {"binary": str(binary), "cache": "warm filesystem cache; no cache eviction", "runs": samples,
            "median_map_seconds": statistics.median(x["map_seconds"] for x in samples),
            "p95_map_seconds": sorted(x["map_seconds"] for x in samples)[int(0.95 * len(samples))],
            "idle_seconds": idle_seconds, "maximum_rss_bytes": max(x["rss_bytes"] for x in samples)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    result = benchmark(args.binary.resolve(strict=True))
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))

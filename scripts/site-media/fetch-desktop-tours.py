#!/usr/bin/env python3
"""Download the newest Windows and Linux page-screenshot tours captured on GitHub-hosted runners.

Usage: fetch-desktop-tours.py <destination>   (needs `gh` with actions:read)

windows.yml and linux.yml already drive the native apps through every page with
fictional sample History (`--ui-screenshots`, JSTI_UI_SCREENSHOT_DIR). This picks
the newest successful main-branch run whose screenshot job ran on a GitHub-hosted
runner, so no footage comes from a self-hosted or personal machine, and writes
<destination>/{windows,linux}/ plus source.json naming the exact runs used.
"""
import json
import os
import subprocess
import sys
from pathlib import Path

REPOSITORY = os.environ.get("GITHUB_REPOSITORY", "crmitchelmore/justspeaktoit")
TOURS = {
    "windows": ("windows.yml", "Native Windows", "windows-ui-screenshots-"),
    "linux": ("linux.yml", "Linux desktop", "linux-ui-screenshots"),
}


def api(path):
    result = subprocess.run(["gh", "api", f"repos/{REPOSITORY}/{path}"], capture_output=True, text=True, check=True)
    return json.loads(result.stdout)


def newest_hosted_tour(workflow, job_prefix, artifact_prefix):
    runs = api(f"actions/workflows/{workflow}/runs?branch=main&status=success&per_page=30")["workflow_runs"]
    for run in runs:
        jobs = api(f"actions/runs/{run['id']}/jobs?per_page=100")["jobs"]
        job = next((job for job in jobs if job["name"].startswith(job_prefix)), None)
        if job is None or job.get("runner_group_name") != "GitHub Actions":
            continue
        artifacts = api(f"actions/runs/{run['id']}/artifacts?per_page=100")["artifacts"]
        artifact = next((item for item in artifacts
                         if item["name"].startswith(artifact_prefix) and not item["expired"]), None)
        if artifact:
            return run, job, artifact
    return None


def main():
    destination = Path(sys.argv[1])
    sources = {}
    for platform, (workflow, job_prefix, artifact_prefix) in TOURS.items():
        found = newest_hosted_tour(workflow, job_prefix, artifact_prefix)
        if found is None:
            print(f"::warning::No hosted {platform} screenshot tour available", file=sys.stderr)
            continue
        run, job, artifact = found
        target = destination / platform
        target.mkdir(parents=True, exist_ok=True)
        subprocess.run(["gh", "run", "download", str(run["id"]), "--repo", REPOSITORY, "--name", artifact["name"],
                        "--dir", str(target)], check=True)
        sources[platform] = {"run": run["id"], "sha": run["head_sha"], "job": job["name"],
                             "runner": job.get("labels"), "artifact": artifact["name"]}
        print(f"{platform}: run {run['id']} ({run['head_sha'][:8]}) on {job.get('labels')}")
    (destination / "source.json").write_text(json.dumps(sources, indent=2) + "\n")
    if not sources:
        raise SystemExit("No desktop tours found")


if __name__ == "__main__":
    main()

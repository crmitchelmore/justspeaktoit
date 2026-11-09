#!/usr/bin/env python3
"""Helpers for the self-hosted Flatpak repository (see Docs/linux-packaging.md).

The workflow builds a signed OSTree repository from the qualified Alpha bundle
and deploys it as a static Cloudflare Pages site. This script owns the parts
that are easy to get wrong and worth unit-testing: the .flatpakref and
.flatpakrepo descriptors, the static-host limits and the "never publish an
older Alpha over a newer one" rule.
"""

from __future__ import annotations

import argparse
import base64
import json
import re
import sys
from pathlib import Path

APP_ID = "com.justspeaktoit.JustSpeakToIt"
BRANCH = "master"
REMOTE_NAME = "justspeaktoit"
TITLE = "Just Speak to It"
HOMEPAGE = "https://justspeaktoit.com"
RUNTIME_REPO = "https://dl.flathub.org/repo/flathub.flatpakrepo"
REF_FILE = f"{APP_ID}.flatpakref"
REPO_FILE = f"{REMOTE_NAME}.flatpakrepo"
# Cloudflare Pages limits for a single deployment.
MAX_FILES = 20_000
MAX_FILE_BYTES = 25 * 1024 * 1024
TAG = re.compile(r"^alpha-build-([1-9][0-9]*)$")


def build_number(tag: str) -> int:
    match = TAG.match(tag)
    if not match:
        raise ValueError(f"not an Alpha tag: {tag!r}")
    return int(match.group(1))


def should_publish(candidate: str, published: str | None) -> bool:
    """Only a strictly newer Alpha may replace the published one."""
    candidate_build = build_number(candidate)
    if not published:
        return True
    try:
        return candidate_build > build_number(published)
    except ValueError:
        return True


def _repo_url(url: str) -> str:
    if not url.startswith("https://"):
        raise ValueError("the repository URL must use https")
    return url if url.endswith("/") else url + "/"


def flatpakrepo(repo_url: str, gpg_key: bytes) -> str:
    return "\n".join([
        "[Flatpak Repo]",
        f"Title={TITLE}",
        f"Url={_repo_url(repo_url)}",
        f"Homepage={HOMEPAGE}",
        f"Comment=Signed Linux builds of {TITLE}",
        f"DefaultBranch={BRANCH}",
        f"GPGKey={base64.b64encode(gpg_key).decode('ascii')}",
        "",
    ])


def flatpakref(repo_url: str, gpg_key: bytes) -> str:
    return "\n".join([
        "[Flatpak Ref]",
        f"Name={APP_ID}",
        f"Branch={BRANCH}",
        f"Title={TITLE}",
        f"Url={_repo_url(repo_url)}",
        f"SuggestRemoteName={REMOTE_NAME}",
        f"Homepage={HOMEPAGE}",
        f"RuntimeRepo={RUNTIME_REPO}",
        "IsRuntime=false",
        f"GPGKey={base64.b64encode(gpg_key).decode('ascii')}",
        "",
    ])


def write_descriptors(site: Path, repo_url: str, gpg_key: bytes, tag: str) -> None:
    if not gpg_key:
        raise ValueError("the public GPG key is empty")
    build_number(tag)
    site.mkdir(parents=True, exist_ok=True)
    (site / REF_FILE).write_text(flatpakref(repo_url, gpg_key), encoding="utf-8")
    (site / REPO_FILE).write_text(flatpakrepo(repo_url, gpg_key), encoding="utf-8")
    (site / "channel.json").write_text(json.dumps({"schemaVersion": 1, "tag": tag, "branch": BRANCH}) + "\n")
    # Without a top-level 404.html, Pages answers unknown paths with index.html
    # and a 200, which OSTree would read as a corrupt object.
    (site / "404.html").write_text("Not found\n", encoding="utf-8")
    (site / "_headers").write_text(
        f"/{REF_FILE}\n  Content-Type: application/vnd.flatpak.ref\n"
        f"/{REPO_FILE}\n  Content-Type: application/vnd.flatpak.repo\n"
        "/repo/*\n  X-Content-Type-Options: nosniff\n",
        encoding="utf-8",
    )


def check_site(site: Path) -> list[str]:
    files = [path for path in site.rglob("*") if path.is_file()]
    problems = []
    if len(files) > MAX_FILES:
        problems.append(f"{len(files)} files exceed the {MAX_FILES}-file Pages limit")
    for path in files:
        if path.stat().st_size > MAX_FILE_BYTES:
            problems.append(f"{path.relative_to(site)} exceeds {MAX_FILE_BYTES} bytes")
    return problems


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    descriptors = commands.add_parser("descriptors")
    descriptors.add_argument("--site", type=Path, required=True)
    descriptors.add_argument("--repo-url", required=True)
    descriptors.add_argument("--public-key", type=Path, required=True)
    descriptors.add_argument("--tag", required=True)
    check = commands.add_parser("check-site")
    check.add_argument("site", type=Path)
    newer = commands.add_parser("should-publish")
    newer.add_argument("--tag", required=True)
    newer.add_argument("--published-channel", type=Path, help="channel.json currently served, if any")
    args = parser.parse_args(argv)

    if args.command == "descriptors":
        write_descriptors(args.site, args.repo_url, args.public_key.read_bytes(), args.tag)
        return 0
    if args.command == "check-site":
        problems = check_site(args.site)
        for problem in problems:
            print(f"::error::{problem}")
        return 1 if problems else 0
    published = None
    if args.published_channel and args.published_channel.is_file():
        try:
            published = json.loads(args.published_channel.read_text()).get("tag")
        except (json.JSONDecodeError, AttributeError):
            published = None
    print("true" if should_publish(args.tag, published) else "false")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

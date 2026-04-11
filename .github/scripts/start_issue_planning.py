#!/usr/bin/env python3

import argparse
import json
import subprocess

PLANNING_LABELS = [
    "planning:in-discussion",
    "planning:needs-product",
    "planning:needs-security",
    "planning:needs-performance",
    "planning:needs-quality",
    "planning:needs-architecture",
    "planning:needs-reliability",
    "planning:needs-design",
]

RESET_LABELS = [
    "triage:pending-product-validation",
    "triage:product-fit",
    "triage:needs-clarification",
    "triage:out-of-scope",
    "planning:ready-for-dev",
    "planning:product-approved",
    "planning:security-approved",
    "planning:performance-approved",
    "planning:quality-approved",
    "planning:architecture-approved",
    "planning:reliability-approved",
    "planning:design-approved",
]

INITIAL_ROLE_WORKFLOW = "issue-planning-product.lock.yml"


def gh_json(*args: str):
    return json.loads(subprocess.check_output(["gh", *args], text=True))


def gh(*args: str) -> None:
    print("+", "gh", *args)
    subprocess.run(["gh", *args], check=True)


def build_kickoff_body(mode: str, author: str, issue_number: str, context: str) -> str:
    planning_summary = (
        "Planning now runs in a single active lane: Alex Hale (Product) starts, then the next specialist joins only after the current role has either approved or finished its questions. "
        "Sam Chen (Engineering Manager) stays out of the normal back-and-forth until the specialist pass is complete or he explicitly challenges a named role to reply. "
        "Answer the active role's questions in-thread until that role converges, then the workflow advances to the next step."
    )
    if mode == "auto":
        return (
            "### 🗂️ Planning Kickoff\n\n"
            f"This issue was created by `@{author}`, who already has repository write access, so Product validation started full planning automatically once the issue was marked `triage:product-fit`. "
            f"{planning_summary}\n\n"
            f"When `planning:ready-for-dev` appears, `Issue Ready to PR` will attempt to implement this plan and should open a pull request that includes `Plan issue: #{issue_number}` in the body."
        )

    body = (
        "### 🗂️ Planning Kickoff\n\n"
        f"`/doit` from `@{author}` was accepted, so {planning_summary}"
    )
    if context:
        body += "\n\n**Maintainer context from the `/doit` comment:**\n" + "\n".join(
            f"> {line}" for line in context.splitlines()
        )
    body += (
        "\n\n"
        f"When `planning:ready-for-dev` appears, `Issue Ready to PR` will attempt to implement this plan and should open a pull request that includes `Plan issue: #{issue_number}` in the body."
    )
    return body


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--issue-number", required=True)
    parser.add_argument("--author", required=True)
    parser.add_argument("--mode", choices=("manual", "auto"), required=True)
    parser.add_argument("--context", default="")
    args = parser.parse_args()

    issue = gh_json(
        "issue",
        "view",
        args.issue_number,
        "--repo",
        args.repo,
        "--json",
        "labels,comments",
    )
    labels = {label["name"] for label in issue.get("labels", [])}
    comments = issue.get("comments", [])

    if any(comment.get("body", "").startswith("### 🗂️ Planning Kickoff") for comment in comments):
        print(f"Issue #{args.issue_number} already has a planning kickoff comment; nothing to do.")
        return

    add_labels = sorted(label for label in PLANNING_LABELS if label not in labels)
    remove_labels = sorted(label for label in RESET_LABELS if label in labels)
    if add_labels or remove_labels:
        cmd = ["issue", "edit", args.issue_number, "--repo", args.repo]
        if add_labels:
            cmd.extend(["--add-label", ",".join(add_labels)])
        if remove_labels:
            cmd.extend(["--remove-label", ",".join(remove_labels)])
        gh(*cmd)

    gh(
        "issue",
        "comment",
        args.issue_number,
        "--repo",
        args.repo,
        "--body",
        build_kickoff_body(args.mode, args.author, args.issue_number, args.context),
    )

    try:
        gh(
            "workflow",
            "run",
            INITIAL_ROLE_WORKFLOW,
            "--repo",
            args.repo,
            "-f",
            f"issue_number={args.issue_number}",
        )
    except subprocess.CalledProcessError:
        print(
            f"Warning: failed to dispatch {INITIAL_ROLE_WORKFLOW} for issue "
            f"#{args.issue_number}"
        )


if __name__ == "__main__":
    main()

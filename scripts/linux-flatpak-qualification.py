"""Fail-closed provenance and sandbox preconditions for Flatpak qualification."""
import re
import subprocess
import sys


def source_metadata(run, sha, repo, run_id, harness_sha):
    if (run['head_sha'] != sha or run['head_repository']['full_name'] != repo
            or run['path'] != '.github/workflows/linux-flatpak.yml'
            or run['status'] != 'completed' or run['conclusion'] != 'success'):
        raise ValueError('Trusted retests require a successful source run for the requested repository and SHA')
    # Associated PR head.sha follows later pushes; run.head_sha is immutable.
    return {'runID': run_id, 'sourceSHA': sha, 'repository': repo, 'workflow': run['path'],
            'harnessSHA': harness_sha, 'event': run['event'],
            'pullRequestParents': [{'baseSHA': pr['base']['sha']} for pr in run.get('pull_requests', [])
                if pr['head']['repo']['id'] == run['repository']['id']
                and pr['base']['repo']['id'] == run['repository']['id']]}


def check_overrides(app):
    if not re.fullmatch(r'[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+){2,}', app):
        raise ValueError('Invalid application ID')
    for scope in ('--user', '--system'):
        for target in ([], [app]):
            command = ['flatpak', 'override', scope, '--show', *target]
            result = subprocess.run(command, capture_output=True, text=True)
            if result.returncode != 0:
                raise ValueError('Cannot inspect Flatpak overrides; qualification refused')
            if result.stdout.strip():
                # Never print override values, which may contain private environment data.
                raise ValueError('Existing Flatpak overrides prevent qualification; use a clean host')


if __name__ == '__main__':
    if len(sys.argv) != 3 or sys.argv[1] != 'check-overrides':
        raise SystemExit('usage: linux-flatpak-qualification.py check-overrides <application-id>')
    check_overrides(sys.argv[2])

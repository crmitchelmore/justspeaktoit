"""Fail-closed provenance and sandbox preconditions for Flatpak qualification."""
import hashlib
import json
import os
from pathlib import Path
import re
import runpy
import subprocess
import sys


WORKFLOW = '.github/workflows/linux-flatpak.yml'
VERIFY = runpy.run_path(str(Path(__file__).resolve().parents[1] / 'packaging/linux/verify_build_revision.py'))


def source_metadata(run, sha, repo, run_id, harness_sha):
    if (str(run['id']) != run_id or run['head_sha'] != sha or run['head_repository']['full_name'] != repo
            or run['repository']['full_name'] != repo or run['head_repository']['id'] != run['repository']['id']
            or not VERIFY['positive'](run['head_repository']['id'])
            or not VERIFY['positive'](run['repository']['id']) or not VERIFY['positive'](run['run_attempt'])
            or run['path'] != WORKFLOW or run['event'] not in ('pull_request', 'push', 'workflow_dispatch')
            or run['status'] != 'completed' or run['conclusion'] != 'success'):
        raise ValueError('Trusted retests require a successful source run for the requested repository, SHA and attempt')
    # Run identity/head/attempt remain authoritative after PR association/base
    # metadata changes. Ordered PR parents come only from its authenticated artifact.
    return {'runID': run_id, 'runAttempt': run['run_attempt'], 'sourceSHA': sha,
            'repository': repo, 'repositoryID': run['repository']['id'], 'workflow': run['path'],
            'harnessSHA': harness_sha, 'event': run['event']}


def file_digest(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def checkout_parents(git, revision='HEAD'):
    # Raw object headers retain parents even in checkout's shallow clone.
    kind = subprocess.check_output([*git, 'cat-file', '-t', revision], text=True).strip()
    if kind != 'commit':
        raise ValueError('Artifact checkout evidence must identify an actual git commit')
    commit = subprocess.check_output([*git, 'cat-file', '-p', revision], text=True)
    return [line.removeprefix('parent ') for line in commit.split('\n\n', 1)[0].splitlines()
            if line.startswith('parent ')]


def build_record(environment, event, built_sha, parents, bundle_sha256):
    repository = environment['GITHUB_REPOSITORY']
    workflow_prefix = repository + '/' + WORKFLOW + '@'
    if (not environment['GITHUB_WORKFLOW_REF'].startswith(workflow_prefix)
            or not environment['GITHUB_WORKFLOW_REF'][len(workflow_prefix):]):
        raise ValueError('Unexpected build workflow identity')
    for key in ('GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT', 'GITHUB_REPOSITORY_ID'):
        if re.fullmatch(r'[1-9][0-9]*', environment[key]) is None:
            raise ValueError('Invalid build run identity')
    repository_id = int(environment['GITHUB_REPOSITORY_ID'])
    if (not VERIFY['positive'](event['repository']['id']) or event['repository']['id'] != repository_id
            or event['repository']['full_name'] != repository):
        raise ValueError('Build event repository does not match its Actions environment')
    request = None
    source_sha = environment['GITHUB_SHA']
    if environment['GITHUB_EVENT_NAME'] == 'pull_request':
        pull = event['pull_request']
        source_sha = pull['head']['sha']
        request = {'number': event['number'], 'headSHA': source_sha, 'baseSHA': pull['base']['sha'],
                   'headRepositoryID': pull['head']['repo']['id'], 'baseRepositoryID': pull['base']['repo']['id']}
    metadata = {'runID': environment['GITHUB_RUN_ID'], 'runAttempt': int(environment['GITHUB_RUN_ATTEMPT']),
                'repository': repository, 'repositoryID': repository_id, 'workflow': WORKFLOW,
                'event': environment['GITHUB_EVENT_NAME'], 'sourceSHA': source_sha}
    record = dict(metadata, version=1, builtRevision=built_sha, parents=parents,
                  bundleSHA256=bundle_sha256, pullRequest=request)
    if environment['GITHUB_SHA'] != built_sha:
        raise ValueError('Build checkout does not match its Actions environment')
    VERIFY['verify_revision'](built_sha, parents, metadata, record, bundle_sha256)
    return record


def artifact_files(directory):
    # Call only after downloading the fixed-name artifact from the authenticated
    # source run. A local record by itself never establishes artifact authority.
    if not directory.is_dir() or directory.is_symlink():
        raise ValueError('Authenticated artifact directory must be a regular directory')
    result = []
    for name in ('JustSpeakToIt-x86_64.flatpak', 'source-revision.txt', 'build-provenance.json'):
        matches = list(directory.rglob(name))
        if len(matches) != 1:
            raise ValueError('Fresh build required: missing or ambiguous artifact bundle/provenance')
        path = matches[0]
        if (not path.is_file() or path.is_symlink() or not path.resolve().is_relative_to(directory.resolve())
                or any((directory / parent).is_symlink() for parent in path.relative_to(directory).parents
                       if parent != Path('.'))):
            raise ValueError('Artifact bundle/provenance must be regular files inside the authenticated artifact')
        result.append(path)
    return tuple(result)


def load_record(path):
    if path.stat().st_size > 65536:
        raise ValueError('Build record exceeds its bounded metadata size')
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('Duplicate build record field')
            result[key] = value
        return result
    return json.loads(path.read_text(), object_pairs_hook=unique)


def write_build_record(bundle, output):
    git = ['git', '-c', 'safe.directory=' + os.getcwd()]
    built_sha = subprocess.check_output([*git, 'rev-parse', 'HEAD'], text=True).strip()
    event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
    record = build_record(os.environ, event, built_sha, checkout_parents(git), file_digest(bundle))
    with output.open('x') as target:
        target.write(json.dumps(record, indent=2) + '\n')


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
    if len(sys.argv) == 3 and sys.argv[1] == 'check-overrides':
        check_overrides(sys.argv[2])
    elif len(sys.argv) == 4 and sys.argv[1] == 'record-build':
        write_build_record(Path(sys.argv[2]), Path(sys.argv[3]))
    else:
        raise SystemExit('usage: linux-flatpak-qualification.py check-overrides <app> | record-build <bundle> <record>')

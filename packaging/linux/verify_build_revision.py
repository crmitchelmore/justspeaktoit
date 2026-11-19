"""Bind an authenticated artifact's build record to its Actions run and git object.

The record is evidence only inside the fixed-name artifact downloaded from the
verified successful source run. It is not an independently trusted attestation.
"""
import re

WORKFLOW = '.github/workflows/linux-flatpak.yml'
IDENTITY = ('runID', 'runAttempt', 'repository', 'repositoryID', 'workflow', 'event', 'sourceSHA')
FIELDS = {*IDENTITY, 'version', 'builtRevision', 'parents', 'bundleSHA256', 'pullRequest', 'postHogKeyStamped'}
# The refs whose builds are stamped with the PostHog project key. Keep in step
# with the stamp step's `if` in the Windows and Linux release workflows.
STAMPED_TAG_PREFIXES = ('refs/tags/alpha-build-', 'refs/tags/stable-candidate-')


def requires_stamped_key(event, ref):
    return (event == 'push' and ref == 'refs/heads/main') or ref.startswith(STAMPED_TAG_PREFIXES)


def positive(value):
    return type(value) is int and value > 0


def sha(value, length=40):
    return isinstance(value, str) and re.fullmatch('[0-9a-f]{' + str(length) + '}', value) is not None


def verify_revision(built_sha, parents, metadata, record, bundle_sha256, require_stamped=False):
    if not isinstance(record, dict) or set(record) != FIELDS or type(record['version']) is not int or record['version'] != 1:
        raise ValueError('Fresh build required: missing or unsupported immutable build record')
    if type(record['postHogKeyStamped']) is not bool:
        raise ValueError('Fresh build required: the build record does not say whether the bundle was stamped')
    if require_stamped and not record['postHogKeyStamped']:
        raise ValueError('Fresh build required: this retest needs a bundle stamped with the PostHog project key, '
                         'but the recorded build was keyless')
    if (any(record[key] != metadata.get(key) for key in IDENTITY)
            or not isinstance(record['runID'], str) or re.fullmatch(r'[1-9][0-9]*', record['runID']) is None
            or not positive(record['runAttempt']) or not positive(record['repositoryID'])
            or record['workflow'] != WORKFLOW or record['event'] not in ('pull_request', 'push', 'workflow_dispatch')
            or not sha(record['sourceSHA'])):
        raise ValueError('Build record does not match the authenticated source run and attempt')
    if (not sha(built_sha) or not sha(bundle_sha256, 64)
            or record['builtRevision'] != built_sha or record['parents'] != parents
            or not isinstance(parents, list) or any(not sha(parent) for parent in parents)
            or record['bundleSHA256'] != bundle_sha256):
        raise ValueError('Build record does not match the artifact bundle or actual checkout parents')
    source_sha = metadata['sourceSHA']
    request = record['pullRequest']
    if record['event'] == 'pull_request':
        if (not isinstance(request, dict)
                or set(request) != {'number', 'headSHA', 'baseSHA', 'headRepositoryID', 'baseRepositoryID'}
                or not positive(request['number']) or not sha(request['baseSHA'])
                or request['headSHA'] != source_sha
                or not positive(request['headRepositoryID']) or not positive(request['baseRepositoryID'])
                or request['headRepositoryID'] != metadata['repositoryID']
                or request['baseRepositoryID'] != metadata['repositoryID']):
            raise ValueError('Build record does not identify a same-repository source pull request')
        if built_sha != source_sha and parents != [request['baseSHA'], source_sha]:
            raise ValueError('Artifact checkout is not the requested source or its recorded ordered PR merge')
    elif request is not None or built_sha != source_sha:
        raise ValueError('Non-PR artifact checkout must be the exact authenticated source')

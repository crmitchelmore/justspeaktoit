#!/usr/bin/env python3
"""Copy installed sample manual candidates; never execute the tool or infer safety."""

from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import PurePosixPath
import re
import stat
import sys
import zlib


MANUAL_ROOTS = (
    '/usr/share/man/man1',
    '/Library/Developer/CommandLineTools/usr/share/man/man1',
    '/Applications/Xcode.app/Contents/Developer/usr/share/man/man1',
    # This fixed Xcode bundle is named in the retained Debug runner log.
    '/Applications/Xcode_26.6.app/Contents/Developer/usr/share/man/man1',
)
MANUAL_PATHS = tuple(f'{root}/sample.1{suffix}'
                     for root in MANUAL_ROOTS for suffix in ('', '.gz'))
TOOL_PATH = '/usr/bin/sample'
MAX_MANUAL_BYTES = 256 * 1024
MAX_EXPANDED_BYTES = 1024 * 1024
MAX_TOOL_BYTES = 64 * 1024 * 1024


class RejectedEvidence(Exception):
    pass


def reason(error):
    if isinstance(error, RejectedEvidence):
        return str(error)
    return f'io_errno_{error.errno}'


@contextmanager
def directory_fd(path):
    path = PurePosixPath(path)
    if not path.is_absolute() or '..' in path.parts:
        raise RejectedEvidence('unsafe_directory')
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for part in path.parts[1:]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                            dir_fd=fd)
            os.close(fd)
            fd = child
        yield fd
    finally:
        os.close(fd)


def identity(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def read_fixed(path, limit, retain=True):
    if path not in (*MANUAL_PATHS, TOOL_PATH):
        raise RejectedEvidence('path_not_allowlisted')
    target = PurePosixPath(path)
    with directory_fd(str(target.parent)) as parent:
        fd = os.open(target.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                     dir_fd=parent)
        with os.fdopen(fd, 'rb') as stream:
            before = os.fstat(stream.fileno())
            if not stat.S_ISREG(before.st_mode):
                raise RejectedEvidence('not_regular')
            if before.st_size <= 0:
                raise RejectedEvidence('empty')
            if before.st_size > limit:
                raise RejectedEvidence('oversized')
            digest = hashlib.sha256()
            chunks = []
            count = 0
            while True:
                data = stream.read(min(65536, limit - count + 1))
                if not data:
                    break
                count += len(data)
                if count > limit:
                    raise RejectedEvidence('grew_beyond_limit')
                digest.update(data)
                if retain:
                    chunks.append(data)
            after = os.fstat(stream.fileno())
            named = os.stat(target.name, dir_fd=parent, follow_symlinks=False)
            if identity(before) != identity(after) or identity(after) != identity(named):
                raise RejectedEvidence('changed_during_read')
            if count != before.st_size:
                raise RejectedEvidence('short_read')
    return b''.join(chunks), {'bytes': count, 'sha256': digest.hexdigest()}


def check_gzip(data):
    decoder = zlib.decompressobj(16 + zlib.MAX_WBITS)
    try:
        expanded = decoder.decompress(data, MAX_EXPANDED_BYTES + 1)
    except zlib.error as error:
        raise RejectedEvidence('invalid_gzip') from error
    if len(expanded) > MAX_EXPANDED_BYTES or decoder.unconsumed_tail:
        raise RejectedEvidence('gzip_expansion_limit')
    if not decoder.eof or decoder.unused_data:
        raise RejectedEvidence('gzip_truncated_or_trailing')
    if not expanded:
        raise RejectedEvidence('gzip_empty_manual')


def write_at(parent, name, data):
    temporary = '.' + name + '.tmp'
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                 0o600, dir_fd=parent)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(data)
    os.link(temporary, name, src_dir_fd=parent, dst_dir_fd=parent, follow_symlinks=False)
    os.unlink(temporary, dir_fd=parent)


def collect(output):
    inventory = {
        'kind': 'installed-sample-contract-evidence',
        'contract_established': False,
        'sampling_performed': False,
        'manuals': [],
    }
    for index, path in enumerate(MANUAL_PATHS):
        entry = {'path': path}
        try:
            data, metadata = read_fixed(path, MAX_MANUAL_BYTES)
            if path.endswith('.gz'):
                check_gzip(data)
            name = f'manual-{index:02d}-sample.1' + ('.gz' if path.endswith('.gz') else '')
            write_at(output, name, data)
            entry.update(status='collected', artifact=name, **metadata)
        except (OSError, RejectedEvidence) as error:
            entry.update(status='unavailable', reason=reason(error))
            print(f'sample contract manual {index}: unavailable ({reason(error)})',
                  file=sys.stderr)
        inventory['manuals'].append(entry)
    tool = {'path': TOOL_PATH}
    try:
        _, metadata = read_fixed(TOOL_PATH, MAX_TOOL_BYTES, retain=False)
        tool.update(status='hashed_without_execution', **metadata)
    except (OSError, RejectedEvidence) as error:
        tool.update(status='unavailable', reason=reason(error))
        print(f'sample tool identity unavailable ({reason(error)})', file=sys.stderr)
    inventory['tool'] = tool
    inventory['status'] = ('evidence_collected_for_review'
                           if any(item['status'] == 'collected' for item in inventory['manuals'])
                           else 'unavailable')
    if inventory['status'] == 'unavailable':
        print('Installed sample manual unavailable; contract NOT established.', file=sys.stderr)
    return inventory


def main():
    if sys.platform != 'darwin' or os.environ.get('GITHUB_ACTIONS') != 'true':
        print('Installed sample contract collection requires macOS CI.', file=sys.stderr)
        return 1
    run = os.environ.get('GITHUB_RUN_ID', '')
    attempt = os.environ.get('GITHUB_RUN_ATTEMPT', '')
    head = os.environ.get('GITHUB_SHA', '')
    if not re.fullmatch(r'[0-9]{1,24}', run) or not re.fullmatch(r'[0-9]{1,8}', attempt):
        print('Installed sample contract collection: invalid run identity.', file=sys.stderr)
        return 1
    try:
        with directory_fd(os.environ.get('RUNNER_TEMP', '')) as parent:
            name = f'jsti-installed-sample-contract-{run}-{attempt}'
            os.mkdir(name, 0o700, dir_fd=parent)
            fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
            try:
                inventory = collect(fd)
                inventory['context'] = {
                    'run_id': run,
                    'run_attempt': attempt,
                    'head': head if re.fullmatch(r'[0-9a-fA-F]{40}', head) else 'unavailable',
                }
                write_at(fd, 'inventory.json',
                         (json.dumps(inventory, indent=2, sort_keys=True) + '\n').encode('ascii'))
            finally:
                os.close(fd)
    except (OSError, RejectedEvidence) as error:
        print(f'Installed sample contract output unavailable ({reason(error)})', file=sys.stderr)
        return 1
    return 0 if inventory['status'] == 'evidence_collected_for_review' else 3


if __name__ == '__main__':
    sys.exit(main())

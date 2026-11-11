#!/usr/bin/env python3
"""Collect existing, workspace-bound macOS XCTest reports; never run a test."""

import argparse
from contextlib import contextmanager
import errno
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import time

MAX_REPORTS = 4
MAX_REPORT_BYTES = 4 * 1024 * 1024
MAX_TOTAL_BYTES = 16 * 1024 * 1024
MAX_READ_BYTES = 16 * 1024 * 1024
MAX_ENTRIES = 2048
MAX_CANDIDATES = 32
REPORT_NAME = re.compile(r'(?:xctest|SpeakAppPackageTests)(?:[-_].*)?\.(?:ips|crash)',
                         re.IGNORECASE | re.ASCII)


class RejectedReport(Exception):
    pass


def error_reason(error):
    if error.errno == errno.ENOENT:
        return 'missing'
    if error.errno in (errno.ELOOP, errno.ENOTDIR):
        return 'symlink_or_not_directory'
    return f'{type(error).__name__}:errno={error.errno}'


@contextmanager
def directory_fd(path, create=False):
    """Open each absolute component without following a directory symlink."""
    path = Path(path)
    if not path.is_absolute() or '..' in path.parts:
        raise ValueError('directory_out_of_scope')
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    fd = os.open(path.anchor, flags)
    try:
        for index, part in enumerate(path.parts[1:], 1):
            if create and index == len(path.parts) - 1:
                os.mkdir(part, 0o700, dir_fd=fd)
            child = os.open(part, flags, dir_fd=fd)
            os.close(fd)
            fd = child
        yield fd
    finally:
        os.close(fd)


def write_at(fd, name, data):
    # A failed copy remains hidden, never a published partial crash report.
    temporary = '.' + name + '.tmp'
    target = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                     0o600, dir_fd=fd)
    with os.fdopen(target, 'wb') as stream:
        stream.write(data)
    os.link(temporary, name, src_dir_fd=fd, dst_dir_fd=fd, follow_symlinks=False)
    os.unlink(temporary, dir_fd=fd)


def json_bytes(value):
    return (json.dumps(value, indent=2, sort_keys=True) + '\n').encode('utf-8')


def identity(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def birth_ns(info):
    return getattr(info, 'st_birthtime_ns', int(getattr(info, 'st_birthtime', 0) * 1_000_000_000))


def read_report(fd, name, boundary_ns, now_ns, budget):
    before = os.stat(name, dir_fd=fd, follow_symlinks=False)
    if stat.S_ISLNK(before.st_mode):
        raise RejectedReport('symlink')
    if not stat.S_ISREG(before.st_mode):
        raise RejectedReport('not_regular')
    if before.st_size > MAX_REPORT_BYTES:
        raise RejectedReport('oversize')
    if before.st_size == 0:
        raise RejectedReport('empty_report')
    stamp = max(before.st_mtime_ns, birth_ns(before))
    if stamp <= boundary_ns:
        raise RejectedReport('stale')
    if stamp > now_ns:
        raise RejectedReport('future_timestamp')
    if budget['reserved'] + before.st_size > MAX_READ_BYTES:
        raise RejectedReport('read_byte_limit')
    source = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
    with os.fdopen(source, 'rb') as stream:
        opened = os.fstat(stream.fileno())
        if not stat.S_ISREG(opened.st_mode) or identity(opened) != identity(before):
            raise RejectedReport('changed_before_read')
        # Reserve the entire read even if an I/O error interrupts it.
        budget['reserved'] += before.st_size
        data = stream.read(before.st_size)
        after = os.fstat(stream.fileno())
    if len(data) != before.st_size or identity(after) != identity(before):
        raise RejectedReport('changed_during_read')
    return data, {'mtime_ns': before.st_mtime_ns, 'birthtime_ns': birth_ns(before)}


def matches_bundle(data, suffix, workspace):
    pattern = (re.escape(workspace + '/.build/')
               + r'(?:[A-Za-z0-9_][A-Za-z0-9_.-]*/)?debug/SpeakAppPackageTests\.xctest'
               + r'(?:/Contents/MacOS/SpeakAppPackageTests)?')
    text = data.decode('utf-8')
    if suffix == '.crash':
        in_images = False
        for line in text.splitlines():
            if line.startswith('Path:') and re.fullmatch(pattern, line[5:].strip()):
                return True
            if line.strip() == 'Binary Images:':
                in_images = True
            elif in_images:
                if not line.strip():
                    in_images = False
                elif re.search(r'(?<!\S)' + pattern + r'$', line.rstrip()):
                    return True
        return False
    # .ips contains a JSON metadata object followed by a separate JSON payload.
    decoder = json.JSONDecoder()
    pending = []
    offset = 0
    while offset < len(text):
        if text[offset].isspace():
            offset += 1
            continue
        value, offset = decoder.raw_decode(text, offset)
        pending.append(value)
    matched = False
    while pending:
        value = pending.pop()
        if isinstance(value, dict):
            for key, item in value.items():
                if key in ('path', 'procPath', 'bundlePath') and isinstance(item, str):
                    matched = matched or re.fullmatch(pattern, item) is not None
                elif isinstance(item, (dict, list)):
                    pending.append(item)
        elif isinstance(value, list):
            pending.extend(value)
    return matched


def collect_reports(context, roots, output, now_ns=None, unavailable=None):
    """The CLI supplies only the two standard roots; tests inject synthetic roots."""
    now_ns = time.time_ns() if now_ns is None else now_ns
    inventory = {
        'schema': 1, 'context': context, 'collection_ns': now_ns,
        'test_outcome': 'not_evaluated_by_collector',
        'limits': {'reports': MAX_REPORTS, 'per_report_bytes': MAX_REPORT_BYTES,
                   'total_bytes': MAX_TOTAL_BYTES, 'read_bytes': MAX_READ_BYTES,
                   'directory_entries': MAX_ENTRIES, 'candidates': MAX_CANDIDATES},
        'scope': 'Nonrecursive standard DiagnosticReports; exact workspace Debug XCTest bundle',
        'directories': [], 'reports': [], 'rejected': [], 'evidence_gaps': [],
        'entries_examined': 0, 'candidates_examined': 0, 'copied_bytes': 0,
    }
    budget = {'reserved': 0}
    if unavailable:
        inventory['evidence_gaps'].append(unavailable)
    elif type(context.get('boundary_ns')) is not int or not 0 < context['boundary_ns'] <= now_ns:
        inventory['evidence_gaps'].append('invalid_or_future_boundary')
    with directory_fd(output, create=True) as destination:
        for label, root in (() if inventory['evidence_gaps'] else roots):
            directory = {'root': label}
            inventory['directories'].append(directory)
            try:
                with directory_fd(root) as source, os.scandir(source) as listing:
                    directory['status'] = 'available'
                    names = []
                    for entry in listing:
                        if inventory['entries_examined'] >= MAX_ENTRIES:
                            directory['status'] = 'entry_limit'
                            break
                        inventory['entries_examined'] += 1
                        if not REPORT_NAME.fullmatch(entry.name):
                            continue
                        if inventory['candidates_examined'] >= MAX_CANDIDATES:
                            directory['status'] = 'candidate_limit'
                            break
                        inventory['candidates_examined'] += 1
                        names.append(entry.name)
                    for name in sorted(names, reverse=True):
                        observation = {'root': label, 'name': name}
                        stage = 'read'
                        try:
                            if len(inventory['reports']) >= MAX_REPORTS:
                                raise RejectedReport('report_limit')
                            data, times = read_report(source, name, context['boundary_ns'], now_ns, budget)
                            suffix = Path(name).suffix.lower()
                            stage = 'decode'
                            try:
                                matched = matches_bundle(data, suffix, context['workspace'])
                            except (ValueError, RecursionError) as error:
                                raise RejectedReport('malformed_report') from error
                            if not matched:
                                raise RejectedReport('bundle_mismatch')
                            if inventory['copied_bytes'] + len(data) > MAX_TOTAL_BYTES:
                                raise RejectedReport('output_byte_limit')
                            stage = 'copy'
                            filename = f'report-{len(inventory["reports"]) + 1:02d}{suffix}'
                            write_at(destination, filename, data)
                            inventory['reports'].append({
                                **observation, **times, 'file': filename, 'bytes': len(data),
                                'sha256': hashlib.sha256(data).hexdigest(),
                            })
                            inventory['copied_bytes'] += len(data)
                        except RejectedReport as error:
                            inventory['rejected'].append({**observation, 'reason': str(error)})
                        except OSError as error:
                            inventory['rejected'].append({
                                **observation, 'reason': stage + '_error:' + error_reason(error),
                            })
            except OSError as error:
                directory['status'] = error_reason(error)
            if directory['status'] != 'available':
                inventory['evidence_gaps'].append(label + ':' + directory['status'])
        inventory['read_bytes_reserved'] = budget['reserved']
        if not inventory['reports']:
            inventory['evidence_gaps'].append('no_matching_reports')
        limited = any(item['reason'].endswith('_limit') for item in inventory['rejected'])
        if limited:
            inventory['evidence_gaps'].append('report_or_byte_limit')
        errors = any('_error:' in item['reason'] for item in inventory['rejected'])
        if errors:
            inventory['evidence_gaps'].append('report_io_error')
        unavailable_reports = {'oversize', 'empty_report', 'future_timestamp',
                               'changed_before_read', 'changed_during_read', 'malformed_report'}
        if any(item['reason'] in unavailable_reports for item in inventory['rejected']):
            inventory['evidence_gaps'].append('candidate_reports_unavailable')
        inventory['status'] = ('evidence_gap' if not inventory['reports'] else
                               'partial' if inventory['evidence_gaps'] else 'reports_collected')
        write_at(destination, 'inventory.json', json_bytes(inventory))
    return inventory


def run_context(env):
    patterns = {
        'GITHUB_SHA': r'[0-9a-fA-F]{40}',
        'GITHUB_REPOSITORY': r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+',
        'GITHUB_RUN_ID': r'[0-9]{1,20}', 'GITHUB_RUN_ATTEMPT': r'[0-9]{1,10}',
        'GITHUB_JOB': r'[A-Za-z_][A-Za-z0-9_-]{0,99}',
    }
    fields = {}
    for key, pattern in patterns.items():
        if not re.fullmatch(pattern, env.get(key, '')):
            raise ValueError('invalid run context field ' + key)
        fields[key] = env[key]
    workspace, temporary = Path(env['GITHUB_WORKSPACE']), Path(env['RUNNER_TEMP'])
    if not workspace.is_absolute() or not temporary.is_absolute():
        raise ValueError('workspace_or_runner_temp_not_absolute')
    workspace, temporary = workspace.resolve(strict=True), temporary.resolve(strict=True)
    if not workspace.is_dir() or not temporary.is_dir():
        raise ValueError('workspace_or_runner_temp_not_directory')
    context = {'schema': 1, 'workspace': workspace.as_posix(), **fields}
    stem = 'jsti-xctest-debug-' + fields['GITHUB_RUN_ID'] + '-' + fields['GITHUB_RUN_ATTEMPT']
    return context, temporary, stem


def load_boundary(temporary, name, expected):
    with directory_fd(temporary) as directory:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        with os.fdopen(fd, 'rb') as stream:
            before = os.fstat(stream.fileno())
            if not stat.S_ISREG(before.st_mode) or not 0 < before.st_size <= 16384:
                raise ValueError('invalid_boundary_file')
            raw = stream.read(before.st_size)
            if len(raw) != before.st_size or identity(os.fstat(stream.fileno())) != identity(before):
                raise ValueError('boundary_changed_during_read')
    context = json.loads(raw)
    if not isinstance(context, dict) or set(context) != set(expected) | {'boundary_ns'}:
        raise ValueError('invalid_boundary_schema')
    if any(context[key] != value for key, value in expected.items()):
        raise ValueError('boundary_run_context_mismatch')
    return context


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('boundary', 'collect'))
    args = parser.parse_args()
    try:
        context, temporary, stem = run_context(os.environ)
    except (OSError, ValueError, KeyError) as error:
        reason = (error_reason(error) if isinstance(error, OSError) else
                  'missing_' + str(error.args[0]) if isinstance(error, KeyError) else str(error))
        print('XCTest diagnostics: run_context_unavailable:' + reason, file=sys.stderr)
        return 1
    boundary_name = stem + '-context.json'
    if args.operation == 'boundary':
        context['boundary_ns'] = time.time_ns()
        try:
            with directory_fd(temporary) as directory:
                write_at(directory, boundary_name, json_bytes(context))
        except OSError as error:
            print('XCTest diagnostics: boundary_write_error:' + error_reason(error), file=sys.stderr)
            return 1
        print('XCTest diagnostics: pre-test boundary recorded; no reports inspected')
        return 0
    unavailable = None
    if os.environ.get('JSTI_XCTEST_BOUNDARY_OUTCOME') != 'success':
        unavailable = 'boundary_step_not_successful'
    else:
        try:
            context = load_boundary(temporary, boundary_name, context)
        except (OSError, ValueError, UnicodeDecodeError, RecursionError) as error:
            reason = (error_reason(error) if isinstance(error, OSError) else
                      type(error).__name__ if isinstance(
                          error, (json.JSONDecodeError, UnicodeDecodeError, RecursionError)) else str(error))
            unavailable = 'boundary_unavailable:' + reason
    roots = [] if unavailable else [
        ('user', Path.home() / 'Library' / 'Logs' / 'DiagnosticReports'),
        ('system', Path('/Library/Logs/DiagnosticReports')),
    ]
    try:
        inventory = collect_reports(context, roots, temporary / stem, unavailable=unavailable)
    except OSError as error:
        print('XCTest diagnostics: collection_output_error:' + error_reason(error), file=sys.stderr)
        return 1
    print('XCTest diagnostics: ' + inventory['status']
          + '; reports=' + str(len(inventory['reports'])) + '; see inventory.json', file=sys.stderr)
    # 3 certifies a fresh inventory, not available/complete crash evidence.
    # 1 is a fatal collection/output error: the workflow must not upload that path.
    return 0 if inventory['status'] == 'reports_collected' else 3


if __name__ == '__main__':
    sys.exit(main())

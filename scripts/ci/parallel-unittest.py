#!/usr/bin/env python3
"""`python3 -m unittest discover` spread across processes.

The tooling tests spend most of their time waiting on the subprocesses they
spawn, so one interpreter leaves the machine idle: scripts/tests takes about
three minutes serially and well under one this way. Each worker imports the
test modules once and runs batches of test ids; a class is split into
batches so one slow class doesn't set the wall time on its own.

    parallel-unittest.py -s DIR [-p PATTERN] [-v] [-j JOBS]

JSTI_TEST_JOBS=1 (or -j 1) runs plain serial discovery instead.
"""
from __future__ import annotations

import argparse
import io
import os
import sys
import time
import unittest
from collections import defaultdict
from concurrent.futures import ProcessPoolExecutor, as_completed

BATCH = 3  # tests per batch: small enough to balance, large enough to amortise setUpClass


def flatten(suite):
    for test in suite:
        if isinstance(test, unittest.TestSuite):
            yield from flatten(test)
        else:
            yield test


def init_worker(start: str) -> None:
    # Same import root as `unittest discover -s START` without -t.
    sys.path.insert(0, start)


def run_batch(ids: list[str], verbosity: int):
    stream = io.StringIO()
    started = time.monotonic()
    suite = unittest.defaultTestLoader.loadTestsFromNames(ids)
    # A bare result rather than TextTestRunner: per-test lines and failure details, no per-batch summary.
    result = unittest.TextTestResult(unittest.runner._WritelnDecorator(stream), True, verbosity)
    suite(result)
    result.printErrors()
    return (result.testsRun, len(result.failures) + len(result.errors) + len(result.unexpectedSuccesses),
            len(result.skipped), stream.getvalue(), time.monotonic() - started)


def batches(tests: list[unittest.TestCase]) -> list[list[str]]:
    by_class: dict[str, list[str]] = defaultdict(list)
    for test in tests:
        by_class[f'{type(test).__module__}.{type(test).__qualname__}'].append(test.id())
    chunks = [ids[i:i + BATCH] for ids in by_class.values() for i in range(0, len(ids), BATCH)]
    return sorted(chunks, key=len, reverse=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('-s', '--start', required=True)
    parser.add_argument('-p', '--pattern', default='test*.py')
    parser.add_argument('-v', '--verbose', action='store_const', const=2, default=1, dest='verbosity')
    parser.add_argument('-j', '--jobs', type=int, default=int(os.environ.get('JSTI_TEST_JOBS', '0')) or os.cpu_count())
    args = parser.parse_args()
    start = os.path.abspath(args.start)

    loader = unittest.TestLoader()
    tests = list(flatten(loader.discover(start, pattern=args.pattern)))
    if args.jobs <= 1:
        result = unittest.TextTestRunner(verbosity=args.verbosity).run(unittest.TestSuite(tests))
        return 0 if result.wasSuccessful() and result.testsRun else 1
    # Import failures can't be reloaded by name in a worker: run them here so they are reported.
    broken = [t for t in tests if type(t).__module__ == 'unittest.loader']
    runnable = [t for t in tests if type(t).__module__ != 'unittest.loader']

    started = time.monotonic()
    ran = failed = skipped = 0
    if broken:
        result = unittest.TextTestRunner(verbosity=args.verbosity).run(unittest.TestSuite(broken))
        ran, failed = result.testsRun, len(result.failures) + len(result.errors)
    with ProcessPoolExecutor(max_workers=args.jobs, initializer=init_worker, initargs=(start,)) as pool:
        futures = [pool.submit(run_batch, ids, args.verbosity) for ids in batches(runnable)]
        for future in as_completed(futures):
            count, failures, skips, output, _ = future.result()
            ran, failed, skipped = ran + count, failed + failures, skipped + skips
            if args.verbosity > 1 or failures:
                sys.stderr.write(output)
                sys.stderr.flush()
    elapsed = time.monotonic() - started
    sys.stderr.write(f'\n{"-" * 70}\nRan {ran} tests in {elapsed:.3f}s across {args.jobs} processes\n\n')
    if failed or not ran:
        sys.stderr.write(f'FAILED (failures+errors={failed}{", no tests ran" if not ran else ""})\n')
        return 1
    sys.stderr.write(f'OK{f" (skipped={skipped})" if skipped else ""}\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())

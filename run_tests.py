#!/usr/bin/env python3
"""Entry point for the DLS test suite.

The suite is plain ``unittest`` (no third-party dependencies) and drives the
real ``dls`` binary over stdio, so it exercises the same code path an editor
would.  One server process is shared per test module to keep the run fast.

Examples::

    python3 run_tests.py                 # run everything
    python3 run_tests.py -k completion   # only tests matching "completion"
    python3 run_tests.py --list          # list test ids, run nothing
    python3 run_tests.py --server bin/dls -v
    python3 run_tests.py --build         # 'make dls' first
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import time
import unittest

REPO_ROOT = os.path.dirname(os.path.abspath(__file__))
TESTS_DIR = os.path.join(REPO_ROOT, "tests")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run the DLS test suite")
    parser.add_argument(
        "--server",
        metavar="PATH",
        help="path to the dls binary (default: $DLS_SERVER or bin/dls)",
    )
    parser.add_argument(
        "--build",
        action="store_true",
        help="run 'make dls' before testing",
    )
    parser.add_argument(
        "-k",
        dest="pattern",
        metavar="PATTERN",
        help="only run tests whose id contains PATTERN",
    )
    parser.add_argument(
        "--list",
        dest="list_tests",
        action="store_true",
        help="list the tests that would run and exit",
    )
    parser.add_argument("-v", "--verbose", action="store_true", help="verbose output")
    parser.add_argument(
        "--failfast", action="store_true", help="stop at the first failure"
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=float(os.environ.get("DLS_TEST_TIMEOUT", "60")),
        help="per-request timeout in seconds (default: 60)",
    )
    parser.add_argument(
        "--module",
        action="append",
        metavar="NAME",
        help="only run the given test module (may be repeated, e.g. --module completion)",
    )
    return parser.parse_args(argv)


def iter_tests(suite: unittest.TestSuite):
    """Yield every TestCase inside a (possibly nested) suite."""
    for item in suite:
        if isinstance(item, unittest.TestSuite):
            yield from iter_tests(item)
        else:
            yield item


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)

    os.environ["DLS_TEST_TIMEOUT"] = str(args.timeout)
    if args.server:
        server = os.path.abspath(args.server)
        if not os.path.isfile(server):
            print(f"error: --server points at a missing file: {server}", file=sys.stderr)
            return 2
        os.environ["DLS_SERVER"] = server

    if args.build:
        print("$ make dls")
        result = subprocess.run(["make", "dls"], cwd=REPO_ROOT)
        if result.returncode != 0:
            print("error: 'make dls' failed", file=sys.stderr)
            return result.returncode

    # Imported after DLS_SERVER is set so ``find_server`` picks it up.
    sys.path.insert(0, TESTS_DIR)
    import harness  # noqa: E402  (import order is intentional)

    try:
        server_path = harness.find_server()
    except harness.ServerNotFound as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    loader = unittest.TestLoader()
    if args.pattern and hasattr(loader, "testNamePatterns"):
        loader.testNamePatterns = [f"*{args.pattern}*"]

    suite = loader.discover(TESTS_DIR, pattern="test_*.py", top_level_dir=TESTS_DIR)

    if args.module:
        wanted = {name if name.startswith("test_") else f"test_{name}" for name in args.module}
        filtered = unittest.TestSuite()
        for test in iter_tests(suite):
            module_name = type(test).__module__.split(".")[-1]
            if module_name in wanted:
                filtered.addTest(test)
        suite = filtered

    tests = list(iter_tests(suite))
    if args.list_tests:
        for test in tests:
            print(test.id())
        print(f"\n{len(tests)} test(s)")
        return 0

    if not tests:
        print("error: no tests collected", file=sys.stderr)
        return 2

    print(f"dls binary : {server_path}")
    print(f"tests      : {len(tests)} in {TESTS_DIR}")
    print(f"python     : {sys.version.split()[0]}")
    print()

    runner = unittest.TextTestRunner(verbosity=2 if args.verbose else 1, failfast=args.failfast)
    started = time.monotonic()
    result = runner.run(suite)
    elapsed = time.monotonic() - started

    print()
    print(f"ran {result.testsRun} test(s) in {elapsed:.2f}s")
    if result.skipped:
        print(f"skipped: {len(result.skipped)}")
    if result.expectedFailures:
        print(f"expected failures (known gaps): {len(result.expectedFailures)}")
        for test, _ in result.expectedFailures:
            print(f"  - {test.id()}")
    if result.unexpectedSuccesses:
        print(f"unexpected successes (a known gap looks fixed): {len(result.unexpectedSuccesses)}")
        for test in result.unexpectedSuccesses:
            print(f"  - {test.id()}")
    if result.failures:
        print(f"failures: {len(result.failures)}")
    if result.errors:
        print(f"errors: {len(result.errors)}")

    ok = result.wasSuccessful()
    print("OK" if ok else "FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())

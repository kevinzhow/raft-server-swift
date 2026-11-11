#!/usr/bin/env python3
"""Run the full Swift test suite as parallel test-runner shards.

Why not ``swift test --filter`` in parallel: SwiftPM serializes concurrent
invocations on the package's ``.build`` lock ("Another instance of SwiftPM is
already running"), so the parallel compute is wasted. This script builds once
with SwiftPM, then invokes the already-linked ``<Target>-test-runner`` binaries
directly. Every shard is a separate process with its own ``TMPDIR``; the
process-wide shared transaction domain stays serialized inside each shard
because each runner runs with ``--no-parallel``.

Tests are balanced by count across shards and selected with the same test IDs
``swift test list`` reports. Each runner also writes a Swift Testing event
stream, which gives the exact failing test IDs. A failing test is retried once
in an isolated process (fresh ``TMPDIR``), and the retry is reported explicitly;
this covers the known load-sensitive
``OarListModelsTests/aListingStillRunningAtOurDeadlineReportsDetectTimeout``
flake without hiding a real failure.

Usage:
    scripts/test-sharded.py [--shards N] [--logs DIR] [--no-build] [--jobs N]

Exit status is non-zero when any test fails after its isolated retry. Logs and
the machine-readable summary are written under the log directory (default
``.build/test-sharded/<UTC stamp>``).
"""

from __future__ import annotations

import argparse
import concurrent.futures
import datetime
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SWIFT = "/mnt/data/opt/swift-6.4.1-RELEASE-ubuntu26.04/usr/bin/swift"
FAIL_SYMBOLS = {"fail", "failure", "error"}


def utc_stamp() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def run(command: list[str], log: Path, env: dict[str, str] | None = None) -> int:
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("ab") as handle:
        handle.write(("\n$ " + " ".join(command) + "\n").encode())
        handle.flush()
        return subprocess.call(command, cwd=REPO_ROOT, stdout=handle, stderr=subprocess.STDOUT, env=env)


def tail(path: Path, lines: int = 30) -> str:
    try:
        content = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return ""
    return "\n".join(content[-lines:])


def discover_tests(swift: str, log: Path) -> list[str]:
    with log.open("wb") as handle:
        result = subprocess.run(
            [swift, "test", "list", "--skip-build"],
            cwd=REPO_ROOT,
            stdout=handle,
            stderr=subprocess.STDOUT,
            env=test_env(REPO_ROOT / ".build/test-sharded/tmp-list"),
        )
    if result.returncode != 0:
        raise SystemExit(f"swift test list failed; see {log}\n{tail(log)}")
    entries: list[str] = []
    for line in log.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line or line.startswith("$ ") or " " in line:
            continue
        if re.match(r"^[A-Za-z0-9_]+\.[A-Za-z0-9_]", line):
            entries.append(line)
    if not entries:
        raise SystemExit(f"no tests listed; see {log}")
    return entries


def target_of(test: str) -> str:
    return test.split(".", 1)[0]


def test_env(tmpdir: Path) -> dict[str, str]:
    env = dict(os.environ)
    tmpdir.mkdir(parents=True, exist_ok=True)
    env["TMPDIR"] = str(tmpdir)
    # XDG_CACHE_HOME is inherited when the caller set it (shared SwiftPM cache);
    # otherwise SwiftPM uses its platform default.
    return env


def shard_tests(tests: list[str], count: int) -> list[list[str]]:
    """Greedy longest-processing-time split, balanced by test count.

    Tests are placed largest-group-first so a suite's tests do not all land in
    one shard; the group key is the suite path without the test function.
    """
    groups: dict[str, list[str]] = {}
    for test in tests:
        path = test.split("/", 1)[0]
        groups.setdefault(path, []).append(test)
    shards: list[list[str]] = [[] for _ in range(count)]
    loads = [0] * count
    for group in sorted(groups.values(), key=len, reverse=True):
        index = loads.index(min(loads))
        shards[index].extend(group)
        loads[index] += len(group)
    return shards


def filter_for(tests: list[str]) -> str:
    return "^(?:" + "|".join(re.escape(test) for test in sorted(tests)) + ")(?:/|$)"


def runner_dir(swift: str) -> Path:
    result = subprocess.run([swift, "build", "--show-bin-path"], cwd=REPO_ROOT, capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"swift build --show-bin-path failed: {result.stderr.strip()}")
    return Path(result.stdout.strip())


def parse_events(path: Path) -> tuple[dict[str, str], dict[str, list[str]], bool]:
    """Return (test id -> kind, failures id -> messages, run_failed).

    Suite records also appear in the event stream and report a failure when one
    of their tests fails; only function records are retried individually.
    """
    kinds: dict[str, str] = {}
    failures: dict[str, list[str]] = {}
    run_failed = False
    if not path.is_file():
        return kinds, failures, run_failed
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            record = json.loads(raw)
        except json.JSONDecodeError:
            continue
        if record.get("kind") == "test":
            payload = record.get("payload", {})
            test_id = payload.get("id")
            if test_id:
                kinds[test_id] = str(payload.get("kind", "function"))
            continue
        if record.get("kind") != "event":
            continue
        payload = record.get("payload", {})
        kind = payload.get("kind")
        test_id = payload.get("testID")
        messages = payload.get("messages") or []
        if kind == "issueRecorded" and test_id:
            issue = payload.get("issue") or {}
            severity = str(issue.get("severity", "error")).lower()
            if severity not in ("warning", "info"):
                failures.setdefault(test_id, []).append(str(issue.get("comment") or issue.get("details") or "issue"))
        if kind == "testEnded" and test_id:
            for message in messages:
                if str(message.get("symbol", "")).lower() in FAIL_SYMBOLS:
                    failures.setdefault(test_id, []).append(str(message.get("text", "failed")))
        if kind == "runEnded":
            for message in messages:
                if str(message.get("symbol", "")).lower() in FAIL_SYMBOLS:
                    run_failed = True
    return kinds, failures, run_failed


def parse_text_failures(log: Path) -> list[str]:
    """Fallback for a crashed runner with no event stream."""
    names: list[str] = []
    for line in log.read_text(encoding="utf-8", errors="replace").splitlines():
        match = re.match(r"\s*✘ Test \"?(.+?)\"? (?:recorded an issue|failed)", line)
        if match:
            names.append(match.group(1))
    return names


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--shards", type=int, default=int(os.environ.get("SHARDS", "6")))
    parser.add_argument("--logs", default=str(REPO_ROOT / ".build/test-sharded" / utc_stamp()))
    parser.add_argument("--swift", default=os.environ.get("SWIFT", DEFAULT_SWIFT))
    parser.add_argument("--no-build", action="store_true", help="reuse the existing build")
    parser.add_argument("--jobs", type=int, default=0, help="max concurrent shard processes (default: shards)")
    parser.add_argument("--no-retry", action="store_true", help="disable the isolated retry")
    args = parser.parse_args(argv)
    if args.shards < 1:
        parser.error("--shards must be >= 1")
    if not Path(args.swift).is_file():
        raise SystemExit(f"swift toolchain not found: {args.swift}")

    logs = Path(args.logs)
    logs.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    summary: dict = {
        "startedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "shards": args.shards,
        "logs": str(logs),
        "buildSeconds": 0,
        "testSeconds": 0,
        "tests": 0,
        "retries": [],
        "failures": [],
    }

    if not args.no_build:
        print(f"== building tests (log: {logs / 'build.log'})", flush=True)
        build_started = time.monotonic()
        rc = run([args.swift, "build", "--build-tests"], logs / "build.log", test_env(logs / "tmp-build"))
        summary["buildSeconds"] = round(time.monotonic() - build_started, 1)
        if rc != 0:
            print(tail(logs / "build.log"), file=sys.stderr)
            print(f"test-sharded: BUILD FAILED ({summary['buildSeconds']}s)", file=sys.stderr)
            (logs / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
            return 1
        print(f"   build ok in {summary['buildSeconds']}s", flush=True)

    tests = discover_tests(args.swift, logs / "list.log")
    summary["tests"] = len(tests)
    shards = shard_tests(tests, args.shards)
    bin_dir = runner_dir(args.swift)
    runners = {target_of(test): bin_dir / f"{target_of(test)}-test-runner" for test in tests}
    missing = sorted(name for name, path in runners.items() if not path.is_file())
    if missing:
        raise SystemExit(f"missing test runner binaries in {bin_dir}: {', '.join(missing)}")

    print(f"== {len(tests)} tests across {args.shards} shards", flush=True)
    for index, shard in enumerate(shards):
        print(f"   shard{index}: {len(shard)} tests", flush=True)

    test_started = time.monotonic()

    def run_shard(index: int, shard: list[str]) -> dict:
        shard_dir = logs / f"shard{index}"
        shard_dir.mkdir(parents=True, exist_ok=True)
        env = test_env(shard_dir / "tmp")
        results = {"index": index, "tests": len(shard), "failed": [], "crashed": False, "events": []}
        by_target: dict[str, list[str]] = {}
        for test in shard:
            by_target.setdefault(target_of(test), []).append(test)
        for target, target_tests in sorted(by_target.items()):
            runner = runners[target]
            events = shard_dir / f"{target}.events.json"
            log = shard_dir / f"{target}.log"
            command = [
                str(runner),
                "--testing-library",
                "swift-testing",
                "--no-parallel",
                "--filter",
                filter_for(target_tests),
                "--event-stream-output-path",
                str(events),
            ]
            rc = run(command, log, env)
            kinds, failures, run_failed = parse_events(events)
            results["events"].append({"target": target, "events": str(events), "log": str(log), "rc": rc})
            actionable = {
                test_id: messages
                for test_id, messages in failures.items()
                if kinds.get(test_id, "function") != "suite"
            }
            results["failed"].extend(
                {"id": test_id, "messages": messages, "target": target} for test_id, messages in actionable.items()
            )
            failures = actionable
            if rc != 0 and not failures:
                # A crash (signal 6/11) or an event-stream gap: keep the text
                # evidence and retry this target group once in isolation.
                results["crashed"] = True
                results["failed"].append(
                    {
                        "id": None,
                        "target": target,
                        "messages": [f"runner exit {rc}"],
                        "names": parse_text_failures(log),
                        "tests": target_tests,
                    }
                )
            if rc == 0 and run_failed and not failures:
                results["failed"].append(
                    {"id": None, "target": target, "messages": ["runEnded reported failure"], "tests": target_tests}
                )
        return results

    jobs = args.jobs or args.shards
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        futures = [pool.submit(run_shard, index, shard) for index, shard in enumerate(shards)]
        shard_results = [future.result() for future in futures]
    summary["testSeconds"] = round(time.monotonic() - test_started, 1)

    failed: list[dict] = []
    for result in shard_results:
        failed.extend(result["failed"])
        if result["crashed"]:
            failed.append({"id": None, "target": "shard", "messages": ["runner crashed"]})
        print(f"   shard{result['index']}: {'FAIL' if result['failed'] else 'pass'} ({result['tests']} tests)", flush=True)

    # One isolated retry per failed test.
    retried: list[dict] = []
    final_failures: list[dict] = []
    if failed and not args.no_retry:
        print(f"== retrying {len(failed)} failed item(s) in isolation", flush=True)
        for item in failed:
            if item.get("id"):
                outcome = retry_test(item, runners, logs)
            else:
                outcome = retry_group(item, runners, logs)
            retried.append(outcome)
            if not outcome["passed"]:
                final_failures.append(item)
    else:
        final_failures = failed

    summary["retries"] = retried
    summary["failures"] = [
        {"id": item.get("id"), "target": item.get("target"), "messages": item.get("messages")} for item in final_failures
    ]
    summary["elapsedSeconds"] = round(time.monotonic() - started, 1)
    summary["elapsedTestSeconds"] = summary["testSeconds"]
    (logs / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")

    if retried:
        for outcome in retried:
            state = "RETRY-PASS (load-sensitive flake)" if outcome["passed"] else "RETRY-FAIL"
            print(f"   {state}: {outcome['id'] or outcome['target']} (log {outcome['log']})", flush=True)

    print()
    if final_failures:
        print(f"test-sharded: FAIL — {len(tests)} tests, {summary['testSeconds']}s", file=sys.stderr)
        for item in final_failures:
            print(f"  {item.get('id') or item.get('target')}: {'; '.join(item.get('messages') or [])}", file=sys.stderr)
        print(f"  logs: {logs}", file=sys.stderr)
        return 1
    print(
        f"test-sharded: PASS — {len(tests)} tests in {args.shards} shards, "
        f"{summary['testSeconds']}s (build {summary['buildSeconds']}s, total {summary['elapsedSeconds']}s)"
    )
    print(f"logs: {logs}")
    return 0


def retry_test(item: dict, runners: dict[str, Path], logs: Path) -> dict:
    test_id = item["id"]
    target = target_of(test_id)
    runner = runners.get(target)
    log = logs / "retry" / (re.sub(r"[^A-Za-z0-9_.-]", "_", test_id)[:120] + ".log")
    log.parent.mkdir(parents=True, exist_ok=True)
    if runner is None or not runner.is_file():
        return {"id": test_id, "target": target, "passed": False, "log": str(log), "reason": "runner missing"}
    env = test_env(logs / "retry" / ("tmp-" + target))
    rc = run([str(runner), "--testing-library", "swift-testing", "--no-parallel", "--filter", "^" + re.escape(test_id) + "$"], log, env)
    return {"id": test_id, "target": target, "passed": rc == 0, "log": str(log)}


def retry_group(item: dict, runners: dict[str, Path], logs: Path) -> dict:
    target = item.get("target")
    runner = runners.get(target)
    log = logs / "retry" / f"group-{target}.log"
    log.parent.mkdir(parents=True, exist_ok=True)
    if runner is None or not runner.is_file():
        return {"id": None, "target": target, "passed": False, "log": str(log), "reason": "runner missing"}
    env = test_env(logs / "retry" / f"tmp-{target}")
    tests = item.get("tests") or []
    command = [str(runner), "--testing-library", "swift-testing", "--no-parallel"]
    if tests:
        command += ["--filter", filter_for(tests)]
    rc = run(command, log, env)
    return {"id": None, "target": target, "passed": rc == 0, "log": str(log)}


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

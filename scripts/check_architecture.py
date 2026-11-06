#!/usr/bin/env python3
"""Architecture guardrails for the raft-server-swift parity port.

The target layering is described in ``docs/ARCHITECTURE.md``. This script
enforces the part of it that can be measured today:

1. ``Sources/RaftHTTP/EmailLogin.swift`` must not grow past its recorded
   baseline (48 lines, the composition root: the locks, the domain stores, the
   OAuth ledger and ``init()``). Every row ledger and injected configuration
   slot lives in a domain store, every accessor lives in
   ``EmailLogin+StoreForwarders.swift``, and the domain services live under
   ``Services/``. Shrinking is always allowed; the baseline constant is a
   ratchet and may only be lowered.
2. Every Swift file under ``Sources/RaftHTTPServer/Features/`` must stay at or
   below 1,200 lines. A missing directory is reported as zero files.
3. Every Swift file under ``Sources/RaftHTTP/EmailLogin/`` must stay at or
   below 1,600 lines, and the directory must not grow past the recorded file
   count. Both numbers ratchet down as extensions migrate to ``Services/``.
   A missing directory is reported as zero files.
4. Every Swift file under ``Sources/RaftHTTP/Services/`` must stay at or below
   1,200 lines, so one migrated domain cannot become the next mega-file. A
   missing directory is reported as zero files.
5. ``ForTesting`` markers in ``EmailLogin.swift`` are warnings, not failures:
   the recorded baseline is 0 markers and 0 ``private func …ForTesting``. The
   file holds no test-only storage; seams live in
   ``EmailLogin+TestSeams.swift`` and new ones belong in the test-only
   ``TestSupport`` target (see R5 in ``docs/ARCHITECTURE.md``).

6. ``ForTesting`` markers anywhere under ``Sources/`` are ratcheted per file
   against ``scripts/for_testing_baseline.tsv`` (one ``path<TAB>count`` line per
   production file; a marker count is the number of lines containing
   ``ForTesting``, the same figure as ``grep -r ForTesting Sources | wc -l``).
   A file whose count exceeds its baseline (a missing file counts as 0) fails;
   a file below its baseline only warns, so the slice that moves seams into the
   ``TestSupport`` target lowers that file's line in the same commit. The
   baseline file is the only thing those slices edit.

Exit codes:
    0  pass, or pass with warnings
    1  guardrail violation
    2  operational error (bad root, missing required file)

Usage:
    scripts/check_architecture.py
    scripts/check_architecture.py --json
    scripts/check_architecture.py --root /path/to/checkout
    scripts/check_architecture.py --print-for-testing-baseline
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

EMAIL_LOGIN_RELATIVE = Path("Sources/RaftHTTP/EmailLogin.swift")
EMAIL_LOGIN_EXTENSIONS_RELATIVE = Path("Sources/RaftHTTP/EmailLogin")
FEATURES_RELATIVE = Path("Sources/RaftHTTPServer/Features")
SERVICES_RELATIVE = Path("Sources/RaftHTTP/Services")
SOURCES_RELATIVE = Path("Sources")
FOR_TESTING_BASELINE_RELATIVE = Path("scripts/for_testing_baseline.tsv")

# Recorded on 2026-11-06 after the AuthProfile/Notifications store split, then
# after the TasksAndReminders/MachinesAndComputers/ServersAndChannels/
# ManagedMCPAndCards/Feedback split, and again after the last domain-state
# dictionaries moved into AuthProfileStore, MessagesAndThreadsStore and
# AgentsRuntimeStore with the accessors in EmailLogin+StoreForwarders.swift,
# and again after the injected relay/configuration slots moved into the domain
# stores and the socket-membership, feedback-locator and action-card services
# moved under Sources/RaftHTTP/Services/.
# The line ceiling is a ratchet: lower it when a slice shrinks the file, never
# raise it to make a check pass.
EMAIL_LOGIN_LINE_BASELINE = 48
EMAIL_LOGIN_FOR_TESTING_BASELINE = 0
EMAIL_LOGIN_PRIVATE_FUNC_FOR_TESTING_BASELINE = 0

# A feature file larger than this must split along upstream route groups.
FEATURE_FILE_LINE_LIMIT = 1_200

# A domain extension file larger than this must split along its domain again.
EMAIL_LOGIN_EXTENSION_LINE_LIMIT = 1_600

# ``Sources/RaftHTTP/EmailLogin/`` holds one file per upstream route family.
# Batch A of the Phase 5 migration deleted AuthCore, AuthIdentitiesProfile and
# OAuthFlows; Batch B deleted FeedbackMultiApp and AttachmentsMobile. Batch C
# deleted MessageSend, ReactionsRealtime, SearchMentions and ThreadsAndInbox;
# Batch D deleted ServerMembersAndTasks1, ServerMembersAndTasks2 and
# ComputersUsage2 (their handlers live in Services/, for Batch D
# ServerMembersAndSidebarService.swift, TasksAndLabsService.swift,
# ServerProfileAndOrderService.swift and AgentSendDeliveryService.swift). The
# count is a ratchet: lower it when a slice deletes a file, never raise it.
EMAIL_LOGIN_EXTENSION_COUNT_BASELINE = 0

# A service file larger than this must split along its domain again, so a
# migrated domain cannot simply become the next mega-file.
SERVICE_FILE_LINE_LIMIT = 1_200

# ``ForTesting`` is almost always a suffix (``mintAccessTokenForTesting``), so a
# word-boundary prefix match would miss nearly every marker.
FOR_TESTING_RE = re.compile(r"ForTesting")
PRIVATE_FUNC_FOR_TESTING_RE = re.compile(r"\bprivate\s+func\s+\w*ForTesting\b")


class GuardrailError(Exception):
    """An input problem that prevents evaluation (exit code 2)."""


def count_lines(path: Path) -> int:
    """Count physical lines the way ``wc -l`` does, including a final unterminated line."""
    data = path.read_bytes()
    if not data:
        return 0
    return data.count(b"\n") + (0 if data.endswith(b"\n") else 1)


def plural(count: int, singular: str, plural_form: str | None = None) -> str:
    return singular if count == 1 else (plural_form or singular + "s")


def check_email_login_ceiling(root: Path) -> dict:
    path = root / EMAIL_LOGIN_RELATIVE
    if not path.is_file():
        raise GuardrailError(f"missing required file: {path}")
    lines = count_lines(path)
    headroom = EMAIL_LOGIN_LINE_BASELINE - lines
    failed = lines > EMAIL_LOGIN_LINE_BASELINE
    if failed:
        message = (
            f"{EMAIL_LOGIN_RELATIVE} grew to {lines:,} lines, "
            f"{lines - EMAIL_LOGIN_LINE_BASELINE:,} over the {EMAIL_LOGIN_LINE_BASELINE:,}-line baseline"
        )
    else:
        message = (
            f"{EMAIL_LOGIN_RELATIVE} is {lines:,} lines "
            f"({headroom:,} {plural(headroom, 'line')} of headroom)"
        )
    return {
        "id": "email-login-ceiling",
        "title": "EmailLogin.swift line ceiling",
        "status": "fail" if failed else "pass",
        "severity": "error",
        "path": str(EMAIL_LOGIN_RELATIVE),
        "lines": lines,
        "baseline": EMAIL_LOGIN_LINE_BASELINE,
        "headroom": headroom,
        "message": message,
    }


def check_feature_file_ceilings(root: Path) -> dict:
    directory = root / FEATURES_RELATIVE
    files: list[dict] = []
    if directory.is_dir():
        for path in sorted(directory.rglob("*.swift")):
            if not path.is_file():
                continue
            lines = count_lines(path)
            files.append(
                {
                    "path": str(path.relative_to(root)),
                    "lines": lines,
                    "status": "fail" if lines > FEATURE_FILE_LINE_LIMIT else "pass",
                }
            )
    violations = [entry for entry in files if entry["status"] == "fail"]
    present = directory.is_dir()
    if not present:
        message = f"{FEATURES_RELATIVE} does not exist yet (0 feature files)"
    elif not files:
        message = f"{FEATURES_RELATIVE} exists but has no .swift files (0 feature files)"
    else:
        largest = max(entry["lines"] for entry in files)
        message = (
            f"{len(files)} feature {plural(len(files), 'file')}, "
            f"largest {largest:,} / {FEATURE_FILE_LINE_LIMIT:,} lines"
        )
        if violations:
            message += f"; {len(violations)} over the limit"
    return {
        "id": "feature-file-ceiling",
        "title": "Features/*.swift line ceiling",
        "status": "fail" if violations else "pass",
        "severity": "error",
        "path": str(FEATURES_RELATIVE),
        "directory_present": present,
        "limit": FEATURE_FILE_LINE_LIMIT,
        "files": files,
        "violations": violations,
        "message": message,
    }


def check_service_file_ceilings(root: Path) -> dict:
    directory = root / SERVICES_RELATIVE
    files: list[dict] = []
    if directory.is_dir():
        for path in sorted(directory.rglob("*.swift")):
            if not path.is_file():
                continue
            lines = count_lines(path)
            files.append(
                {
                    "path": str(path.relative_to(root)),
                    "lines": lines,
                    "limit": SERVICE_FILE_LINE_LIMIT,
                    "status": "fail" if lines > SERVICE_FILE_LINE_LIMIT else "pass",
                }
            )
    violations = [entry for entry in files if entry["status"] == "fail"]
    present = directory.is_dir()
    if not present:
        message = f"{SERVICES_RELATIVE} does not exist yet (0 service files)"
    elif not files:
        message = f"{SERVICES_RELATIVE} exists but has no .swift files (0 service files)"
    else:
        largest = max(entry["lines"] for entry in files)
        message = (
            f"{len(files)} service {plural(len(files), 'file')}, "
            f"largest {largest:,} / {SERVICE_FILE_LINE_LIMIT:,} lines"
        )
        if violations:
            message += f"; {len(violations)} over the limit"
    return {
        "id": "service-file-ceiling",
        "title": "Services/*.swift line ceiling",
        "status": "fail" if violations else "pass",
        "severity": "error",
        "path": str(SERVICES_RELATIVE),
        "directory_present": present,
        "limit": SERVICE_FILE_LINE_LIMIT,
        "files": files,
        "violations": violations,
        "message": message,
    }


def check_email_login_extension_ceilings(root: Path) -> dict:
    directory = root / EMAIL_LOGIN_EXTENSIONS_RELATIVE
    files: list[dict] = []
    if directory.is_dir():
        for path in sorted(directory.rglob("*.swift")):
            if not path.is_file():
                continue
            lines = count_lines(path)
            files.append(
                {
                    "path": str(path.relative_to(root)),
                    "lines": lines,
                    "limit": EMAIL_LOGIN_EXTENSION_LINE_LIMIT,
                    "status": "fail" if lines > EMAIL_LOGIN_EXTENSION_LINE_LIMIT else "pass",
                }
            )
    violations = [entry for entry in files if entry["status"] == "fail"]
    present = directory.is_dir()
    count = len(files)
    count_limit = EMAIL_LOGIN_EXTENSION_COUNT_BASELINE
    over_count = count > count_limit
    if not present:
        message = f"{EMAIL_LOGIN_EXTENSIONS_RELATIVE} does not exist yet (0 extension files)"
    elif not files:
        message = (
            f"{EMAIL_LOGIN_EXTENSIONS_RELATIVE} exists but has no .swift files "
            "(0 extension files)"
        )
    else:
        largest = max(entry["lines"] for entry in files)
        message = (
            f"{count} EmailLogin extension {plural(count, 'file')} "
            f"(count baseline {count_limit}), "
            f"largest {largest:,} / {EMAIL_LOGIN_EXTENSION_LINE_LIMIT:,} lines"
        )
        if violations:
            message += f"; {len(violations)} over the limit"
        if over_count:
            message += (
                f"; {count - count_limit} file(s) over the {count_limit}-file baseline "
                "(migrate a domain to Services/ instead of adding an extension)"
            )
    return {
        "id": "email-login-extension-ceiling",
        "title": "EmailLogin/*.swift line ceiling",
        "status": "fail" if violations or over_count else "pass",
        "severity": "error",
        "path": str(EMAIL_LOGIN_EXTENSIONS_RELATIVE),
        "directory_present": present,
        "limit": EMAIL_LOGIN_EXTENSION_LINE_LIMIT,
        "count": count,
        "count_limit": count_limit,
        "files": files,
        "violations": violations,
        "message": message,
    }


def check_email_login_test_seams(root: Path) -> dict:
    path = root / EMAIL_LOGIN_RELATIVE
    if not path.is_file():
        raise GuardrailError(f"missing required file: {path}")
    text = path.read_text(encoding="utf-8", errors="replace")
    for_testing = len(FOR_TESTING_RE.findall(text))
    private_func = len(PRIVATE_FUNC_FOR_TESTING_RE.findall(text))

    warnings: list[str] = []
    if for_testing > EMAIL_LOGIN_FOR_TESTING_BASELINE:
        warnings.append(
            f"{for_testing - EMAIL_LOGIN_FOR_TESTING_BASELINE} new ForTesting marker(s) in "
            f"{EMAIL_LOGIN_RELATIVE}; put new seams in TestSupport instead"
        )
    if private_func > EMAIL_LOGIN_PRIVATE_FUNC_FOR_TESTING_BASELINE:
        warnings.append(
            f"{private_func} private func …ForTesting member(s) in {EMAIL_LOGIN_RELATIVE}; "
            "the baseline is 0"
        )
    if for_testing > 0 and not warnings:
        warnings.append(
            f"{for_testing} legacy ForTesting markers remain in {EMAIL_LOGIN_RELATIVE}; "
            "new seams belong in TestSupport (R5)"
        )

    status = "warn" if warnings else "pass"
    message = (
        f"{for_testing} ForTesting markers (baseline {EMAIL_LOGIN_FOR_TESTING_BASELINE}), "
        f"{private_func} private func …ForTesting (baseline "
        f"{EMAIL_LOGIN_PRIVATE_FUNC_FOR_TESTING_BASELINE})"
    )
    return {
        "id": "email-login-test-seams",
        "title": "EmailLogin.swift test seams",
        "status": status,
        "severity": "warning",
        "path": str(EMAIL_LOGIN_RELATIVE),
        "for_testing_markers": for_testing,
        "for_testing_baseline": EMAIL_LOGIN_FOR_TESTING_BASELINE,
        "private_func_markers": private_func,
        "private_func_baseline": EMAIL_LOGIN_PRIVATE_FUNC_FOR_TESTING_BASELINE,
        "warnings": warnings,
        "message": message,
    }


def count_for_testing_lines(path: Path) -> int:
    """Number of lines containing ``ForTesting`` (what ``grep -c ForTesting`` reports)."""
    text = path.read_text(encoding="utf-8", errors="replace")
    return sum(1 for line in text.splitlines() if FOR_TESTING_RE.search(line))


def scan_for_testing(root: Path) -> dict[str, int]:
    """Per-file ``ForTesting`` line counts for every Swift file under ``Sources/``."""
    directory = root / SOURCES_RELATIVE
    counts: dict[str, int] = {}
    if directory.is_dir():
        for path in sorted(directory.rglob("*.swift")):
            if not path.is_file():
                continue
            count = count_for_testing_lines(path)
            if count:
                counts[path.relative_to(root).as_posix()] = count
    return counts


def read_for_testing_baseline(root: Path) -> dict[str, int]:
    path = root / FOR_TESTING_BASELINE_RELATIVE
    if not path.is_file():
        raise GuardrailError(f"missing required file: {path}")
    baseline: dict[str, int] = {}
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if not raw.strip():
            continue
        fields = raw.split("\t")
        if len(fields) != 2 or not fields[1].isdigit():
            raise GuardrailError(
                f"{FOR_TESTING_BASELINE_RELATIVE}:{number}: expected 'path<TAB>count', got {raw!r}"
            )
        if fields[0] in baseline:
            raise GuardrailError(
                f"{FOR_TESTING_BASELINE_RELATIVE}:{number}: duplicate entry for {fields[0]}"
            )
        baseline[fields[0]] = int(fields[1])
    return baseline


def render_for_testing_baseline(counts: dict[str, int]) -> str:
    return "".join(f"{path}\t{count}\n" for path, count in sorted(counts.items()))


def check_for_testing_tree_baseline(root: Path) -> dict:
    counts = scan_for_testing(root)
    baseline = read_for_testing_baseline(root)

    over = sorted(
        (path, count, baseline.get(path, 0))
        for path, count in counts.items()
        if count > baseline.get(path, 0)
    )
    stale = sorted(
        (path, counts.get(path, 0), allowed)
        for path, allowed in baseline.items()
        if counts.get(path, 0) < allowed
    )
    violations = [
        f"{path}: {count} ForTesting line(s) exceeds the baseline of {allowed}; "
        "put new seams in the TestSupport target instead"
        for path, count, allowed in over
    ]
    warnings = [
        f"{path}: {count} ForTesting line(s) is below the baseline of {allowed}; "
        f"lower its line in {FOR_TESTING_BASELINE_RELATIVE}"
        for path, count, allowed in stale
    ]
    total = sum(counts.values())
    allowed_total = sum(baseline.values())
    message = (
        f"{total} ForTesting line(s) in {len(counts)} {plural(len(counts), 'file')} "
        f"(baseline {allowed_total} in {sum(1 for v in baseline.values() if v)} files)"
    )
    if over:
        message += f"; {len(over)} file(s) over their baseline"
    status = "fail" if over else ("warn" if stale else "pass")
    return {
        "id": "for-testing-tree-baseline",
        "title": "Sources/ ForTesting per-file baseline",
        "status": status,
        "severity": "error",
        "path": str(SOURCES_RELATIVE),
        "baseline_path": str(FOR_TESTING_BASELINE_RELATIVE),
        "for_testing_lines": total,
        "for_testing_files": len(counts),
        "baseline_lines": allowed_total,
        "files": counts,
        "violations_detail": violations,
        "warnings": warnings,
        "message": message,
    }


def evaluate(root: Path) -> dict:
    checks = [
        check_email_login_ceiling(root),
        check_feature_file_ceilings(root),
        check_email_login_extension_ceilings(root),
        check_service_file_ceilings(root),
        check_email_login_test_seams(root),
        check_for_testing_tree_baseline(root),
    ]
    warnings = [warning for check in checks for warning in check.get("warnings", [])]
    violations: list[str] = []
    for check in checks:
        if check["status"] != "fail":
            continue
        entries = check.get("violations", [])
        if check.get("violations_detail"):
            violations.extend(check["violations_detail"])
        elif entries:
            violations.extend(
                f"{entry['path']}: {entry['lines']:,} lines exceeds the "
                f"{entry.get('limit', FEATURE_FILE_LINE_LIMIT):,}-line limit"
                for entry in entries
            )
        else:
            violations.append(check["message"])
    failed = bool(violations)
    counts = {
        "passed": sum(1 for check in checks if check["status"] == "pass"),
        "warnings": sum(1 for check in checks if check["status"] == "warn"),
        "failed": sum(1 for check in checks if check["status"] == "fail"),
    }
    return {
        "schema": "raft-server-swift.architecture-guardrails/1",
        "root": str(root),
        "result": "fail" if failed else "pass",
        "exit_code": 1 if failed else 0,
        "counts": counts,
        "baselines": {
            "email_login_lines": EMAIL_LOGIN_LINE_BASELINE,
            "feature_file_line_limit": FEATURE_FILE_LINE_LIMIT,
            "email_login_extension_line_limit": EMAIL_LOGIN_EXTENSION_LINE_LIMIT,
            "email_login_extension_count_baseline": EMAIL_LOGIN_EXTENSION_COUNT_BASELINE,
            "service_file_line_limit": SERVICE_FILE_LINE_LIMIT,
            "email_login_for_testing_markers": EMAIL_LOGIN_FOR_TESTING_BASELINE,
            "email_login_private_func_for_testing": EMAIL_LOGIN_PRIVATE_FUNC_FOR_TESTING_BASELINE,
            "for_testing_tree_baseline_file": str(FOR_TESTING_BASELINE_RELATIVE),
        },
        "checks": checks,
        "warnings": warnings,
        "violations": violations,
    }


def render_text(report: dict) -> str:
    label_width = max(len(check["title"]) for check in report["checks"])
    lines = [
        "architecture guardrails — raft-server-swift",
        f"root: {report['root']}",
        "",
    ]
    for check in report["checks"]:
        badge = {"pass": "PASS", "warn": "WARN", "fail": "FAIL"}[check["status"]]
        lines.append(f"[{badge}] {check['title']:<{label_width}}  {check['message']}")

    if report["violations"]:
        lines.append("")
        lines.append("violations:")
        lines.extend(f"  - {violation}" for violation in report["violations"])
    if report["warnings"]:
        lines.append("")
        lines.append("warnings:")
        lines.extend(f"  - {warning}" for warning in report["warnings"])

    counts = report["counts"]
    lines.append("")
    lines.append(
        f"result: {report['result'].upper()} — "
        f"{counts['passed']} passed, {counts['warnings']} warnings, {counts['failed']} failed"
    )
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Enforce the architecture guardrails documented in docs/ARCHITECTURE.md.",
    )
    parser.add_argument(
        "--root",
        default=str(REPO_ROOT),
        help="checkout root to check (default: the repository containing this script)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="emit a machine-readable report instead of the concise text report",
    )
    parser.add_argument(
        "--print-for-testing-baseline",
        action="store_true",
        help="print the current per-file ForTesting counts as baseline TSV and exit",
    )
    args = parser.parse_args(argv)

    root = Path(args.root).expanduser()
    if args.print_for_testing_baseline:
        if not root.is_dir():
            print(f"check_architecture: root is not a directory: {root}", file=sys.stderr)
            return 2
        sys.stdout.write(render_for_testing_baseline(scan_for_testing(root)))
        return 0
    try:
        if not root.is_dir():
            raise GuardrailError(f"root is not a directory: {root}")
        report = evaluate(root)
    except GuardrailError as error:
        if args.json:
            print(
                json.dumps(
                    {
                        "schema": "raft-server-swift.architecture-guardrails/1",
                        "root": str(root),
                        "result": "error",
                        "exit_code": 2,
                        "error": str(error),
                    },
                    indent=2,
                )
            )
        print(f"check_architecture: {error}", file=sys.stderr)
        return 2

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(render_text(report))
    return report["exit_code"]


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

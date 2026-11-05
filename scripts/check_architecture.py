#!/usr/bin/env python3
"""Architecture guardrails for the raft-server-swift parity port.

The target layering is described in ``docs/ARCHITECTURE.md``. This script
enforces the part of it that can be measured today:

1. ``Sources/RaftHTTP/EmailLogin.swift`` must not grow past its recorded
   baseline (1,201 lines, the stored state + nested types + ``init`` residue).
   Shrinking is always allowed; the baseline constant is a ratchet and may only
   be lowered.
2. Every Swift file under ``Sources/RaftHTTPServer/Features/`` must stay at or
   below 1,200 lines. A missing directory is reported as zero files.
3. Every Swift file under ``Sources/RaftHTTP/EmailLogin/`` must stay at or
   below 1,600 lines. A missing directory is reported as zero files.
4. ``ForTesting`` markers in ``EmailLogin.swift`` are warnings, not failures:
   the recorded baseline is 243 markers and 0 ``private func …ForTesting``.
   New seams belong in the test-only ``TestSupport`` target (see R5 in
   ``docs/ARCHITECTURE.md``).

Exit codes:
    0  pass, or pass with warnings
    1  guardrail violation
    2  operational error (bad root, missing required file)

Usage:
    scripts/check_architecture.py
    scripts/check_architecture.py --json
    scripts/check_architecture.py --root /path/to/checkout
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

# Recorded on 2026-11-05 from the tree that introduced this guardrail.
# The line ceiling is a ratchet: lower it when a slice shrinks the file, never
# raise it to make a check pass.
EMAIL_LOGIN_LINE_BASELINE = 1201
EMAIL_LOGIN_FOR_TESTING_BASELINE = 243
EMAIL_LOGIN_PRIVATE_FUNC_FOR_TESTING_BASELINE = 0

# A feature file larger than this must split along upstream route groups.
FEATURE_FILE_LINE_LIMIT = 1_200

# A domain extension file larger than this must split along its domain again.
EMAIL_LOGIN_EXTENSION_LINE_LIMIT = 1_600

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
            f"{len(files)} EmailLogin extension {plural(len(files), 'file')}, "
            f"largest {largest:,} / {EMAIL_LOGIN_EXTENSION_LINE_LIMIT:,} lines"
        )
        if violations:
            message += f"; {len(violations)} over the limit"
    return {
        "id": "email-login-extension-ceiling",
        "title": "EmailLogin/*.swift line ceiling",
        "status": "fail" if violations else "pass",
        "severity": "error",
        "path": str(EMAIL_LOGIN_EXTENSIONS_RELATIVE),
        "directory_present": present,
        "limit": EMAIL_LOGIN_EXTENSION_LINE_LIMIT,
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


def evaluate(root: Path) -> dict:
    checks = [
        check_email_login_ceiling(root),
        check_feature_file_ceilings(root),
        check_email_login_extension_ceilings(root),
        check_email_login_test_seams(root),
    ]
    warnings = [warning for check in checks for warning in check.get("warnings", [])]
    violations: list[str] = []
    for check in checks:
        if check["status"] != "fail":
            continue
        entries = check.get("violations", [])
        if entries:
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
            "email_login_for_testing_markers": EMAIL_LOGIN_FOR_TESTING_BASELINE,
            "email_login_private_func_for_testing": EMAIL_LOGIN_PRIVATE_FUNC_FOR_TESTING_BASELINE,
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
        f"{counts['passed']} passed, {counts['warnings']} warning, {counts['failed']} failed"
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
    args = parser.parse_args(argv)

    root = Path(args.root).expanduser()
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

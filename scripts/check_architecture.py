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

7. Phase 6 ratchets: six per-file metrics are each ratcheted against
   ``scripts/ratchet_<metric>.tsv`` (``path<TAB>count``; a file that is not
   listed counts as 0, and a missing baseline file means every count is
   ratcheted against 0):

   ==========================  ===============================================
   metric                      counted
   ==========================  ===============================================
   ``extension_directory``     ``extension EmailLoginDirectory`` occurrences
                               under ``Sources/RaftHTTP``
   ``service_httpreply``       ``HTTPReply`` tokens under
                               ``Sources/RaftHTTP/Services``
   ``service_json_any``        ``JSONSerialization``, ``[String: Any]`` or
                               ``[String:Any]`` under
                               ``Sources/RaftHTTP/Services`` and
                               ``Sources/RaftHTTP/DTO``
   ``unchecked_sendable``      ``@unchecked Sendable`` occurrences under
                               ``Sources``
   ``directory_forwarder``     line count of the forwarder file
                               (``Sources/RaftHTTP/Stores/DirectoryStoreForwarders.swift``,
                               0 when the file is gone)
   ``service_directory_calls`` ``directory.`` call sites under
                               ``Sources/RaftHTTP/Services``
   ==========================  ===============================================

   A file above its baseline fails, and so does a file below it: the baseline
   may only decrease, so the slice that shrinks a metric runs
   ``--update-baselines`` in the same commit. Generated sources under
   ``Sources/RaftHTTPServer/Generated/`` are out of scope for every ratchet.

8. Hard zero: no file under ``Sources/RaftHTTP/Services/`` may contain
   ``import Vapor``; the service layer is Vapor-free by construction.

Exit codes:
    0  pass, or pass with warnings
    1  guardrail violation
    2  operational error (bad root, missing required file)

Usage:
    scripts/check_architecture.py
    scripts/check_architecture.py --json
    scripts/check_architecture.py --root /path/to/checkout
    scripts/check_architecture.py --print-for-testing-baseline
    scripts/check_architecture.py --update-baselines
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
DTO_RELATIVE = Path("Sources/RaftHTTP/DTO")
SOURCES_RELATIVE = Path("Sources")
FOR_TESTING_BASELINE_RELATIVE = Path("scripts/for_testing_baseline.tsv")

# Generated sources are data-only corpora (for example
# ``Sources/RaftHTTPServer/Generated/KnowledgeCorpus.swift``). They are not
# hand-written architecture, so no Phase 6 ratchet counts them.
GENERATED_RELATIVE = Path("Sources/RaftHTTPServer/Generated")
GENERATED_PREFIX = GENERATED_RELATIVE.as_posix() + "/"

# The one command that rewrites every ratchet baseline from the current tree.
RATCHET_UPDATE_COMMAND = "python3 scripts/check_architecture.py --update-baselines"

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

# Phase 6 ratchets. Each pattern counts non-overlapping occurrences, not lines,
# so a handler that builds three ``HTTPReply`` values in one expression counts
# three. ``directory_forwarder`` is the one line-count metric.
RATCHET_EXTENSION_DIRECTORY_RE = re.compile(r"extension EmailLoginDirectory")
RATCHET_HTTPREPLY_RE = re.compile(r"HTTPReply")
RATCHET_JSON_ANY_RE = re.compile(r"JSONSerialization|\[String: Any\]|\[String:Any\]")
RATCHET_UNCHECKED_SENDABLE_RE = re.compile(r"@unchecked Sendable")
RATCHET_DIRECTORY_CALL_RE = re.compile(r"directory\.")
# The services layer must not depend on Vapor; this is a hard zero, not a
# baseline. It matches the literal ``import Vapor`` token, so a comment that
# mentions the token also fails, which is the strict reading.
RATCHET_VAPOR_IMPORT_RE = re.compile(r"import Vapor")

# Order here is the order the checks appear in the text and JSON reports.
RATCHET_METRICS: tuple[dict, ...] = (
    {
        "id": "extension_directory",
        "title": "RaftHTTP EmailLoginDirectory extensions",
        "baseline": Path("scripts/ratchet_extension_directory.tsv"),
        "scan_path": "Sources/RaftHTTP",
        "roots": (Path("Sources/RaftHTTP"),),
        "kind": "matches",
        "pattern": RATCHET_EXTENSION_DIRECTORY_RE,
        "unit": "occurrence",
    },
    {
        "id": "service_httpreply",
        "title": "Services/** HTTPReply tokens",
        "baseline": Path("scripts/ratchet_service_httpreply.tsv"),
        "scan_path": "Sources/RaftHTTP/Services",
        "roots": (SERVICES_RELATIVE,),
        "kind": "matches",
        "pattern": RATCHET_HTTPREPLY_RE,
        "unit": "occurrence",
    },
    {
        "id": "service_json_any",
        "title": "Services+DTO JSON any-typed payloads",
        "baseline": Path("scripts/ratchet_service_json_any.tsv"),
        "scan_path": "Sources/RaftHTTP/Services, Sources/RaftHTTP/DTO",
        "roots": (SERVICES_RELATIVE, DTO_RELATIVE),
        "kind": "matches",
        "pattern": RATCHET_JSON_ANY_RE,
        "unit": "occurrence",
    },
    {
        "id": "unchecked_sendable",
        "title": "Sources/** @unchecked Sendable",
        "baseline": Path("scripts/ratchet_unchecked_sendable.tsv"),
        "scan_path": "Sources",
        "roots": (SOURCES_RELATIVE,),
        "kind": "matches",
        "pattern": RATCHET_UNCHECKED_SENDABLE_RE,
        "unit": "occurrence",
    },
    {
        "id": "directory_forwarder",
        "title": "DirectoryStoreForwarders.swift line count",
        "baseline": Path("scripts/ratchet_directory_forwarder.tsv"),
        "scan_path": "Sources/RaftHTTP/Stores/DirectoryStoreForwarders.swift",
        "roots": (),
        "kind": "lines",
        "path": Path("Sources/RaftHTTP/Stores/DirectoryStoreForwarders.swift"),
        "unit": "line",
    },
    {
        "id": "service_directory_calls",
        "title": "Services/** directory. calls",
        "baseline": Path("scripts/ratchet_service_directory_calls.tsv"),
        "scan_path": "Sources/RaftHTTP/Services",
        "roots": (SERVICES_RELATIVE,),
        "kind": "matches",
        "pattern": RATCHET_DIRECTORY_CALL_RE,
        "unit": "occurrence",
    },
)


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


def read_baseline_tsv(path: Path, label: Path) -> dict[str, int]:
    """Parse a ``path<TAB>count`` baseline TSV, raising ``GuardrailError`` on bad input."""
    baseline: dict[str, int] = {}
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if not raw.strip():
            continue
        fields = raw.split("\t")
        if len(fields) != 2 or not fields[1].isdigit():
            raise GuardrailError(
                f"{label}:{number}: expected 'path<TAB>count', got {raw!r}"
            )
        if fields[0] in baseline:
            raise GuardrailError(
                f"{label}:{number}: duplicate entry for {fields[0]}"
            )
        baseline[fields[0]] = int(fields[1])
    return baseline


def read_for_testing_baseline(root: Path) -> dict[str, int]:
    path = root / FOR_TESTING_BASELINE_RELATIVE
    if not path.is_file():
        raise GuardrailError(f"missing required file: {path}")
    return read_baseline_tsv(path, FOR_TESTING_BASELINE_RELATIVE)


def render_baseline_tsv(counts: dict[str, int]) -> str:
    return "".join(f"{path}\t{count}\n" for path, count in sorted(counts.items()))


def render_for_testing_baseline(counts: dict[str, int]) -> str:
    return render_baseline_tsv(counts)


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


def iter_swift_sources(root: Path, bases: tuple[Path, ...]) -> list[tuple[str, Path]]:
    """Sorted ``(relative_posix_path, absolute_path)`` pairs for Swift files under ``bases``.

    Generated sources are excluded; a missing base directory contributes nothing.
    """
    found: dict[str, Path] = {}
    for base_relative in bases:
        base = root / base_relative
        if not base.is_dir():
            continue
        for path in sorted(base.rglob("*.swift")):
            if not path.is_file():
                continue
            relative = path.relative_to(root).as_posix()
            if relative.startswith(GENERATED_PREFIX) or relative in found:
                continue
            found[relative] = path
    return sorted(found.items())


def count_matches(path: Path, pattern: re.Pattern[str]) -> int:
    """Non-overlapping occurrences of ``pattern`` in one file."""
    text = path.read_text(encoding="utf-8", errors="replace")
    return len(pattern.findall(text))


def scan_ratchet_metric(root: Path, metric: dict) -> dict[str, int]:
    """Per-file counts for one ratchet metric; files with a zero count are omitted."""
    if metric["kind"] == "lines":
        path = root / metric["path"]
        if not path.is_file():
            return {}
        return {metric["path"].as_posix(): count_lines(path)}

    counts: dict[str, int] = {}
    for relative, path in iter_swift_sources(root, metric["roots"]):
        count = count_matches(path, metric["pattern"])
        if count:
            counts[relative] = count
    return counts


def read_ratchet_baseline(root: Path, metric: dict) -> dict[str, int]:
    """Baseline for one metric; a missing TSV means every file is ratcheted against 0."""
    path = root / metric["baseline"]
    if not path.is_file():
        return {}
    return read_baseline_tsv(path, metric["baseline"])


def check_ratchet_metric(root: Path, metric: dict) -> dict:
    counts = scan_ratchet_metric(root, metric)
    baseline = read_ratchet_baseline(root, metric)
    unit = metric["unit"]

    over = sorted(
        (path, count, baseline.get(path, 0))
        for path, count in counts.items()
        if count > baseline.get(path, 0)
    )
    under = sorted(
        (path, counts.get(path, 0), allowed)
        for path, allowed in baseline.items()
        if counts.get(path, 0) < allowed
    )
    violations = [
        f"{path}: {count:,} {plural(count, unit)} exceeds the baseline of {allowed:,}; "
        f"reduce it instead of raising {metric['baseline'].as_posix()} "
        "(ratchet: only decrease)"
        for path, count, allowed in over
    ]
    violations.extend(
        f"{path}: {current:,} {plural(current, unit)} is below the baseline of {allowed:,}; "
        f"run `{RATCHET_UPDATE_COMMAND}` to lower it"
        for path, current, allowed in under
    )
    total = sum(counts.values())
    allowed_total = sum(baseline.values())
    baseline_file_count = sum(1 for value in baseline.values() if value)
    message = (
        f"{total:,} {plural(total, unit)} in {len(counts):,} "
        f"{plural(len(counts), 'file')} "
        f"(baseline {allowed_total:,} in {baseline_file_count:,} "
        f"{plural(baseline_file_count, 'file')}; ratchet: only decrease)"
    )
    if over:
        message += f"; {len(over)} file(s) over their baseline"
    if under:
        message += f"; {len(under)} file(s) below their baseline (run --update-baselines)"
    return {
        "id": f"ratchet-{metric['id']}",
        "title": metric["title"],
        "status": "fail" if violations else "pass",
        "severity": "error",
        "metric": metric["id"],
        "scan_path": metric["scan_path"],
        "baseline_path": metric["baseline"].as_posix(),
        "unit": unit,
        "total": total,
        "baseline_total": allowed_total,
        "files": counts,
        "baseline_files": baseline,
        "over": [
            {"path": path, "count": count, "baseline": allowed}
            for path, count, allowed in over
        ],
        "under": [
            {"path": path, "count": current, "baseline": allowed}
            for path, current, allowed in under
        ],
        "violations_detail": violations,
        "message": message,
    }


def update_ratchet_baselines(root: Path) -> list[dict]:
    """Rewrite every ``scripts/ratchet_<metric>.tsv`` from the current tree."""
    written: list[dict] = []
    for metric in RATCHET_METRICS:
        counts = scan_ratchet_metric(root, metric)
        path = root / metric["baseline"]
        rendered = render_baseline_tsv(counts)
        previous = path.read_text(encoding="utf-8") if path.is_file() else None
        path.parent.mkdir(parents=True, exist_ok=True)
        changed = previous != rendered
        if changed:
            path.write_text(rendered, encoding="utf-8")
        written.append(
            {
                "metric": metric["id"],
                "baseline_path": metric["baseline"].as_posix(),
                "files": len(counts),
                "total": sum(counts.values()),
                "unit": metric["unit"],
                "changed": changed,
            }
        )
    return written


def check_services_vapor_free(root: Path) -> dict:
    """Hard zero: no service file may contain ``import Vapor``."""
    files = iter_swift_sources(root, (SERVICES_RELATIVE,))
    offenders = [
        relative
        for relative, path in files
        if RATCHET_VAPOR_IMPORT_RE.search(
            path.read_text(encoding="utf-8", errors="replace")
        )
    ]
    message = (
        f"{len(offenders)} Vapor import(s) in {len(files):,} service "
        f"{plural(len(files), 'file')} (hard zero)"
    )
    if offenders:
        message += f"; {len(offenders)} file(s) import Vapor"
    return {
        "id": "services-vapor-free",
        "title": "Services/** no import Vapor (hard zero)",
        "status": "fail" if offenders else "pass",
        "severity": "error",
        "path": str(SERVICES_RELATIVE),
        "service_files": len(files),
        "offenders": offenders,
        "violations_detail": [
            f"{path}: imports Vapor; the service layer must stay Vapor-free (hard zero)"
            for path in offenders
        ],
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
        *(check_ratchet_metric(root, metric) for metric in RATCHET_METRICS),
        check_services_vapor_free(root),
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
    ratchet_totals = {
        check["metric"]: check["total"] for check in checks if check.get("metric")
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
        "ratchet_totals": ratchet_totals,
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
    parser.add_argument(
        "--update-baselines",
        action="store_true",
        help=(
            "rewrite every scripts/ratchet_<metric>.tsv from the current tree and exit "
            "(scripts/for_testing_baseline.tsv is never rewritten)"
        ),
    )
    args = parser.parse_args(argv)

    root = Path(args.root).expanduser()
    if args.print_for_testing_baseline:
        if not root.is_dir():
            print(f"check_architecture: root is not a directory: {root}", file=sys.stderr)
            return 2
        sys.stdout.write(render_for_testing_baseline(scan_for_testing(root)))
        return 0
    if args.update_baselines:
        if not root.is_dir():
            print(f"check_architecture: root is not a directory: {root}", file=sys.stderr)
            return 2
        written = update_ratchet_baselines(root)
        if args.json:
            print(
                json.dumps(
                    {
                        "schema": "raft-server-swift.architecture-guardrails/1",
                        "root": str(root),
                        "result": "baselines-updated",
                        "exit_code": 0,
                        "baselines": written,
                    },
                    indent=2,
                )
            )
        else:
            for entry in written:
                state = "updated" if entry["changed"] else "unchanged"
                print(
                    f"{state}: {entry['baseline_path']} "
                    f"({entry['files']:,} {plural(entry['files'], 'file')}, "
                    f"{entry['total']:,} {plural(entry['total'], entry['unit'])})"
                )
            print(f"wrote {len(written)} ratchet baseline(s)")
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

#!/usr/bin/env python3
"""Validate historical upstream-module dispositions in the parity ledger.

``docs/PARITY.tsv`` records pending/partial/locked module dispositions, including
reviewed exclusions and deliberate subsystem boundaries. A locked commit and a
named test file are historical links. They do not prove production wiring,
consumer completeness, current execution, or a complete user journey.

The optional tests column is a best-effort historical mapping. Blank means
unknown. Counts of declarations inside locked modules must not be presented as
executed cases or runtime parity coverage. New upstream modules require an
explicit ledger disposition; feature qualification uses the completion guard.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

DEFAULT_SOURCE = "/mnt/data/tmp/grok/raft-source-v1.21.23"
DEFAULT_MANIFEST = "docs/PARITY.tsv"
STATUSES = ("pending", "partial", "locked")
CASE_PATTERN = re.compile(r"^\s*(?:test|it)\(\s*['\"]", re.MULTILINE)
NON_CASE_STOPWORDS = {
    "api",
    "test",
    "tests",
    "spec",
    "contract",
    "realpg",
    "redis",
    "regression",
    "fixtures",
    "v1",
    "v2",
}

REPO_ROOT = Path(__file__).resolve().parent.parent


def case_count(path: Path) -> int:
    return len(CASE_PATTERN.findall(path.read_text(encoding="utf-8", errors="replace")))


def collect_modules(source: Path) -> dict[str, list[tuple[str, int, Path]]]:
    """Return area -> [(module, cases, path)] for the areas that matter."""
    areas: dict[str, list[tuple[str, int, Path]]] = {"route": [], "socket": [], "daemon": []}

    route_dir = source / "packages/server/src/routes"
    for path in sorted(route_dir.glob("*.test.ts")):
        module = path.name[: -len(".test.ts")]
        areas["route"].append((module, case_count(path), path))

    socket_dir = source / "packages/server/src/socket"
    for path in sorted(socket_dir.glob("*.test.ts")):
        module = path.name[: -len(".test.ts")]
        areas["socket"].append((module, case_count(path), path))

    daemon_dir = source / "packages/daemon/src"
    for path in sorted(daemon_dir.rglob("*.test.ts")):
        module = str(path.relative_to(daemon_dir))[: -len(".test.ts")].replace(os.sep, "/")
        areas["daemon"].append((module, case_count(path), path))

    return areas


def swift_test_corpus() -> list[str]:
    """Lowercased Swift test type names, used only for seeding new ledgers."""
    names: list[str] = []
    for path in sorted((REPO_ROOT / "Tests").rglob("*.swift")):
        stem = path.name[: -len(".swift")]
        if stem.endswith("Tests"):
            stem = stem[: -len("Tests")]
        if stem:
            names.append(stem.lower())
    return names


def token_stems(text: str) -> list[str]:
    stems: list[str] = []
    for chunk in re.split(r"[^A-Za-z0-9]+", text):
        for token in re.findall(r"[A-Z]?[a-z]+|[A-Z]+(?![a-z])|\d+", chunk):
            lowered = token.lower()
            if len(lowered) < 2 or lowered in NON_CASE_STOPWORDS:
                continue
            stem = lowered[:-1] if lowered.endswith("s") and len(lowered) > 4 else lowered
            stems.append(stem)
    return stems


def looks_started(module: str, corpus: list[str]) -> bool:
    """Conservative seed: the same Swift test name must cover at least two
    module tokens, or the module name is a single token. Tokens matched across
    different Swift files are not evidence that one module is covered."""
    stems = sorted(set(token_stems(module)))
    if not stems:
        return False
    best = max((sum(1 for stem in stems if stem in name) for name in corpus), default=0)
    return best >= 2 or (len(stems) == 1 and best == 1)


def seed_manifest(areas: dict[str, list[tuple[str, int, Path]]]) -> str:
    corpus = swift_test_corpus()
    lines = ["module\tarea\tstatus\tcommit\tnotes\ttests"]
    for area in ("route", "socket", "daemon"):
        for module, _cases, _path in areas[area]:
            started = area != "daemon" and looks_started(module, corpus)
            status = "partial" if started else "pending"
            lines.append(f"{module}\t{area}\t{status}\t-\tauto-seed\t")
    return "\n".join(lines) + "\n"


def read_manifest(path: Path) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    seen: set[str] = set()
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        if raw.split("\t")[0] == "module":
            continue
        fields = raw.split("\t")
        if len(fields) < 4:
            raise SystemExit(f"{path}:{number}: expected module, area, status, commit; got {raw!r}")
        row = {
            "module": fields[0].strip(),
            "area": fields[1].strip(),
            "status": fields[2].strip(),
            "commit": fields[3].strip(),
            "notes": fields[4].strip() if len(fields) > 4 else "",
            "tests": [part.strip() for part in fields[5].split(",") if part.strip()] if len(fields) > 5 else [],
        }
        if row["module"] in seen:
            raise SystemExit(f"{path}:{number}: duplicate module {row['module']!r}")
        seen.add(row["module"])
        if row["status"] not in STATUSES:
            raise SystemExit(f"{path}:{number}: unknown status {row['status']!r}")
        rows.append(row)
    return rows


def commit_exists(commit: str) -> bool:
    if not commit or commit == "-":
        return False
    result = subprocess.run(
        ["git", "-C", str(REPO_ROOT), "cat-file", "-e", f"{commit}^{{commit}}"],
        capture_output=True,
    )
    return result.returncode == 0


def report(
    areas: dict[str, list[tuple[str, int, Path]]],
    rows: list[dict[str, str]],
    check: bool,
) -> int:
    by_module = {module: (area_name, cases) for area_name, entries in areas.items() for module, cases, _p in entries}
    known = set(by_module)
    problems: list[str] = []

    for row in rows:
        if row["module"] not in known:
            problems.append(f"unknown upstream module {row['module']!r}")
            continue
        if row["area"] != by_module[row["module"]][0]:
            problems.append(f"{row['module']}: area does not match the upstream module")
        if row["status"] == "locked" and not commit_exists(row["commit"]):
            problems.append(f"{row['module']}: locked needs an existing commit, got {row['commit']!r}")
        if row["status"] == "partial" and row["commit"] not in ("-", ""):
            if not commit_exists(row["commit"]):
                problems.append(f"{row['module']}: partial references missing commit {row['commit']!r}")
        for test_path in row["tests"]:
            candidate = REPO_ROOT / test_path
            if not test_path.startswith("Tests/") or not test_path.endswith(".swift"):
                problems.append(f"{row['module']}: test path must be Tests/**.swift, got {test_path!r}")
            elif not candidate.is_file():
                problems.append(f"{row['module']}: test file not found: {test_path!r}")

    listed = {row["module"] for row in rows}
    unlisted = sorted(known - listed)

    print(f"upstream source : {source_dir()}")
    print(f"ledger          : {manifest_path()} ({len(rows)} modules listed)")
    print()

    print("Historical module dispositions; these are not current runtime results.")
    header = f"{'area':<8}{'modules':>8}{'listed':>8}{'locked':>8}{'partial':>9}{'pending':>9}{'decls':>8}{'in locked':>14}"
    print(header)
    print("-" * len(header))
    for area_name in ("route", "socket", "daemon"):
        entries = areas[area_name]
        area_rows = [row for row in rows if row["area"] == area_name and row["module"] in by_module]
        total_cases = sum(cases for _m, cases, _p in entries)
        locked_rows = [row for row in area_rows if row["status"] == "locked"]
        locked_cases = sum(by_module[row["module"]][1] for row in locked_rows)
        partial_rows = [row for row in area_rows if row["status"] == "partial"]
        pending_rows = [row for row in area_rows if row["status"] == "pending"]
        print(
            f"{area_name:<8}{len(entries):>8}{len(area_rows):>8}{len(locked_rows):>8}"
            f"{len(partial_rows):>9}{len(pending_rows):>9}{total_cases:>8}{locked_cases:>14}"
        )

    print()
    route_cases = sum(cases for _m, cases, _p in areas["route"])
    locked_route_cases = sum(
        by_module[row["module"]][1] for row in rows if row["area"] == "route" and row["status"] == "locked"
    )
    mapped = sum(1 for row in rows if row["tests"])
    print(f"route declarations: {locked_route_cases}/{route_cases} inside historically locked modules (not executed cases)")
    print(f"test mapping      : {mapped}/{len(rows)} modules name at least one historical Swift test file")
    print("runtime acceptance: NOT_ESTABLISHED by this ledger; use the change-scoped completion guard")

    if unlisted:
        print()
        print(f"unlisted modules  : {len(unlisted)} (an explicit disposition is required)")
        problems.append(f"{len(unlisted)} upstream modules have no ledger disposition")
    unlocked_route = sorted(
        (
            (by_module[row["module"]][1], row["status"], row["module"])
            for row in rows
            if row["area"] == "route" and row["status"] != "locked"
        ),
        reverse=True,
    )[:10]
    if unlocked_route:
        print()
        print("largest un-locked route modules:")
        for cases, status, module in unlocked_route:
            print(f"  {cases:>4}  {status:<7}  {module}")

    if problems:
        print()
        print("ledger problems:")
        for problem in problems:
            print(f"  - {problem}")
        if check:
            return 1

    return 0


_source_hint: Path | None = None
_manifest_hint: Path | None = None


def source_dir() -> Path:
    return _source_hint or Path(DEFAULT_SOURCE)


def manifest_path() -> Path:
    return _manifest_hint or REPO_ROOT / DEFAULT_MANIFEST


def main(argv: list[str]) -> int:
    global _source_hint, _manifest_hint
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", default=os.environ.get("RAFT_SOURCE_DIR", DEFAULT_SOURCE))
    parser.add_argument("--manifest", default=str(REPO_ROOT / DEFAULT_MANIFEST))
    parser.add_argument("--seed", action="store_true", help="write the ledger if it is missing")
    parser.add_argument("--check", action="store_true", help="exit nonzero on ledger problems")
    args = parser.parse_args(argv)

    _source_hint = Path(args.source).expanduser()
    _manifest_hint = Path(args.manifest).expanduser()
    if not _source_hint.is_dir():
        print(f"upstream source not found: {_source_hint}", file=sys.stderr)
        return 2
    areas = collect_modules(_source_hint)

    if not _manifest_hint.exists():
        if not args.seed:
            print(f"ledger not found: {_manifest_hint} (run --seed to create it)", file=sys.stderr)
            return 2
        _manifest_hint.parent.mkdir(parents=True, exist_ok=True)
        _manifest_hint.write_text(seed_manifest(areas), encoding="utf-8")
        print(f"seeded {_manifest_hint}")

    rows = read_manifest(_manifest_hint)
    return report(areas, rows, args.check)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

"""Strict evidence accounting for paired upstream verification.

This module does not reinterpret the historical PARITY ledger. Callers declare
required behavior IDs before execution; absence, stale evidence, and approved
deviations never become behavioral passes.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any

STATUSES = {"PASS", "FAIL", "NOT_RUN", "BLOCKED"}
TARGETS = ("upstream", "swift")


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def baseline_id(baseline: dict) -> str:
    return digest(json.dumps(baseline, sort_keys=True, separators=(",", ":")).encode())


class Aliases:
    """A bijection between logical identities and concrete IDs on one target."""

    def __init__(self) -> None:
        self.logical: dict[str, str] = {}
        self.concrete: dict[str, str] = {}

    def bind(self, logical: str, concrete: str) -> None:
        if not logical or not concrete:
            raise ValueError("identity aliases must be nonempty")
        if logical in self.logical and self.logical[logical] != concrete:
            raise ValueError("logical identity changed within the scenario")
        if concrete in self.concrete and self.concrete[concrete] != logical:
            raise ValueError("two logical identities collapsed to one concrete ID")
        self.logical[logical] = concrete
        self.concrete[concrete] = logical

    def normalize(self, value: Any) -> Any:
        if isinstance(value, str):
            return {"$identity": self.concrete[value]} if value in self.concrete else value
        if isinstance(value, list):
            return [self.normalize(item) for item in value]
        if isinstance(value, dict):
            return {key: self.normalize(item) for key, item in value.items()}
        return value


def differences(left: Any, right: Any, path: str = "$") -> list[str]:
    """Strict JSON comparison: preserve missing/null, types and array order."""
    if type(left) is not type(right):
        return [f"{path}: type differs"]
    if isinstance(left, dict):
        result = [f"{path}.{key}: field presence differs" for key in sorted(left.keys() ^ right.keys())]
        for key in sorted(left.keys() & right.keys()):
            result.extend(differences(left[key], right[key], f"{path}.{key}"))
        return result
    if isinstance(left, list):
        result = [] if len(left) == len(right) else [f"{path}: array length differs"]
        for index, (a, b) in enumerate(zip(left, right)):
            result.extend(differences(a, b, f"{path}[{index}]"))
        return result
    return [] if left == right else [f"{path}: value differs"]


def evidence_valid(item: dict, root: Path) -> bool:
    """Evidence paths are relative, remain inside this run and match their hash."""
    try:
        relative = Path(item["path"])
        if relative.is_absolute() or ".." in relative.parts:
            return False
        path = (root / relative).resolve()
        if not path.is_relative_to(root.resolve()) or not path.is_file():
            return False
        return digest(path.read_bytes()) == item["sha256"]
    except (KeyError, OSError, TypeError, ValueError):
        return False


def make_report(*, baseline: dict, required: list[str], results: list[dict],
                comparisons: list[dict], evidence_root: Path,
                baseline_verified: dict[str, bool], gates_passed: bool = False,
                defects: list[dict] | None = None, execution_errors: list[str] | None = None) -> dict:
    if not required or len(required) != len(set(required)):
        raise ValueError("declare a nonempty unique required-behavior denominator")
    current = baseline_id(baseline)
    indexed: dict[tuple[str, str], dict] = {}
    for row in results:
        key = (row["target"], row["behavior_id"])
        if row["target"] not in TARGETS or row["status"] not in STATUSES:
            raise ValueError("unknown target or execution status")
        if key in indexed:
            raise ValueError("duplicate behavior result for target")
        if row["behavior_id"] not in required:
            raise ValueError("result is outside the declared behavior denominator")
        indexed[key] = row
    paired: dict[str, dict] = {}
    for row in comparisons:
        identity = row["behavior_id"]
        if identity not in required or identity in paired or row["status"] not in STATUSES:
            raise ValueError("invalid or duplicate paired comparison")
        paired[identity] = row
    counts = {target: {status: 0 for status in sorted(STATUSES)} for target in TARGETS}
    missing: list[dict] = []
    invalid: list[dict] = []
    for target in TARGETS:
        for identity in required:
            row = indexed.get((target, identity))
            if row is None:
                counts[target]["NOT_RUN"] += 1
                missing.append({"target": target, "behavior_id": identity})
                continue
            counts[target][row["status"]] += 1
            if row["status"] == "PASS" and (
                row.get("baseline_id") != current
                or not row.get("evidence")
                or not all(evidence_valid(item, evidence_root) for item in row["evidence"])
                or row.get("disposition") == "approved_deviation"
            ):
                invalid.append({"target": target, "behavior_id": identity,
                                "reason": "pass lacks current, valid behavioral evidence"})
    errors = execution_errors or []
    execution_ok = not errors
    target_passes = all(counts[target]["PASS"] == len(required) for target in TARGETS)
    comparisons_current = all(
        identity in paired and paired[identity]["status"] == "PASS"
        and paired[identity].get("baseline_id") == current for identity in required
    )
    complete = bool(execution_ok and target_passes and comparisons_current and not invalid
                    and all(baseline_verified.get(target) is True for target in TARGETS))
    defects = defects or []
    critical = any(row.get("severity") == "critical" and not row.get("resolved", False) for row in defects)
    return {
        "schemaVersion": 1, "baseline": baseline, "baseline_id": current,
        "required_behaviors": required, "denominator_per_target": len(required),
        "counts": counts, "missing_results": missing, "invalid_pass_evidence": invalid,
        "results": results, "comparisons": comparisons, "defects": defects,
        "baseline_verified": baseline_verified, "execution_errors": errors,
        "execution_ok": execution_ok, "acceptance_complete": complete,
        "release_eligible": bool(complete and gates_passed and not critical),
        "gates_passed": gates_passed,
    }

#!/usr/bin/env python3
"""Plan version-upgrade review from stable entry/rule IDs; never accept a release.

compare --old-inventory OLD --new-inventory NEW --old-contract OLD --new-contract NEW
        [--old-sources OLD_MANIFEST --new-sources NEW_MANIFEST] --out PLAN
manifest --source-root READ_ONLY_ROOT --include RELATIVE_PATH [--include ...] --out FILE

Generated manifests cover only the declared scope and always declare incomplete
coverage. A separately reviewed manifest may set scope.coverage_complete=true;
this is a caller assertion, never inferred from file count. Plans never inherit
PASS results. Static equality is not semantic equality. Exit 2 means invalid
input or output containment; exit 0 means a review plan was written, not accepted.
"""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import sys


class InputError(ValueError):
    pass


def sha(data):
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False)


def json_equal(left, right):
    """Compare JSON structure without Python bool/int/float coercion."""
    return canonical(left) == canonical(right)


def require(condition, message):
    if not condition:
        raise InputError(message)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON object key: " + key)
        result[key] = value
    return result


def load(path):
    try:
        result = json.loads(Path(path).read_text(), object_pairs_hook=unique_object,
                            parse_constant=lambda value: (_ for _ in ()).throw(InputError("non-finite JSON value")))
    except (OSError, ValueError) as error:
        raise InputError(f"cannot read valid JSON input {path}: {error}") from error
    require(isinstance(result, dict), "JSON input must be an object")
    return result


def document(value, label):
    require(isinstance(value, dict) and type(value.get("schema_version")) is int
            and value["schema_version"] == 1, label + " requires schema_version=1")


def rows(value, label):
    require(isinstance(value, list) and all(isinstance(row, dict) for row in value), label + " must be an array of objects")
    return value


def index(values, key, label):
    result = {}
    for row in rows(values, label):
        identity = row.get(key)
        require(isinstance(identity, str) and bool(identity.strip()), label + " missing stable " + key)
        require(identity not in result, label + " duplicate stable ID: " + identity)
        result[identity] = row
    return result


def relative_path(value):
    require(isinstance(value, str) and bool(value) and "\\" not in value, "invalid relative source path")
    path = PurePosixPath(value)
    require(not path.is_absolute() and ".." not in path.parts and str(path) not in ("", "."), "unsafe relative source path")
    return str(path)


def source_reference(value):
    require(isinstance(value, str), "source_refs entries must be strings")
    match = re.fullmatch(r"(.+):([1-9][0-9]*(?:-[1-9][0-9]*)?)", value)
    return relative_path(match.group(1) if match else value)


LOCATION_KEYS = {"line", "line_number", "source_line", "column", "offset", "registration_id"}
IGNORED_RESULT_KEYS = {"normalized_match", "status", "results", "evidence", "execution_status"}


def content(value, root=True, coordinates=False):
    """Remove explicit source coordinates, never payload fields named line/status."""
    if isinstance(value, dict):
        return {key: content(item, False, (root or coordinates) and key in ("source", "mounts")) for key, item in value.items()
                if not ((root or coordinates) and key in LOCATION_KEYS)
                and not (root and key in IGNORED_RESULT_KEYS)}
    if isinstance(value, list):
        return [content(item, False, coordinates) for item in value]
    return value


def location(value, root=True, coordinates=False):
    if isinstance(value, dict):
        return {key: item if (root or coordinates) and key in LOCATION_KEYS else location(item, False, (root or coordinates) and key in ("source", "mounts"))
                for key, item in value.items()
                if ((root or coordinates) and key in LOCATION_KEYS) or isinstance(item, (dict, list))}
    if isinstance(value, list):
        return [location(item, False, coordinates) for item in value]
    return None


def rule_content(row):
    result = content(row)
    result["source_refs"] = sorted({source_reference(value) for value in row.get("source_refs", [])})
    if isinstance(result.get("test_or_scenario_id"), str):
        result["test_or_scenario_id"] = re.sub(r"\s*\(runner:[^)]+\)", "", result["test_or_scenario_id"])
    return result


def rule_location(row):
    return {"coordinates": location(row), "source_refs": row.get("source_refs", []),
            "test_or_scenario_id": row.get("test_or_scenario_id")}


def fields_changed(old, new):
    return sorted(key for key in old.keys() | new.keys()
                  if (key in old) != (key in new) or not json_equal(old.get(key), new.get(key)))


def file_index(values, label):
    result = {}
    for row in rows(values, label):
        name = relative_path(row.get("file"))
        require(name not in result, label + " duplicate file: " + name)
        require(isinstance(row.get("sha256"), str) and re.fullmatch(r"[0-9a-f]{64}", row["sha256"]), label + " invalid sha256")
        result[name] = row["sha256"]
    return result


def validate_inventory(value, label):
    document(value, label)
    operations = index(value.get("operations"), "operation_id", label + " operations")
    for key in ("registrations", "unresolved_registrations", "review_items"):
        rows(value.get(key, []), label + " " + key)
    require(isinstance(value.get("extraction_errors", []), list), label + " extraction_errors must be an array")
    require(isinstance(value.get("scope", {}), dict) and isinstance(value.get("baseline", {}), dict), label + " invalid scope/baseline")
    for row in operations.values():
        if row.get("source") is not None:
            require(isinstance(row["source"], dict), "operation source must be an object")
            relative_path(row["source"].get("file"))
        require(isinstance(row.get("mounts", []), list), "operation mounts must be an array")
        for mount in row.get("mounts", []):
            require(isinstance(mount, dict), "mount must be an object")
            if "file" in mount:
                relative_path(mount["file"])
    files = file_index(value.get("baseline", {}).get("source_files", []), label + " source_files")
    return operations, files


def validate_contract(value, label):
    document(value, label)
    require(isinstance(value.get("profiles"), dict), label + " profiles must be an object")
    require("required_rules" in value, label + " missing required_rules")
    required = rows(value["required_rules"], label + " required_rules")
    additional = rows(value.get("additional_required_rules", []), label + " additional_required_rules")
    rules = index(required + additional, "behavior_id", label + " rules")
    for row in rules.values():
        require(isinstance(row.get("operation_ids"), list) and all(isinstance(item, str) and item for item in row["operation_ids"]), "rule operation_ids must be strings")
        require(isinstance(row.get("source_refs"), list), "rule source_refs must be an array")
        for reference in row["source_refs"]:
            source_reference(reference)
        for key in ("expected", "preconditions", "profile"):
            require(key in row, "rule missing " + key)
        require(row["profile"] in value["profiles"], "rule names an unknown profile")
        for key in ("dependencies", "depends_on"):
            if key in row:
                require(isinstance(row[key], list) and all(isinstance(item, str) and item for item in row[key]), "rule dependencies must be stable behavior IDs")
    return rules, {row["behavior_id"] for row in required}


def validate_manifest(value, label):
    document(value, label)
    require(value.get("kind") == "source_manifest", label + " kind must be source_manifest")
    scope = value.get("scope")
    require(isinstance(scope, dict) and type(scope.get("coverage_complete")) is bool,
            label + " scope.coverage_complete must be boolean")
    require(isinstance(scope.get("includes"), list) and bool(scope["includes"]), label + " scope.includes missing")
    for name in scope["includes"]:
        if name != ".":
            relative_path(name)
    require(isinstance(scope.get("exclusions"), list) and isinstance(scope.get("coverage_statement"), str), label + " scope declaration incomplete")
    require(isinstance(value.get("coverage_issues", []), list), label + " coverage_issues must be an array")
    return file_index(value.get("files"), label + " files")


def multiset_delta(old, new):
    """Candidate matching ignores registration_id; ambiguity remains reviewable."""
    left = Counter(canonical(content(row)) for row in old)
    right = Counter(canonical(content(row)) for row in new)
    return {"removed_candidates": [json.loads(item) for item in sorted((left - right).elements())],
            "added_candidates": [json.loads(item) for item in sorted((right - left).elements())],
            "ambiguous_candidates": [json.loads(item) for item in sorted(set(left) | set(right)) if left[item] > 1 or right[item] > 1],
            "source_location_changed": left == right and not json_equal(old, new),
            "matching": "conservative content multiset; registration_id is never a cross-version identity"}


def compare(old_inventory, new_inventory, old_contract, new_contract, old_sources=None, new_sources=None):
    old_ops, old_route_files = validate_inventory(old_inventory, "old inventory")
    new_ops, new_route_files = validate_inventory(new_inventory, "new inventory")
    old_rules, old_required = validate_contract(old_contract, "old contract")
    new_rules, new_required = validate_contract(new_contract, "new contract")
    require((old_sources is None) == (new_sources is None), "supply both source manifests or neither")
    reasons = set()
    old_files, new_files = dict(old_route_files), dict(new_route_files)
    missing_sources = {"old": [], "new": []}
    if old_sources is None:
        reasons.add("source_coverage_insufficient: both source manifests are required to narrow impact")
    else:
        old_files = validate_manifest(old_sources, "old sources")
        new_files = validate_manifest(new_sources, "new sources")
        for label, manifest, files, inventory_files, rules in (
                ("old", old_sources, old_files, old_route_files, old_rules),
                ("new", new_sources, new_files, new_route_files, new_rules)):
            for name in files.keys() & inventory_files.keys():
                require(files[name] == inventory_files[name], label + " manifest disagrees with inventory hash: " + name)
            referenced = set(inventory_files) | {source_reference(ref) for row in rules.values() for ref in row["source_refs"]}
            missing_sources[label] = sorted(referenced - files.keys())
            if (not manifest["scope"]["coverage_complete"] or manifest["scope"]["includes"] != ["."]
                    or manifest["scope"]["exclusions"] or manifest.get("coverage_issues") or missing_sources[label]):
                reasons.add(label + " source_coverage_insufficient")
        # Partial manifests must not erase handler hashes already captured by
        # the independent inventory; missing coverage remains explicit above.
        old_files = {**old_route_files, **old_files}
        new_files = {**new_route_files, **new_files}
    for label, inventory in (("old", old_inventory), ("new", new_inventory)):
        if inventory.get("scope", {}).get("complete") is not True:
            reasons.add(label + " entry_inventory_incomplete")
        if any(key not in inventory for key in ("registrations", "unresolved_registrations", "extraction_errors", "review_items")):
            reasons.add(label + " inventory_coverage_metadata_missing")
        if inventory.get("extraction_errors") or inventory.get("unresolved_registrations") or inventory.get("review_items"):
            reasons.add(label + " unresolved_entries_or_extraction_errors")
    source_changes = [{"file": name, "change": "added" if name not in old_files else "removed" if name not in new_files else "hash_changed",
                       "old_sha256": old_files.get(name), "new_sha256": new_files.get(name),
                       "interpretation": "source changed; semantic review required", "status": "NOT_RUN"}
                      for name in sorted(old_files.keys() | new_files.keys()) if old_files.get(name) != new_files.get(name)]
    changed_files = {row["file"] for row in source_changes}
    source_rule_map = {}
    operation_rule_map = {}
    for rules in (old_rules, new_rules):
        for identity, row in rules.items():
            for name in {source_reference(ref) for ref in row["source_refs"]}:
                source_rule_map.setdefault(name, set()).add(identity)
            for operation in row["operation_ids"]:
                operation_rule_map.setdefault(operation, set()).add(identity)
    entry_changes = []
    for identity in sorted(old_ops.keys() | new_ops.keys()):
        before, after = old_ops.get(identity), new_ops.get(identity)
        if before is None or after is None:
            entry_changes.append({"operation_id": identity, "change": "added" if before is None else "removed",
                                  "old": before, "new": after, "status": "NOT_RUN"})
            continue
        fields = fields_changed(content(before), content(after))
        files = {item["source"]["file"] for item in (before, after) if isinstance(item.get("source"), dict)}
        files.update(mount["file"] for item in (before, after) for mount in item.get("mounts", []) if "file" in mount)
        hashes = sorted(files & changed_files)
        locations = not json_equal(location(before), location(after))
        if fields or hashes or locations:
            entry_changes.append({"operation_id": identity, "change": "review_required" if fields or hashes else "source_location",
                                  "changed_fields": fields, "changed_source_files": hashes,
                                  "source_location_changed": locations, "old": before, "new": after, "status": "NOT_RUN"})
    rule_changes = []
    for identity in sorted(old_rules.keys() | new_rules.keys()):
        before, after = old_rules.get(identity), new_rules.get(identity)
        if before is None or after is None:
            rule_changes.append({"behavior_id": identity, "change": "added" if before is None else "removed", "status": "NOT_RUN"})
            continue
        fields = fields_changed(rule_content(before), rule_content(after))
        if (identity in old_required) != (identity in new_required):
            fields.append("denominator_membership")
        locations = not json_equal(rule_location(before), rule_location(after))
        if fields or locations:
            rule_changes.append({"behavior_id": identity, "change": "review_required" if fields else "source_location",
                                 "changed_fields": fields, "source_location_changed": locations, "status": "NOT_RUN"})
    registration_changes = multiset_delta(old_inventory.get("registrations", []), new_inventory.get("registrations", []))
    if any(registration_changes[key] for key in ("removed_candidates", "added_candidates", "ambiguous_candidates")):
        reasons.add("registration_candidates_changed_or_ambiguous")
    for row in source_changes:
        mapped = source_rule_map.get(row["file"], set())
        row["behavior_ids"] = sorted(mapped)
        if not mapped:
            reasons.add("changed_source_without_rule_mapping")
        # Without a dependency graph, services/shared/clients/config/locks may
        # affect every endpoint even when the registered handler file is stable.
        if "/routes/" not in "/" + row["file"]:
            reasons.add("transitive_source_change_requires_global_review")
    current_specified = {operation for row in new_rules.values() for operation in row["operation_ids"]}
    unspecified = sorted(set(new_ops) - current_specified)
    if unspecified:
        reasons.add("entries_without_reviewed_rules")
    missing_operations = sorted({operation for row in new_rules.values() for operation in row["operation_ids"]} - new_ops.keys())
    if missing_operations:
        reasons.add("rule_operation_mapping_not_resolved")
    missing_dependencies = sorted({dependency for row in new_rules.values() for key in ("dependencies", "depends_on")
                                   for dependency in row.get(key, [])} - new_rules.keys())
    if missing_dependencies:
        reasons.add("rule_dependency_mapping_not_resolved")
    profiles_changed = not json_equal(old_contract["profiles"], new_contract["profiles"])
    if profiles_changed:
        reasons.add("profile_definitions_changed")
    metadata = lambda value: {key: item for key, item in value.items() if key not in {"required_rules", "additional_required_rules", "profiles", "reference", "purpose"}}
    if not json_equal(metadata(old_contract), metadata(new_contract)):
        reasons.add("contract_cases_or_metadata_changed")
    def identity_metadata(inventory, contract, sources):
        # Preserve missing versus explicit null at identity-field boundaries.
        return {"inventory": {key: inventory[key] for key in ("baseline",) if key in inventory},
                "contract": {key: contract[key] for key in ("reference",) if key in contract},
                "sources": {key: sources[key] for key in ("identity",) if key in (sources or {})}}
    baseline_changed = not json_equal(identity_metadata(old_inventory, old_contract, old_sources),
                                     identity_metadata(new_inventory, new_contract, new_sources))
    rule_reasons = {}
    def affect(identities, reason):
        for identity in identities:
            rule_reasons.setdefault(identity, set()).add(reason)
    for row in entry_changes:
        if row["change"] != "source_location":
            affect(operation_rule_map.get(row["operation_id"], []), "entry_or_handler_changed:" + row["operation_id"])
    for row in rule_changes:
        if row["change"] != "source_location":
            affect([row["behavior_id"]], "reviewed_rule_changed")
    for row in source_changes:
        affect(row["behavior_ids"], "referenced_source_changed:" + row["file"])
    if reasons:
        affect(set(old_rules) | set(new_rules), "global_review_required")
    if baseline_changed:
        affect(set(old_rules) | set(new_rules), "new_baseline_requires_fresh_evidence")
    # Resolve only explicitly declared rule dependencies; unknown dependency
    # graphs remain subject to the global conservative fallback above.
    while True:
        previous = len(rule_reasons)
        for identity, row in new_rules.items():
            if any(dependency in rule_reasons for key in ("dependencies", "depends_on") for dependency in row.get(key, [])):
                affect([identity], "declared_dependency_requires_reverification")
        if len(rule_reasons) == previous:
            break
    queue = [{"kind": "rule_reverification", "behavior_id": identity, "status": "NOT_RUN",
              "reasons": sorted(why), "disposition": "pending_review" if identity in new_rules else "removal_adjudication"}
             for identity, why in sorted(rule_reasons.items())]
    queue.extend({"kind": "source_location_review", "operation_id": row["operation_id"], "status": "NOT_RUN"}
                 for row in entry_changes if row["change"] == "source_location")
    queue.extend({"kind": "source_location_review", "behavior_id": row["behavior_id"], "status": "NOT_RUN"}
                 for row in rule_changes if row["change"] == "source_location")
    queue.extend({"kind": "entry_contract_review", "operation_id": identity, "status": "NOT_RUN", "disposition": "UNSPECIFIED"} for identity in unspecified)
    queue.extend({"kind": "consumer_compatibility_adjudication", "operation_id": identity, "status": "NOT_RUN", "disposition": "pending_adjudication"}
                 for identity in sorted(old_ops.keys() - new_ops.keys()))
    if reasons:
        queue.append({"kind": "global_review", "status": "NOT_RUN", "reasons": sorted(reasons)})
    return {"schema_version": 1, "kind": "upgrade_review_plan", "status": "NOT_RUN",
            "acceptance_complete": False, "release_eligible": False, "prior_passes_inherited": False,
            "interpretation": "Change/review plan only. Static entries with no detected delta do not establish unchanged semantics. Source hash changes are review candidates, not proven behavior changes.",
            "input_ids": {name: sha(canonical(value).encode()) for name, value in {
                "old_inventory": old_inventory, "new_inventory": new_inventory, "old_contract": old_contract,
                "new_contract": new_contract, "old_sources": old_sources, "new_sources": new_sources}.items()},
            "baseline_changed": baseline_changed, "global_review_required": bool(reasons), "global_review_reasons": sorted(reasons),
            "entry_changes": entry_changes, "rule_changes": rule_changes, "source_changes": source_changes,
            "registration_changes": registration_changes, "profiles_changed": profiles_changed,
            "coverage": {"missing_source_files": missing_sources, "unresolved_rule_operation_ids": missing_operations,
                         "unresolved_dependency_ids": missing_dependencies},
            "pending_inputs": {label: {key: inventory.get(key, []) for key in ("unresolved_registrations", "extraction_errors", "review_items")}
                               for label, inventory in (("old", old_inventory), ("new", new_inventory))},
            "reverification_queue": queue}


EXCLUDED_DIRECTORIES = {".git", "node_modules", ".build", "__pycache__", ".cache", ".next", ".turbo", "dist", "build", "coverage"}


def manifest(source_root, includes):
    root = Path(source_root).resolve(strict=True)
    require(root.is_dir(), "source-root must be a directory")
    files, issues = {}, []
    def capture(path):
        name = path.relative_to(root).as_posix()
        if path.is_symlink() or not path.resolve().is_relative_to(root):
            issues.append({"file": name, "reason": "symlink or root escape omitted"})
        elif path.is_file():
            try:
                files[name] = sha(path.read_bytes())
            except OSError as error:
                issues.append({"file": name, "reason": type(error).__name__})
    for name in includes:
        if name != ".":
            relative_path(name)
        path = root / name
        require(path.exists() or path.is_symlink(), "include path does not exist: " + name)
        parts = PurePosixPath(name).parts
        if any(part in EXCLUDED_DIRECTORIES for part in parts) or path.suffix in (".pyc", ".pyo"):
            issues.append({"file": name, "reason": "explicit include is excluded generated/dependency content"})
            continue
        if any(root.joinpath(*parts[:end]).is_symlink() for end in range(1, len(parts) + 1)):
            issues.append({"file": name, "reason": "symlink include or ancestor omitted"})
            continue
        require(path.resolve().is_relative_to(root), "include escapes source-root")
        if path.is_file():
            capture(path)
            continue
        def walk_error(error):
            issues.append({"file": str(Path(error.filename).relative_to(root)), "reason": type(error).__name__})
        for directory, subdirs, names in os.walk(path, followlinks=False, onerror=walk_error):
            current = Path(directory)
            for child in list(subdirs):
                candidate = current / child
                if child in EXCLUDED_DIRECTORIES or candidate.is_symlink():
                    subdirs.remove(child)
                    issues.append({"file": candidate.relative_to(root).as_posix(), "reason": "excluded generated/dependency directory" if child in EXCLUDED_DIRECTORIES else "symlink directory omitted"})
            for child in names:
                if child.endswith((".pyc", ".pyo")):
                    issues.append({"file": (current / child).relative_to(root).as_posix(), "reason": "generated bytecode omitted"})
                else:
                    capture(current / child)
    return {"schema_version": 1, "kind": "source_manifest",
            "scope": {"includes": includes, "exclusions": sorted(EXCLUDED_DIRECTORIES) + ["*.pyc", "*.pyo", "all symlinks"],
                      "coverage_complete": False, "coverage_statement": "Only declared includes were read; exclusions, generated files, dependencies and symlinks are outside coverage. A human must review semantic dependency closure."},
            "coverage_issues": sorted(issues, key=canonical),
            "files": [{"file": name, "sha256": value} for name, value in sorted(files.items())]}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    scan = commands.add_parser("manifest")
    scan.add_argument("--source-root", type=Path, required=True)
    scan.add_argument("--include", action="append", required=True)
    scan.add_argument("--out", type=Path, required=True)
    delta = commands.add_parser("compare")
    for name in ("old-inventory", "new-inventory", "old-contract", "new-contract"):
        delta.add_argument("--" + name, type=Path, required=True)
    delta.add_argument("--old-sources", type=Path)
    delta.add_argument("--new-sources", type=Path)
    delta.add_argument("--out", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        output = args.out.resolve()
        require(not output.exists() or output.stat().st_nlink == 1, "--out must not overwrite a hardlinked input alias")
        if args.command == "manifest":
            root = args.source_root.resolve(strict=True)
            require(not output.is_relative_to(root), "--out must remain outside read-only source-root")
            result = manifest(root, args.include)
        else:
            names = ("old_inventory", "new_inventory", "old_contract", "new_contract", "old_sources", "new_sources")
            paths = {name: getattr(args, name) for name in names}
            require(all(output != path.resolve() for path in paths.values() if path is not None), "--out must not overwrite any input")
            inputs = {name: load(path) if path else None for name, path in paths.items()}
            for name in ("old_inventory", "new_inventory"):
                root = inputs[name].get("baseline", {}).get("upstream_root")
                if isinstance(root, str) and Path(root).is_absolute():
                    require(not output.is_relative_to(Path(root).resolve()), "--out must remain outside declared read-only source-root")
            result = compare(**inputs)
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(result, indent=2, ensure_ascii=False, allow_nan=False) + "\n")
        print(json.dumps({key: result[key] for key in ("kind", "global_review_required", "acceptance_complete", "release_eligible") if key in result}))
        return 0
    except (InputError, OSError, TypeError) as error:
        print(f"upgrade_delta: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())

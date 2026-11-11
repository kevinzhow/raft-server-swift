#!/usr/bin/python3
"""Assemble a staging Main release from a recorded clean build.

Usage:  stage-main-release.py <commit>

Inputs (all under /mnt/data/raft-swift-development):
  build/main-<short>/                         clean detached checkout
  build/scratch-release-<short>/              SwiftPM scratch path
  qualified-artifacts/main-<short>-v1/build-proof.json

Outputs (never installed):
  qualified-artifacts/main-<short>-v1/release/       staged release tree
  qualified-artifacts/main-<short>-v1/main.release.json
  qualified-artifacts/main-<short>-v1/main.launch.json
  qualified-artifacts/main-<short>-v1/stage-proof.json
  qualified-artifacts/main-<short>-v1/elf-graph.json
  qualified-artifacts/main-<short>-v1/runtime-closure.json

The staged manifest uses the deployed schema (schemaVersion, releaseKind,
gitCommit, buildSourceCommit, sourceTreeClean, releaseGates, files, symlinks).
The manifest and the draft launch spec live next to -- not inside -- the release
tree, exactly like the deployed supervision manifest. The draft launch spec
changes only releaseRoot/releaseManifest hash/executable/hashes/gitCommit and
the release identity values in fixedEnvironment; libraryDirectories are derived
from releaseRoot so the verified runtime is the staged one.

No file under /mnt/data/services is written.
"""
from __future__ import annotations

import argparse
import collections
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import traceback
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from env import load as load_deploy_env  # noqa: E402

_CONFIG = load_deploy_env()
DEV = Path(_CONFIG["DEV_ROOT"])
REPO = Path(_CONFIG["SOURCE_REPO"])
SWIFT = Path(_CONFIG["SWIFT"])
SDK = Path(_CONFIG["SWIFT_SDK"])
SWIFT_LIB = SDK / "usr/lib/swift/linux"
JSC = Path(_CONFIG["JSC_LIBRARY"])

DEPLOYED_COMMIT = _CONFIG["BASELINE_COMMIT"]
RELEASE_ROOT_PREFIX = Path(_CONFIG["RELEASE_ROOT_PREFIX"])
PRODUCTION_ROOT = Path(_CONFIG["PRODUCTION_ROOT"])
SUPERVISION = PRODUCTION_ROOT / "production/supervision"
DEPLOYED_RELEASE = RELEASE_ROOT_PREFIX / DEPLOYED_COMMIT
DEPLOYED_MANIFEST = SUPERVISION / "manifests/main.release.json"
DEPLOYED_LAUNCH = SUPERVISION / "main.launch.json"
HOST_PLATFORM = Path(_CONFIG["HOST_PLATFORM_PROOF"])
BUNDLE_NAME = "raft-server-swift_RaftHTTP.bundle"
SHORT_LEN = 8
ARTIFACT_ROOT = Path(_CONFIG["ARTIFACT_ROOT"] or DEV / "qualified-artifacts")
LOG_DIR = DEV / "tmp/release-tools"

# The platform baseline carried by the deployed 1c40 proof. Libraries in this
# name set are never packaged; every other DT_NEEDED object is.
HOST_BASELINE_NAMES = {
    "ld-linux-x86-64.so.2",
    "libc.so.6",
    "libm.so.6",
    "libdl.so.2",
    "libpthread.so.0",
    "librt.so.1",
    "libresolv.so.2",
    "libutil.so.1",
    "libanl.so.1",
}
NATIVE_SEARCH_DIRS = [
    Path("/usr/lib/x86_64-linux-gnu"),
    Path("/lib/x86_64-linux-gnu"),
    Path("/usr/lib"),
    Path("/lib"),
    Path("/usr/local/lib"),
]


class StageError(Exception):
    pass


def require(ok: bool, message: str) -> None:
    if not ok:
        raise StageError(message)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_json(path: Path) -> object:
    with Path(path).open("r", encoding="utf-8") as source:
        return json.load(source)


def write_json(path: Path, value: object) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name("." + path.name + ".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    # The production launcher requires (mode & 0o022) == 0 for non-private
    # configuration. Do not inherit a permissive group-write umask.
    os.chmod(temporary, 0o644)
    temporary.replace(path)


def git_commit(argument: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(REPO), "rev-parse", "--verify", argument + "^{commit}"],
        capture_output=True,
        text=True,
    )
    require(result.returncode == 0, f"cannot resolve commit: {argument}")
    commit = result.stdout.strip()
    require(re.fullmatch(r"[0-9a-f]{40}", commit) is not None, f"invalid commit: {commit}")
    return commit


def readelf_dynamic(path: Path) -> dict[str, object]:
    environment = {"PATH": "/usr/local/bin:/usr/bin:/bin", "LC_ALL": "C"}
    result = subprocess.run(
        ["readelf", "-dW", str(path)],
        capture_output=True,
        text=True,
        env=environment,
    )
    require(result.returncode == 0, f"readelf failed for {path}")
    output = result.stdout
    return {
        "needed": re.findall(r"\(NEEDED\).*?\[([^]]+)\]", output),
        "soname": re.findall(r"\(SONAME\).*?\[([^]]+)\]", output),
        "rpathOrRunpath": re.findall(r"\((?:RPATH|RUNPATH)\).*?\[([^]]+)\]", output),
    }


def resolve_needed(name: str, obj: Path, rpaths: list[str]) -> Path | None:
    candidates: list[Path] = []
    if name.startswith("/"):
        candidates.append(Path(name))
    else:
        # LD_LIBRARY_PATH in the prior ldd-based method was SWIFT_LIB:JSC.parent.
        candidates.append(SWIFT_LIB / name)
        candidates.append(JSC.parent / name)
        for rpath in rpaths:
            for segment in rpath.split(":"):
                if not segment:
                    continue
                segment = segment.replace("$ORIGIN", str(obj.parent))
                segment = segment.replace("${ORIGIN}", str(obj.parent))
                candidates.append(Path(segment) / name)
        for directory in NATIVE_SEARCH_DIRS:
            candidates.append(directory / name)
    seen: set[Path] = set()
    for candidate in candidates:
        try:
            resolved = candidate.resolve(strict=True)
        except OSError:
            continue
        if resolved in seen:
            continue
        seen.add(resolved)
        if resolved.is_file():
            return resolved
    return None


class Closure:
    def __init__(self, binary: Path, allowed_host: dict[str, str]):
        self.binary = binary
        self.allowed_host = allowed_host
        self.files: dict[str, Path] = {}
        self.links: dict[str, str] = {}
        self.host: dict[str, dict[str, str]] = {}
        self.graph: dict[str, dict[str, object]] = {}

    def fail(self, message: str) -> None:
        raise StageError(message)

    def plan_file(self, relative: Path, source: Path) -> None:
        relative_text = relative.as_posix()
        source = source.resolve(strict=True)
        if relative_text in self.files:
            require(
                sha256(self.files[relative_text]) == sha256(source),
                f"conflicting files for {relative_text}",
            )
        elif relative_text in self.links:
            self.fail(f"file/link conflict for {relative_text}")
        else:
            self.files[relative_text] = source

    def plan_alias(self, relative: Path, target: Path) -> None:
        if relative == target:
            return
        relative_text = relative.as_posix()
        literal = os.path.relpath(str(target), str(relative.parent))
        require(relative_text not in self.files, f"alias collides with file: {relative_text}")
        if relative_text in self.links:
            require(self.links[relative_text] == literal, f"alias conflict: {relative_text}")
        else:
            self.links[relative_text] = literal

    def destination(self, source: Path) -> Path:
        actual = source.resolve(strict=True)
        if actual.is_relative_to(SWIFT_LIB):
            return Path("lib/swift/linux") / actual.relative_to(SWIFT_LIB)
        return Path("lib/native") / actual.name

    def build(self) -> None:
        roots = [self.binary.resolve(strict=True)]
        roots += sorted(SWIFT_LIB.glob("*.so*"))
        roots.append(JSC.resolve(strict=True))
        queue = collections.deque(roots)
        while queue:
            source = queue.popleft()
            actual = source.resolve(strict=True)
            if str(actual) in self.graph:
                continue
            dynamic = readelf_dynamic(actual)
            record: dict[str, object] = {
                "sourceSHA256": sha256(actual),
                "needed": [],
                "rpathOrRunpath": dynamic["rpathOrRunpath"],
                "soname": dynamic["soname"],
            }
            for name in dynamic["needed"]:
                target = resolve_needed(name, actual, dynamic["rpathOrRunpath"])
                if target is None:
                    self.fail(f"unresolved DT_NEEDED {name} of {actual}")
                if name in HOST_BASELINE_NAMES:
                    host_path = str(target.resolve(strict=True))
                    require(
                        host_path in self.allowed_host,
                        "host-platform library outside the deployed allowlist: "
                        f"{name} -> {host_path}",
                    )
                    self.host[host_path] = {
                        "name": name,
                        "sha256": sha256(target),
                        "reason": "Specific glibc/ELF-loader platform baseline; not packaged or overridden",
                    }
                    record["needed"].append(
                        {"name": name, "source": host_path, "kind": "host-platform"}
                    )
                else:
                    destination = self.destination(target)
                    self.plan_file(destination, target)
                    self.plan_alias(destination.parent / name, destination)
                    record["needed"].append(
                        {
                            "name": name,
                            "source": str(target),
                            "kind": "packaged",
                            "path": destination.as_posix(),
                        }
                    )
                    queue.append(target)
            if actual != self.binary.resolve(strict=True):
                destination = self.destination(actual)
                self.plan_file(destination, actual)
                self.plan_alias(destination.parent / source.name, destination)
                for soname in dynamic["soname"]:
                    self.plan_alias(destination.parent / soname, destination)
            self.graph[str(actual)] = record


def inventory(root: Path) -> dict[str, dict[str, str]]:
    root = Path(root)
    require(root.is_absolute() and root.resolve(strict=True) == root, f"inventory root is not canonical: {root}")
    require(root.is_dir(), f"inventory root is not a directory: {root}")
    files: dict[str, str] = {}
    links: dict[str, str] = {}
    for directory, names, filenames in os.walk(root, followlinks=False):
        for name in names + filenames:
            item = Path(directory) / name
            relative = item.relative_to(root).as_posix()
            if item.is_symlink():
                target = os.readlink(item)
                require(not Path(target).is_absolute(), f"absolute symlink in inventory: {relative}")
                resolved = item.resolve(strict=True)
                require(resolved.is_relative_to(root), f"symlink escapes inventory: {relative}")
                links[relative] = target
            elif item.is_file():
                files[relative] = sha256(item)
            elif item.is_dir():
                continue
            else:
                raise StageError(f"special file in inventory: {relative}")
    require(bool(files), "inventory is empty")
    require(len(files) + len(links) <= 250000, "inventory is too large")
    return {
        "files": dict(sorted(files.items())),
        "symlinks": dict(sorted(links.items())),
    }


def compare_expected_runtime(
    closure: Closure, deployed_runtime: Path
) -> dict[str, object]:
    expected_files = {
        relative: {"source": str(source), "sha256": sha256(source)}
        for relative, source in closure.files.items()
    }
    deployed_files: dict[str, str] = {}
    deployed_links: dict[str, str] = {}
    for directory, names, filenames in os.walk(deployed_runtime, followlinks=False):
        for name in names + filenames:
            item = Path(directory) / name
            relative = item.relative_to(deployed_runtime).as_posix()
            if relative.startswith("licenses/"):
                continue
            if item.is_symlink():
                deployed_links[relative] = os.readlink(item)
            elif item.is_file():
                deployed_files[relative] = sha256(item)

    missing = sorted(set(expected_files) - set(deployed_files))
    extra = sorted(set(deployed_files) - set(expected_files))
    changed = []
    for relative in sorted(set(expected_files) & set(deployed_files)):
        if expected_files[relative]["sha256"] != deployed_files[relative]:
            changed.append(
                {
                    "path": relative,
                    "source": expected_files[relative]["source"],
                    "sourceSHA256": expected_files[relative]["sha256"],
                    "deployedSHA256": deployed_files[relative],
                }
            )
    link_missing = sorted(set(closure.links) - set(deployed_links))
    link_extra = sorted(set(deployed_links) - set(closure.links))
    link_changed = []
    for relative in sorted(set(closure.links) & set(deployed_links)):
        if closure.links[relative] != deployed_links[relative]:
            link_changed.append(
                {
                    "path": relative,
                    "expectedTarget": closure.links[relative],
                    "deployedTarget": deployed_links[relative],
                }
            )
    identical = not (missing or extra or changed or link_missing or link_extra or link_changed)
    return {
        "identical": identical,
        "expectedFiles": expected_files,
        "deployedFiles": deployed_files,
        "expectedLinks": dict(sorted(closure.links.items())),
        "deployedLinks": dict(sorted(deployed_links.items())),
        "missingInDeployed": missing,
        "extraInDeployed": extra,
        "changed": changed,
        "linkMissingInDeployed": link_missing,
        "linkExtraInDeployed": link_extra,
        "linkChanged": link_changed,
        "declaredFiles": len(expected_files),
        "deployedFilesCount": len(deployed_files),
        "declaredLinks": len(closure.links),
        "deployedLinksCount": len(deployed_links),
    }


def verify_deployed_manifest_runtime() -> dict[str, str]:
    manifest = load_json(DEPLOYED_MANIFEST)
    expected_files = {
        key[len("swift-runtime/"):]: value
        for key, value in manifest["files"].items()
        if key.startswith("swift-runtime/")
    }
    expected_links = {
        key[len("swift-runtime/"):]: value
        for key, value in manifest["symlinks"].items()
        if key.startswith("swift-runtime/")
    }
    runtime = DEPLOYED_RELEASE / "swift-runtime"
    observed = inventory(runtime)
    require(
        observed["files"] == expected_files,
        "deployed 1c40 runtime files do not match the deployed manifest",
    )
    require(
        observed["symlinks"] == expected_links,
        "deployed 1c40 runtime links do not match the deployed manifest",
    )
    return observed


def copy_license_files(closure: Closure, runtime: Path) -> dict[str, list[str]]:
    copied: list[str] = []
    missing: list[str] = []
    for name in ("LICENSE.txt", "LICENSE", "NOTICE.txt", "NOTICE"):
        source = SDK / name
        if source.is_file():
            destination = runtime / "licenses/swift" / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
            copied.append(f"licenses/swift/{name}")
    packages: dict[str, Path] = {}
    for source in set(closure.files.values()):
        if not source.is_relative_to(Path("/usr/lib")) and not source.is_relative_to(Path("/lib")):
            continue
        owner = subprocess.run(
            ["dpkg-query", "-S", str(source)],
            capture_output=True,
            text=True,
            env={"PATH": "/usr/local/bin:/usr/bin:/bin", "LC_ALL": "C"},
        )
        if owner.returncode != 0:
            missing.append(str(source))
            continue
        for line in owner.stdout.splitlines():
            if ": " not in line:
                continue
            package = line.split(": ", 1)[0].split(":", 1)[0]
            copyright_path = Path("/usr/share/doc") / package / "copyright"
            if copyright_path.is_file():
                packages[package] = copyright_path
            else:
                missing.append(f"{package}:copyright")
    for package, source in sorted(packages.items()):
        destination = runtime / "licenses/system" / package / "copyright"
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
        copied.append(f"licenses/system/{package}/copyright")
    return {"copied": sorted(copied), "missing": sorted(set(missing))}


def bundle_inventory(bundle: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for directory, names, filenames in os.walk(bundle, followlinks=False):
        for name in names + filenames:
            item = Path(directory) / name
            if item.is_symlink():
                raise StageError(f"symlink in resource bundle: {item}")
            if item.is_file():
                result[item.relative_to(bundle).as_posix()] = sha256(item)
    return dict(sorted(result.items()))


class Logger:
    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self.stream = path.open("w", encoding="utf-8")

    def __call__(self, message: str) -> None:
        print(message, flush=True)
        self.stream.write(message + "\n")
        self.stream.flush()

    def close(self) -> None:
        self.stream.close()


def run(commit_argument: str, log: Logger) -> dict[str, object]:
    full = git_commit(commit_argument)
    short = full[:SHORT_LEN]
    artifact_dir = ARTIFACT_ROOT / f"main-{short}-v1"
    worktree = DEV / "build" / f"main-{short}"
    proof_path = artifact_dir / "build-proof.json"
    release = artifact_dir / "release"
    manifest_path = artifact_dir / "main.release.json"
    launch_path = artifact_dir / "main.launch.json"

    require(proof_path.is_file(), f"build proof missing: {proof_path}; run build-main-release.sh {full} first")
    proof = load_json(proof_path)
    require(proof.get("gitCommit") == full, "build proof commit mismatch")
    require(proof.get("buildSourceCommit") == full, "build proof source commit mismatch")
    require(proof.get("sourceTreeClean") is True, "build proof sourceTreeClean is not true")
    require(proof.get("sourceTreeCleanBefore") is True, "build proof sourceTreeCleanBefore is not true")
    require(proof.get("sourceTreeCleanAfter") is True, "build proof sourceTreeCleanAfter is not true")
    require(proof.get("trackedBytesUnchanged") is True, "build proof trackedBytesUnchanged is not true")
    require(proof.get("exitCode") == 0, "build proof exitCode is not zero")
    built_at = proof.get("builtAt", "")
    require(
        re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z", built_at)
        is not None,
        f"build proof builtAt is not UTC ISO-8601 with milliseconds: {built_at!r}",
    )

    require(worktree.is_dir(), f"build worktree missing: {worktree}")
    status = subprocess.run(
        ["git", "-C", str(worktree), "status", "--porcelain"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    require(status == "", "build worktree is dirty")
    require(
        subprocess.run(
            ["git", "-C", str(worktree), "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        == full,
        "build worktree HEAD does not match the commit",
    )

    products = Path(proof["productsPath"]).resolve(strict=True)
    binary = Path(proof["binaryPath"]).resolve(strict=True)
    require(products.is_relative_to(DEV / "build"), f"products path is not under the development build root: {products}")
    require(binary.is_relative_to(products), f"binary is not in the products path: {binary}")
    require(sha256(binary) == proof["binarySHA256"], "built binary hash does not match the build proof")
    bundle = products / BUNDLE_NAME
    require(bundle.is_dir(), f"resource bundle missing: {bundle}")
    expected_bundle_names = {
        "Info.plist",
        "raft-markdown-parser.js",
        "raft-markdown-parser.LICENSE.txt",
        "raft-markdown-parser.provenance.json",
        # Owner opener v2 Team Mode artifact (pinned upstream bytes, added in 94aab87).
        "owner-opener-team-mode.html",
    }
    require(
        {item.name for item in bundle.iterdir()} == expected_bundle_names,
        f"unexpected resource bundle contents: {sorted(item.name for item in bundle.iterdir())}",
    )

    log(f"[stage-main] commit {full} (short {short})")
    log(f"[stage-main] binary {binary} ({proof['binarySHA256']})")

    require(not release.exists(), f"staging release already exists: {release}")
    require(not manifest_path.exists(), f"staged manifest already exists: {manifest_path}")
    require(not launch_path.exists(), f"draft launch spec already exists: {launch_path}")

    # ------------------------------------------------------------------
    # 1. Compute the full recursive ELF closure and compare it with 1c40.
    # ------------------------------------------------------------------
    host_platform = load_json(HOST_PLATFORM)["files"]
    allowed_host = {str(Path(path).resolve(strict=True)): info["sha256"] for path, info in host_platform.items()}
    closure = Closure(binary, allowed_host)
    log("[stage-main] computing recursive DT_NEEDED closure (readelf only)")
    closure.build()
    log(
        f"[stage-main] closure: {len(closure.graph)} objects, "
        f"{len(closure.files)} files, {len(closure.links)} aliases, "
        f"{len(closure.host)} host-platform files"
    )

    deployed_inventory = verify_deployed_manifest_runtime()
    comparison = compare_expected_runtime(closure, DEPLOYED_RELEASE / "swift-runtime")
    log(
        "[stage-main] closure identical to deployed 1c40 runtime: "
        f"{comparison['identical']}"
    )

    release.mkdir(parents=True)
    shutil.copy2(binary, release / "RaftServer")
    shutil.copytree(bundle, release / BUNDLE_NAME, symlinks=True)
    require(
        sha256(release / "RaftServer") == proof["binarySHA256"],
        "staged binary hash changed during copy",
    )

    runtime = release / "swift-runtime"
    if comparison["identical"]:
        log("[stage-main] copying the deployed 1c40 swift-runtime with cp -a")
        subprocess.run(["cp", "-a", str(DEPLOYED_RELEASE / "swift-runtime"), str(runtime)], check=True)
        action = "copied-deployed-runtime-identical-closure"
    else:
        log("[stage-main] closure differs; rebuilding swift-runtime from sources")
        runtime.mkdir()
        for relative, source in sorted(closure.files.items()):
            destination = runtime / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
        for relative, target in sorted(closure.links.items()):
            destination = runtime / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.symlink_to(target)
        license_report = copy_license_files(closure, runtime)
        action = "rebuilt-closure"
        log(
            f"[stage-main] rebuilt runtime licenses: {len(license_report['copied'])} copied, "
            f"{len(license_report['missing'])} missing"
        )

    staged_runtime_inventory = inventory(runtime)
    for relative, expected in comparison["expectedFiles"].items():
        require((runtime / relative).is_file(), f"staged runtime missing {relative}")
        require(not (runtime / relative).is_symlink(), f"staged runtime file is a symlink: {relative}")
        require(sha256(runtime / relative) == expected["sha256"], f"staged runtime hash mismatch: {relative}")
    for relative, target in comparison["expectedLinks"].items():
        path = runtime / relative
        require(path.is_symlink(), f"staged runtime alias missing: {relative}")
        require(os.readlink(path) == target, f"staged runtime alias mismatch: {relative}")
    for relative in comparison["deployedFiles"]:
        require(
            relative in staged_runtime_inventory["files"]
            or relative in comparison["extraInDeployed"],
            f"staged runtime file inventory drifted: {relative}",
        )

    if comparison["identical"]:
        require(
            staged_runtime_inventory == deployed_inventory,
            "cp -a did not preserve the deployed runtime inventory",
        )

    # ------------------------------------------------------------------
    # 2. Compare the bundle with the deployed 1c40 bundle.
    # ------------------------------------------------------------------
    staged_bundle = {
        f"{BUNDLE_NAME}/{relative}": digest
        for relative, digest in bundle_inventory(release / BUNDLE_NAME).items()
    }
    deployed_manifest = load_json(DEPLOYED_MANIFEST)
    deployed_bundle = {
        key: value
        for key, value in deployed_manifest["files"].items()
        if key.startswith(BUNDLE_NAME + "/")
    }
    bundle_changed = {
        key: {"deployed": deployed_bundle.get(key), "staged": value}
        for key, value in staged_bundle.items()
        if deployed_bundle.get(key) not in (None, value)
    }
    bundle_added = sorted(set(staged_bundle) - set(deployed_bundle))
    bundle_removed = sorted(set(deployed_bundle) - set(staged_bundle))

    # ------------------------------------------------------------------
    # 3. Inventory the staged tree and write the deployed-schema manifest.
    # ------------------------------------------------------------------
    observed = inventory(release)
    require("RaftServer" in observed["files"], "staged release is missing RaftServer")
    require(
        observed["files"]["RaftServer"] == proof["binarySHA256"],
        "staged RaftServer hash does not match the build proof",
    )
    manifest = {
        "schemaVersion": 1,
        "releaseKind": "main",
        "gitCommit": full,
        "buildSourceCommit": full,
        "sourceTreeClean": True,
        "releaseGates": "passed",
        "files": observed["files"],
        "symlinks": observed["symlinks"],
    }
    write_json(manifest_path, manifest)
    manifest_sha = sha256(manifest_path)

    # ------------------------------------------------------------------
    # 4. Draft launch spec: only the release identity and derived paths move.
    # ------------------------------------------------------------------
    launch = load_json(DEPLOYED_LAUNCH)
    launch["gitCommit"] = full
    launch["releaseRoot"] = str(RELEASE_ROOT_PREFIX / full)
    launch["releaseManifest"] = str(DEPLOYED_LAUNCH.parent / "manifests" / "main.release.json")
    launch["releaseManifestSHA256"] = manifest_sha
    launch["executable"] = str(Path(launch["releaseRoot"]) / "RaftServer")
    launch["executableSHA256"] = observed["files"]["RaftServer"]
    launch["libraryDirectories"] = [
        str(Path(launch["releaseRoot"]) / "swift-runtime/lib/swift/linux"),
        str(Path(launch["releaseRoot"]) / "swift-runtime/lib/native"),
    ]
    fixed = launch["fixedEnvironment"]
    fixed["RAFT_RELEASE_SHA"] = full
    fixed["RAFT_BUILD_AT"] = built_at
    write_json(launch_path, launch)
    launch_sha = sha256(launch_path)

    # ------------------------------------------------------------------
    # 5. Evidence.
    # ------------------------------------------------------------------
    manifest_size = manifest_path.stat().st_size
    release_bytes = sum(
        (release / relative).stat().st_size for relative in observed["files"]
    )
    bundle_bytes = sum((release / relative).stat().st_size for relative in staged_bundle)
    runtime_bytes = sum(
        (runtime / relative).stat().st_size for relative in staged_runtime_inventory["files"]
    )
    old_binary_sha = deployed_manifest["files"]["RaftServer"]
    old_binary_size = (DEPLOYED_RELEASE / "RaftServer").stat().st_size
    new_binary_size = (release / "RaftServer").stat().st_size

    runtime_closure = {
        "gitCommit": full,
        "builtAt": built_at,
        "binarySHA256": proof["binarySHA256"],
        "action": action,
        "identicalToDeployedCommit": DEPLOYED_COMMIT,
        "identical": comparison["identical"],
        "objectsInspected": len(closure.graph),
        "files": len(closure.files),
        "symlinks": len(closure.links),
        "hostPlatformFiles": closure.host,
        "allowedHostPlatformFiles": host_platform,
        "difference": {
            "missingInDeployed": comparison["missingInDeployed"],
            "extraInDeployed": comparison["extraInDeployed"],
            "changed": comparison["changed"],
            "linkMissingInDeployed": comparison["linkMissingInDeployed"],
            "linkExtraInDeployed": comparison["linkExtraInDeployed"],
            "linkChanged": comparison["linkChanged"],
        },
        "stagedRuntimeInventory": staged_runtime_inventory,
        "notInstalled": True,
    }
    write_json(artifact_dir / "runtime-closure.json", runtime_closure)
    write_json(
        artifact_dir / "elf-graph.json",
        {
            "gitCommit": full,
            "roots": [str(binary)] + [str(path) for path in sorted(SWIFT_LIB.glob("*.so*"))] + [str(JSC.resolve(strict=True))],
            "objects": closure.graph,
        },
    )

    stage_proof = {
        "schemaVersion": 1,
        "gitCommit": full,
        "shortCommit": short,
        "builtAt": built_at,
        "toolchain": proof["toolchain"],
        "stagingRoot": str(artifact_dir),
        "releaseRoot": str(release),
        "intendedReleaseRoot": str(RELEASE_ROOT_PREFIX / full),
        "manifest": str(manifest_path),
        "manifestSHA256": manifest_sha,
        "manifestSizeBytes": manifest_size,
        "launchSpec": str(launch_path),
        "launchSpecSHA256": launch_sha,
        "releaseFileCount": len(observed["files"]),
        "releaseSymlinkCount": len(observed["symlinks"]),
        "releaseBytes": release_bytes,
        "binary": {
            "path": str(release / "RaftServer"),
            "sha256": observed["files"]["RaftServer"],
            "sizeBytes": new_binary_size,
            "deployedSHA256": old_binary_sha,
            "deployedSizeBytes": old_binary_size,
            "changed": observed["files"]["RaftServer"] != old_binary_sha,
        },
        "runtime": {
            "action": action,
            "identicalToDeployed": comparison["identical"],
            "fileCount": len(staged_runtime_inventory["files"]),
            "symlinkCount": len(staged_runtime_inventory["symlinks"]),
            "bytes": runtime_bytes,
            "difference": runtime_closure["difference"],
        },
        "bundle": {
            "fileCount": len(staged_bundle),
            "bytes": bundle_bytes,
            "changed": bundle_changed,
            "added": bundle_added,
            "removed": bundle_removed,
            "identicalToDeployed": not (bundle_changed or bundle_added or bundle_removed),
        },
        "gates": {
            "sourceTreeClean": True,
            "trackedBytesUnchanged": True,
            "buildExitCode": 0,
            "closureVerified": True,
            "manifestInventoried": True,
        },
        "installPerformed": False,
        "productionTouched": False,
    }
    write_json(artifact_dir / "stage-proof.json", stage_proof)

    summary = {
        "commit": full,
        "short": short,
        "stagingRoot": str(artifact_dir),
        "releaseRoot": str(release),
        "runtimeAction": action,
        "runtimeIdenticalTo1c40": comparison["identical"],
        "runtimeDifferences": {
            "missing": len(comparison["missingInDeployed"]),
            "extra": len(comparison["extraInDeployed"]),
            "changed": len(comparison["changed"]),
            "links": len(comparison["linkMissingInDeployed"])
            + len(comparison["linkExtraInDeployed"])
            + len(comparison["linkChanged"]),
        },
        "bundleIdenticalTo1c40": not (bundle_changed or bundle_added or bundle_removed),
        "releaseFileCount": len(observed["files"]),
        "releaseSymlinkCount": len(observed["symlinks"]),
        "releaseBytes": release_bytes,
        "manifestSHA256": manifest_sha,
        "launchSpecSHA256": launch_sha,
        "proof": str(artifact_dir / "stage-proof.json"),
        "installPerformed": False,
    }
    log(json.dumps(summary, indent=2))
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(description="Assemble a staging Main release from a recorded clean build.")
    parser.add_argument("commit", help="commit or full SHA already built by build-main-release.sh")
    arguments = parser.parse_args()
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    log = Logger(LOG_DIR / "stage-main.log")
    try:
        run(arguments.commit, log)
        return 0
    except StageError as error:
        log(f"[stage-main] FAIL: {error}")
        return 1
    except Exception:
        log("[stage-main] FAIL: unexpected error")
        log(traceback.format_exc())
        return 1
    finally:
        log.close()


if __name__ == "__main__":
    raise SystemExit(main())

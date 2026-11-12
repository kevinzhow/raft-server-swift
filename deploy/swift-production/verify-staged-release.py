#!/usr/bin/python3
"""Verify a staged Main release without installing it.

Usage:  verify-staged-release.py <stagedir>

<stagedir> is the staged release tree, e.g.
  /mnt/data/raft-swift-development/qualified-artifacts/main-7a87c51d-v1/release

The manifest and draft launch spec are expected next to it:
  ../main.release.json
  ../main.launch.json

Checks:
  1. Import /mnt/data/services/raft-swift/production/supervision/launch-verified.py
     without executing main() and run its verify_release() against the staged
     tree mapped to its intended /mnt/data/services release root.
  2. Independently recompute the staged inventory and require exact equality.
  3. Check the draft launch spec differs from the deployed 1c40 spec only in the
     intended fields, and that its hashes match the staged bytes.
  4. Start the staged RaftServer with an explicitly minimal environment (no
     DATABASE_URL, throwaway JWT secret, no inherited production variables),
     LD_LIBRARY_PATH pointing only at the staged runtime, and free loopback
     ports. Check /livez, /health, /api/version.
  5. Read /proc/<pid>/maps and require every mapped .so to resolve either inside
     the staged release or to the deployed host-platform allowlist. Historical
     JS parser bundles additionally require JSC from the staged runtime;
     native Markdown is compiled into the executable.
  6. Stop with SIGTERM and record the exit code.

No file under /mnt/data/services is written. The environment file under
production/secrets is never read.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import http.client
import importlib.util
import json
import os
import re
import signal
import socket
import subprocess
import sys

# Importing the production launcher must never leave a __pycache__ under
# /mnt/data/services. This is set before the launcher is loaded below.
sys.dont_write_bytecode = True

import time
import traceback
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from env import load as load_deploy_env  # noqa: E402
from markdown_runtime import check_parser_mapping, resource_profile  # noqa: E402

_CONFIG = load_deploy_env()
DEV = Path(_CONFIG["DEV_ROOT"])
DEPLOYED_COMMIT = _CONFIG["BASELINE_COMMIT"]
RELEASE_ROOT_PREFIX = Path(_CONFIG["RELEASE_ROOT_PREFIX"])
PRODUCTION_ROOT = Path(_CONFIG["PRODUCTION_ROOT"])
SUPERVISION = PRODUCTION_ROOT / "production/supervision"
DEPLOYED_RELEASE = RELEASE_ROOT_PREFIX / DEPLOYED_COMMIT
DEPLOYED_LAUNCH = SUPERVISION / "main.launch.json"
DEPLOYED_MANIFEST = SUPERVISION / "manifests/main.release.json"
LAUNCHER = Path(_CONFIG["LAUNCHER"]) if _CONFIG["LAUNCHER"] else SUPERVISION / "launch-verified.py"
HOST_PLATFORM = Path(_CONFIG["HOST_PLATFORM_PROOF"])
BUNDLE_NAME = "raft-server-swift_RaftHTTP.bundle"
INTENDED_RELEASE_PREFIX = RELEASE_ROOT_PREFIX
ARTIFACT_ROOT = Path(_CONFIG["ARTIFACT_ROOT"] or DEV / "qualified-artifacts")
LOG_DIR = DEV / "tmp/release-tools"
SHUTDOWN_TIMEOUT_SECONDS = 20

# Only these paths may differ between the deployed 1c40 launch spec and the
# draft. libraryDirectories are derived from releaseRoot so the launcher loads
# the staged runtime rather than the currently deployed one.
ALLOWED_LAUNCH_CHANGES = {
    "gitCommit",
    "releaseRoot",
    "releaseManifestSHA256",
    "executable",
    "executableSHA256",
    "libraryDirectories",
    "fixedEnvironment.RAFT_RELEASE_SHA",
    "fixedEnvironment.RAFT_BUILD_AT",
}


class VerifyError(Exception):
    pass


def require(ok: bool, message: str) -> None:
    if not ok:
        raise VerifyError(message)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_json(path: Path) -> object:
    with Path(path).open("r", encoding="utf-8") as source:
        return json.load(source)


def inventory(root: Path) -> dict[str, dict[str, str]]:
    root = Path(root)
    require(root.is_absolute(), f"root is not absolute: {root}")
    require(root.resolve(strict=True) == root, f"root is not canonical: {root}")
    require(root.is_dir(), f"root is not a directory: {root}")
    files: dict[str, str] = {}
    links: dict[str, str] = {}
    for directory, names, filenames in os.walk(root, followlinks=False):
        for name in names + filenames:
            item = Path(directory) / name
            relative = item.relative_to(root).as_posix()
            if item.is_symlink():
                target = os.readlink(item)
                require(not Path(target).is_absolute(), f"absolute symlink in inventory: {relative}")
                require(item.resolve(strict=True).is_relative_to(root), f"symlink escapes inventory: {relative}")
                links[relative] = target
            elif item.is_file():
                files[relative] = sha256(item)
            elif item.is_dir():
                continue
            else:
                raise VerifyError(f"special file in inventory: {relative}")
    require(bool(files), "inventory is empty")
    require(len(files) + len(links) <= 250000, "inventory is too large")
    return {
        "files": dict(sorted(files.items())),
        "symlinks": dict(sorted(links.items())),
    }


def import_launcher():
    specification = importlib.util.spec_from_file_location("raft_launch_verified", LAUNCHER)
    require(specification is not None and specification.loader is not None, "cannot load launch-verified.py")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


def deep_diff(left: object, right: object, path: str = "") -> list[str]:
    if type(left) is not type(right):
        return [path or "<root>"]
    if isinstance(left, dict):
        changes: list[str] = []
        for key in sorted(set(left) | set(right)):
            child = f"{path}.{key}" if path else key
            if key not in left or key not in right:
                changes.append(child)
            else:
                changes.extend(deep_diff(left[key], right[key], child))
        return changes
    if isinstance(left, list):
        if left != right:
            return [path or "<root>"]
        return []
    if left != right:
        return [path or "<root>"]
    return []


def free_ports() -> tuple[int, int, int]:
    sockets = []
    ports = []
    try:
        for _ in range(3):
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.bind(("127.0.0.1", 0))
            sockets.append(sock)
            ports.append(sock.getsockname()[1])
    finally:
        for sock in sockets:
            sock.close()
    return ports[0], ports[1], ports[2]


def http_get(port: int, path: str, timeout: float = 3.0) -> tuple[int, bytes]:
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    try:
        connection.request("GET", path)
        response = connection.getresponse()
        return response.status, response.read()
    finally:
        connection.close()


def read_log(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except FileNotFoundError:
        return ""


def stop_process(proc: subprocess.Popen) -> tuple[int | None, int | None, float, bool]:
    """SIGTERM the server's process group; return (rc, signal, seconds, timed_out)."""
    if proc.poll() is not None:
        rc = proc.returncode
        return rc, (-rc if rc is not None and rc < 0 else None), 0.0, False
    started = time.monotonic()
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        rc = proc.wait(timeout=SHUTDOWN_TIMEOUT_SECONDS)
        timed_out = False
    except subprocess.TimeoutExpired:
        timed_out = True
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except ProcessLookupError:
            pass
        rc = proc.wait(timeout=10)
    elapsed = time.monotonic() - started
    return rc, (-rc if rc < 0 else None), elapsed, timed_out


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


def run(stagedir: Path, log: Logger) -> dict[str, object]:
    stagedir = stagedir.resolve(strict=True)
    base = stagedir.parent
    release = stagedir
    if (stagedir / "main.release.json").is_file() and (stagedir / "release").is_dir():
        base = stagedir
        release = stagedir / "release"
    manifest_path = base / "main.release.json"
    launch_path = base / "main.launch.json"
    require(manifest_path.is_file(), f"staged manifest missing: {manifest_path}")
    require(launch_path.is_file(), f"draft launch spec missing: {launch_path}")
    manifest = load_json(manifest_path)
    launch = load_json(launch_path)
    commit = manifest.get("gitCommit")
    require(isinstance(commit, str) and re.fullmatch(r"[0-9a-f]{40}", commit) is not None, "invalid manifest commit")
    intended_root = str(INTENDED_RELEASE_PREFIX / commit)
    built_at = launch.get("fixedEnvironment", {}).get("RAFT_BUILD_AT")
    branch = launch.get("fixedEnvironment", {}).get("RAFT_RELEASE_BRANCH")

    result: dict[str, object] = {
        "schemaVersion": 1,
        "gitCommit": commit,
        "stagedir": str(stagedir),
        "manifest": str(manifest_path),
        "launchSpec": str(launch_path),
        "checks": {},
        "runtime": {},
        "passed": False,
        "installPerformed": False,
        "productionTouched": False,
    }
    checks = result["checks"]
    proc = None
    server_log_path = None
    log_stream = None

    try:
        # ------------------------------------------------------------------
        # 1. Inventory equality and launch-spec consistency.
        # ------------------------------------------------------------------
        observed = inventory(release)
        require(observed["files"] == manifest.get("files"), "staged files do not match the manifest")
        require(observed["symlinks"] == manifest.get("symlinks"), "staged symlinks do not match the manifest")
        checks["inventoryEquality"] = "passed"
        try:
            parser_profile = resource_profile({
                name[len(BUNDLE_NAME) + 1:]
                for name in observed["files"]
                if name.startswith(BUNDLE_NAME + "/")
            })
        except ValueError as error:
            raise VerifyError(str(error)) from error
        require(
            not any(name.startswith(BUNDLE_NAME + "/") for name in observed["symlinks"]),
            "symlink in resource bundle",
        )
        checks["markdownParserRuntime"] = parser_profile
        checks["fileCount"] = len(observed["files"])
        checks["symlinkCount"] = len(observed["symlinks"])
        log(
            f"[verify] inventory: {len(observed['files'])} files, "
            f"{len(observed['symlinks'])} symlinks"
        )

        require(launch.get("schemaVersion") == 1 and launch.get("service") == "main", "launch spec identity")
        require(launch.get("gitCommit") == commit, "launch spec gitCommit does not match the manifest")
        require(launch.get("releaseRoot") == intended_root, "launch releaseRoot is not the intended release root")
        require(
            launch.get("releaseManifest") == str(DEPLOYED_LAUNCH.parent / "manifests" / "main.release.json"),
            "launch releaseManifest is not the supervision manifest path",
        )
        require(launch.get("releaseManifestSHA256") == sha256(manifest_path), "launch releaseManifestSHA256 mismatch")
        require(launch.get("executable") == intended_root + "/RaftServer", "launch executable path mismatch")
        binary = release / "RaftServer"
        require(binary.is_file() and not binary.is_symlink(), "staged RaftServer missing or is a symlink")
        require(sha256(binary) == launch.get("executableSHA256"), "launch executableSHA256 mismatch")
        require(sha256(binary) == manifest["files"].get("RaftServer"), "manifest RaftServer hash mismatch")
        require(launch.get("arguments") == [], "launch arguments must be empty for main")
        require(
            launch.get("libraryDirectories")
            == [
                intended_root + "/swift-runtime/lib/swift/linux",
                intended_root + "/swift-runtime/lib/native",
            ],
            "launch libraryDirectories are not derived from releaseRoot",
        )
        require(launch.get("fixedEnvironment", {}).get("RAFT_RELEASE_SHA") == commit, "RAFT_RELEASE_SHA mismatch")
        require(
            isinstance(built_at, str)
            and re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z", built_at)
            is not None,
            "RAFT_BUILD_AT is not UTC ISO-8601 with milliseconds",
        )
        require(isinstance(branch, str) and branch != "", "RAFT_RELEASE_BRANCH missing")
        build_proof_path = base / "build-proof.json"
        if build_proof_path.is_file():
            proof = load_json(build_proof_path)
            require(proof.get("gitCommit") == commit, "build proof commit mismatch")
            require(proof.get("builtAt") == built_at, "RAFT_BUILD_AT does not match the build proof")
            require(proof.get("binarySHA256") == sha256(binary), "build proof binary hash mismatch")
            checks["buildProof"] = "passed"
        else:
            checks["buildProof"] = "not-present"

        deployed_launch = load_json(DEPLOYED_LAUNCH)
        unexpected = [
            change
            for change in deep_diff(deployed_launch, launch)
            if change not in ALLOWED_LAUNCH_CHANGES
        ]
        require(not unexpected, f"draft launch spec changed unexpected fields: {unexpected}")
        checks["launchSpecDiff"] = "passed"
        log("[verify] launch spec and inventory consistency: passed")

        # ------------------------------------------------------------------
        # 2. Import the production launcher and run its verify_release().
        # ------------------------------------------------------------------
        launcher = import_launcher()
        mapped = copy.deepcopy(launch)
        mapped["releaseRoot"] = str(release)
        mapped["releaseManifest"] = str(manifest_path)
        mapped["releaseManifestSHA256"] = sha256(manifest_path)
        mapped["executable"] = str(binary)
        mapped["executableSHA256"] = sha256(binary)
        mapped["libraryDirectories"] = [
            str(release / "swift-runtime/lib/swift/linux"),
            str(release / "swift-runtime/lib/native"),
        ]
        try:
            verified_executable, verified_arguments = launcher.verify_release(mapped)
        except launcher.Refusal as error:
            raise VerifyError(f"launch-verified.verify_release refused: {error}") from error
        require(Path(verified_executable).resolve(strict=True) == binary.resolve(strict=True), "verified executable mismatch")
        require(verified_arguments == [], "verified arguments mismatch")
        checks["verifyRelease"] = "passed"
        log("[verify] launch-verified.verify_release: passed")

        # ------------------------------------------------------------------
        # 3. Start the staged binary with a controlled, minimal environment.
        # ------------------------------------------------------------------
        host_platform = load_json(HOST_PLATFORM)["files"]
        host_allowed = {
            str(Path(path).resolve(strict=True)): (basename, info["sha256"])
            for path, info in host_platform.items()
            for basename in [Path(path).name]
        }
        staged_allowed: dict[str, tuple[str, str]] = {}
        for relative, digest in observed["files"].items():
            location = release / relative
            if location.is_file() and not location.is_symlink():
                staged_allowed[str(location.resolve(strict=True))] = (relative, digest)

        run_dir = DEV / "tmp" / "release-tools" / f"verify-{commit[:8]}-{os.getpid()}"
        (run_dir / "tmp").mkdir(parents=True, exist_ok=True)
        (run_dir / "cache").mkdir(parents=True, exist_ok=True)
        server_log_path = run_dir / "server.log"

        http_port, realtime_port, daemon_port = free_ports()
        environment = {
            # Throwaway verification settings only; DATABASE_URL is deliberately absent.
            "NODE_ENV": "test",
            "JWT_SECRET": "verify-staged-throwaway-jwt-secret-not-for-production",
            "SLOCK_E2E_AUTO_VERIFY_EMAIL": "1",
            "PORT": str(http_port),
            "SOCKET_PORT": str(realtime_port),
            "DAEMON_CONNECT_PORT": str(daemon_port),
            "SERVER_URL": f"http://127.0.0.1:{http_port}",
            "RAFT_RELEASE_SHA": commit,
            "RAFT_RELEASE_BRANCH": branch,
            "RAFT_BUILD_AT": built_at,
            "LD_LIBRARY_PATH": (
                f"{release}/swift-runtime/lib/swift/linux:"
                f"{release}/swift-runtime/lib/native"
            ),
            "TMPDIR": str(run_dir / "tmp"),
            "XDG_CACHE_HOME": str(run_dir / "cache"),
        }
        log_stream = server_log_path.open("wb")
        proc = subprocess.Popen(
            [str(binary)],
            cwd=str(run_dir),
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=log_stream,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        log(f"[verify] started staged RaftServer pid={proc.pid} ports={http_port}/{realtime_port}/{daemon_port}")

        deadline = time.monotonic() + 45
        ready_line = ""
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                raise VerifyError(
                    f"staged RaftServer exited before ready (exit {proc.returncode}); "
                    f"log: {server_log_path}"
                )
            text = read_log(server_log_path)
            match = re.search(r"raft-server ready http=127\.0\.0\.1:[0-9]+.*", text)
            if match:
                ready_line = match.group(0).strip()
                break
            time.sleep(0.1)
        require(ready_line != "", f"staged RaftServer did not report ready within 45s; log: {server_log_path}")
        checks["ready"] = ready_line
        log(f"[verify] {ready_line}")

        # /livez may race the listener bind that follows the ready line.
        live_deadline = time.monotonic() + 15
        livez_status = None
        livez_body = b""
        while time.monotonic() < live_deadline:
            try:
                livez_status, livez_body = http_get(http_port, "/livez", timeout=2)
                break
            except (ConnectionError, OSError):
                time.sleep(0.1)
        require(livez_status == 200, f"GET /livez expected 200, got {livez_status}: {livez_body[:300]!r}")
        livez = json.loads(livez_body)
        require(livez.get("status") == "ok", f"GET /livez status is not ok: {livez_body[:300]!r}")
        checks["livez"] = {"status": livez_status, "body": livez}
        log("[verify] GET /livez -> 200 status=ok")

        health_status, health_body = http_get(http_port, "/health")
        expected_health = b'{"status":"error","detail":"database unreachable"}'
        require(
            health_status == 503 and health_body == expected_health,
            f"GET /health expected 503 {expected_health!r}, got {health_status} {health_body[:300]!r}",
        )
        checks["health"] = {"status": health_status, "body": health_body.decode("utf-8")}
        log("[verify] GET /health -> 503 exact database-unreachable body")

        version_status, version_body = http_get(http_port, "/api/version")
        require(version_status == 200, f"GET /api/version expected 200, got {version_status}: {version_body[:300]!r}")
        version = json.loads(version_body)
        require(version.get("sha") == commit, f"/api/version sha mismatch: {version}")
        require(version.get("builtAt") == built_at, f"/api/version builtAt mismatch: {version}")
        require(version.get("branch") == branch, f"/api/version branch mismatch: {version}")
        require(isinstance(version.get("version"), str) and version["version"], f"/api/version version missing: {version}")
        checks["version"] = {"status": version_status, "body": version}
        log(f"[verify] GET /api/version -> 200 {json.dumps(version, sort_keys=True)}")

        # ------------------------------------------------------------------
        # 4. Inspect /proc/<pid>/maps.
        # ------------------------------------------------------------------
        maps_path = Path("/proc") / str(proc.pid) / "maps"
        require(maps_path.is_file(), f"cannot read {maps_path}")
        mapped: list[dict[str, str]] = []
        seen: set[str] = set()
        forbidden_prefixes = [
            str(DEPLOYED_RELEASE),
            str(Path(_CONFIG["SWIFT_SDK"]).parent) + "/",
            str(DEV / "build"),
        ]
        for line in maps_path.read_text(encoding="utf-8").splitlines():
            fields = line.split(None, 5)
            if len(fields) < 6 or not fields[5].startswith("/"):
                continue
            raw_path = fields[5]
            require(not raw_path.endswith(" (deleted)"), f"deleted file mapping: {raw_path}")
            path = Path(raw_path)
            try:
                resolved = path.resolve(strict=True)
            except OSError as error:
                raise VerifyError(f"mapped path cannot be resolved: {raw_path} ({error})") from error
            resolved_text = str(resolved)
            if resolved_text in seen:
                continue
            seen.add(resolved_text)
            name = resolved.name
            shared_object = ".so" in name
            if resolved_text in staged_allowed:
                relative, expected_digest = staged_allowed[resolved_text]
                actual_digest = sha256(resolved)
                require(actual_digest == expected_digest, f"mapped staged file hash mismatch: {relative}")
                kind = "staged-release"
                relative_path = relative
            elif resolved_text in host_allowed:
                _, expected_digest = host_allowed[resolved_text]
                require(sha256(resolved) == expected_digest, f"mapped host-platform file hash mismatch: {resolved_text}")
                kind = "host-platform"
                relative_path = ""
            elif shared_object:
                raise VerifyError(f"unclassified .so mapping: {resolved_text}")
            elif resolved.is_relative_to(Path("/usr/lib/locale")):
                kind = "host-locale-data"
                relative_path = ""
            else:
                for prefix in forbidden_prefixes:
                    require(
                        not resolved_text.startswith(prefix),
                        f"mapping from forbidden tree {prefix}: {resolved_text}",
                    )
                kind = "host-data"
                relative_path = ""
            mapped.append(
                {
                    "path": resolved_text,
                    "name": name,
                    "kind": kind,
                    "relativePath": relative_path,
                    "sha256": sha256(resolved),
                }
            )

        staged_mappings = [item for item in mapped if item["kind"] == "staged-release"]
        require(staged_mappings, "no mapped file came from the staged release")
        require(
            any(item["name"] == "libswiftCore.so" for item in staged_mappings),
            "libswiftCore.so is not mapped from the staged runtime",
        )
        try:
            jsc_mapped = check_parser_mapping(parser_profile, mapped)
        except ValueError as error:
            raise VerifyError(str(error)) from error
        require(
            any(item["path"] == str((release / "RaftServer").resolve(strict=True)) for item in staged_mappings),
            "staged RaftServer is not mapped",
        )
        bundle_mapped = any(BUNDLE_NAME in item["path"] or "raft-markdown-parser.js" in item["path"] for item in mapped)
        checks["mappings"] = {
            "mappedFileCount": len(mapped),
            "stagedFileCount": len(staged_mappings),
            "hostPlatformFileCount": len([item for item in mapped if item["kind"] == "host-platform"]),
            "javascriptCoreMappedFromStaged": jsc_mapped,
            "swiftCoreMappedFromStaged": True,
            "markdownParserBundleMapped": bundle_mapped,
            "markdownParserBundlePresent": (release / BUNDLE_NAME / "raft-markdown-parser.js").is_file(),
            "markdownParserStartupValidationImpliedByReady": parser_profile == "javascriptcore",
        }
        result["runtime"]["mappedFiles"] = mapped
        log(
            f"[verify] /proc/{proc.pid}/maps: {len(mapped)} unique mapped files, "
            f"{len(staged_mappings)} from staged release, parser={parser_profile}, JSC mapped={jsc_mapped}"
        )

        # ------------------------------------------------------------------
        # 5. Stop with SIGTERM and record the exit code.
        # ------------------------------------------------------------------
        rc, signal_number, shutdown_seconds, timed_out = stop_process(proc)
        exit_code = rc if rc is not None and rc >= 0 else (128 + (-rc) if rc is not None and rc < 0 else None)
        shutdown = {
            "signalSent": "SIGTERM",
            "returnCode": rc,
            "exitCode": exit_code,
            "terminatedBySignal": signal_number,
            "seconds": round(shutdown_seconds, 3),
            "timedOut": timed_out,
        }
        result["runtime"]["shutdown"] = shutdown
        checks["shutdown"] = shutdown
        log(
            f"[verify] SIGTERM -> rc={rc} exitCode={exit_code} "
            f"signal={signal_number} seconds={shutdown_seconds:.2f} timedOut={timed_out}"
        )
        require(not timed_out, "staged RaftServer did not exit within the SIGTERM timeout")
        result["passed"] = True

    except VerifyError as error:
        result["passed"] = False
        result["failure"] = str(error)
        log(f"[verify] FAIL: {error}")
    except Exception:
        result["passed"] = False
        result["failure"] = "unexpected error"
        log("[verify] FAIL: unexpected error")
        log(traceback.format_exc())
    finally:
        if proc is not None and proc.poll() is None:
            rc, signal_number, shutdown_seconds, timed_out = stop_process(proc)
            result["runtime"]["shutdownOnFailure"] = {
                "signalSent": "SIGTERM",
                "returnCode": rc,
                "seconds": round(shutdown_seconds, 3),
                "timedOut": timed_out,
            }
        if log_stream is not None:
            log_stream.close()
        result["serverLog"] = str(server_log_path) if server_log_path is not None else None
        result["finishedAt"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        verify_path = base / "verify-staged.json"
        verify_path.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
        os.chmod(verify_path, 0o644)
        summary = {
            "passed": result["passed"],
            "gitCommit": commit,
            "stagedir": str(release),
            "inventory": {
                "files": len(observed["files"]) if "observed" in locals() else None,
                "symlinks": len(observed["symlinks"]) if "observed" in locals() else None,
            },
            "runtimeAction": "started-and-stopped-with-SIGTERM" if proc is not None else "not-started",
            "version": checks.get("version", {}).get("body") if isinstance(checks.get("version"), dict) else None,
            "shutdown": checks.get("shutdown"),
            "failure": result.get("failure"),
            "proof": str(verify_path),
            "serverLog": result["serverLog"],
        }
        log(json.dumps(summary, indent=2))
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify a staged Main release without installing it.")
    parser.add_argument("stagedir", help="staged release tree (contains RaftServer)")
    arguments = parser.parse_args()
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    log = Logger(LOG_DIR / "verify-staged.log")
    try:
        result = run(Path(arguments.stagedir), log)
        return 0 if result.get("passed") is True else 1
    finally:
        log.close()


if __name__ == "__main__":
    raise SystemExit(main())

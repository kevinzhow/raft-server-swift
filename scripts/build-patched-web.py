#!/usr/bin/env python3
"""Replay the release Web build from the pinned archive plus a reviewed overlay patch.

The release Web bytes are produced from the *pinned upstream base archive* with a
single Git patch applied, so the inputs are verifiable and the source delta is
reviewable:

  1. export the pinned base commit with `git archive` and assert its SHA-256,
  2. apply the overlay patch and assert the resulting tree differs from the base
     only in the manifest's allowlisted files,
  3. assert `pnpm-lock.yaml` is byte-identical to the base,
  4. install offline from the shared pnpm store with `--frozen-lockfile`,
  5. probe the real Tailwind candidate scanner so a blinded scan (for example an
     ancestor `.gitignore` that hides the extracted tree) fails the build instead
     of shipping a bundle with missing utilities,
  6. run the release build (tsc --noEmit + vite build + the four bundle guards),
  7. audit the built CSS class presence against an optional reference release CSS
     and fail if an actually-used utility disappeared,
  8. write `build-status.json` and `artifact-hashes.json` with base commit, overlay
     commit/patch identity, scan probe, class audit and build environment.

Verifiability scope: the *inputs* are byte-verifiable (pinned archive + patch hash +
allowlisted source delta + unchanged lockfile). The produced artifact bytes are
expected to be stable for the same inputs and toolchain, but they are not claimed
to be independent of the environment/build time (no `SOURCE_DATE_EPOCH` pinning),
and chunk file names may differ across environments. The class-presence audit is
the rendering-regression guard that survives that drift.

The pinned reference checkout is only read (`git archive` + `git show`); this
script never writes to it. Same-origin deployment: `VITE_API_URL` stays empty.

Usage:
  scripts/build-patched-web.py --out /path/to/private/stage \
      [--overlay-commit <sha>] [--reference-css /path/to/app-shell-*.css]

Put --out on the data disk outside directories whose ancestor `.gitignore` hides
it (for example NOT under a directory whose `.gitignore` is `*`): the Tailwind
candidate scanner honours ancestor ignore files, and the scan probe will fail the
build with that diagnosis otherwise.
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import platform
import re
import subprocess
import sys
import tarfile
import uuid
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_PATCH_DIR = REPO_ROOT / "web" / "patches" / "v1.21.23-source.1"
DEFAULT_PATCH = DEFAULT_PATCH_DIR / "avatar-member-cache.patch"
DEFAULT_MANIFEST = DEFAULT_PATCH_DIR / "manifest.json"
DEFAULT_BASE_REPO = Path("/mnt/data/tmp/grok/raft-source-v1.21.23")
DEFAULT_TOOLS = Path("/mnt/data/raft-swift-development/tools")
DEFAULT_STORE = Path("/mnt/data/.pnpm-store")
DEFAULT_CACHE = Path("/mnt/data/raft-swift-development/cache/web")

NODE_VERSION = "v24.22.2"
PNPM_VERSION = "12.11.2"
SCAN_PROBE_REQUIRED_CLASSES = ("w-64", "max-w-2xl", "border-2", "animate-spin")

SCAN_PROBE_JS = r"""
import { createRequire } from "node:module";
import { realpathSync } from "node:fs";
import { resolve } from "node:path";
const web = process.cwd();
const req = createRequire(realpathSync(resolve(web, "node_modules/tailwindcss/package.json")));
const { Scanner } = await import(req.resolve("@tailwindcss/oxide"));
const sources = [
  { base: web, pattern: "**/*", negated: false },
  { base: resolve(web, "src"), pattern: "./components", negated: false },
  { base: resolve(web, "src"), pattern: "./pages", negated: false },
  { base: resolve(web, "src"), pattern: "../node_modules/@botiverse/raft-ui/dist", negated: false },
];
const scanner = new Scanner({ sources });
const candidates = scanner.scan();
const required = Object.fromEntries(REQUIRED.map((name) => [name, candidates.includes(name)]));
const result = {
  files: scanner.files.length,
  candidates: candidates.length,
  hasSettingsPanel: scanner.files.some((file) => String(file).includes("SettingsPanel.tsx")),
  required,
};
console.log(JSON.stringify(result));
if (scanner.files.length < 1000 || candidates.length < 40000 || !result.hasSettingsPanel || Object.values(required).some((value) => !value)) {
  process.exit(3);
}
"""


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def tree_hashes(root: Path) -> dict[str, str]:
    """Hashes of the extracted pinned archive only (no installed dependencies)."""
    hashes: dict[str, str] = {}
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.is_symlink():
            continue
        hashes[str(path.relative_to(root))] = sha256_file(path)
    return hashes


def css_class_tokens(css: str) -> set[str]:
    tokens = re.findall(r"\.((?:\\!)?[A-Za-z_][A-Za-z0-9_\\!:\[\]/%.=-]*)", css)
    return {token.rstrip("\\") for token in tokens if token}


def js_literal_class_tokens(js_sources: list[str]) -> set[str]:
    tokens: set[str] = set()
    literal = re.compile(r"[\"'`]([^\"'`\n]{1,300})[\"'`]")
    candidate = re.compile(r"^!?-?[a-z][a-z0-9@:/._\[\]%-]*$")
    for source in js_sources:
        for raw in literal.findall(source):
            for token in raw.split():
                if candidate.match(token):
                    tokens.add(token)
    return tokens


def validate_allowlist(manifest: dict) -> list[str]:
    allowlisted = manifest["overlay"]["allowlistedSourceChanges"]
    if not isinstance(allowlisted, list) or not allowlisted:
        raise SystemExit("manifest: overlay.allowlistedSourceChanges must be a non-empty list")
    for name in allowlisted:
        if not isinstance(name, str) or name.startswith("/") or ".." in Path(name).parts:
            raise SystemExit(f"manifest: allowlisted path is not a safe relative path: {name!r}")
        if not name.startswith("packages/"):
            raise SystemExit(f"manifest: allowlisted path escapes the Web workspace: {name!r}")
    for name, entry in manifest["overlay"]["changedFiles"].items():
        if name not in allowlisted:
            raise SystemExit(f"manifest: changedFiles entry {name!r} is not allowlisted")
        if not isinstance(entry.get("afterPatchSHA256"), str):
            raise SystemExit(f"manifest: changedFiles[{name!r}] is missing afterPatchSHA256")
    return sorted(allowlisted)


def source_proof_hashes(root: Path, names: list[str]) -> dict[str, str | None]:
    hashes: dict[str, str | None] = {}
    for name in sorted(names):
        path = root / name
        hashes[name] = sha256_file(path) if path.is_file() else None
    return hashes


def verify_source_proof(
    root: Path,
    phase: str,
    baseline: dict[str, str],
    patched: dict[str, str],
    allowlisted: list[str],
) -> dict[str, object]:
    """Every baseline/allowlisted file must still hash to its post-patch value.

    The allowlist authorizes *what the patch changes*, not drift after it: a
    dependency install or the build itself mutating an allowlisted file (for
    example the reviewed authStore change or its regression test) must fail the
    build just like mutating any other tracked file.
    """
    keys = sorted(set(baseline) | set(patched) | set(allowlisted))
    actual = source_proof_hashes(root, keys)
    problems = []
    base_changed = {name for name in set(baseline) | set(patched) if baseline.get(name) != patched.get(name)}
    if base_changed != set(allowlisted):
        problems.append(f"baseline/patch diff is not exactly the allowlist: {sorted(base_changed)}")
    for name in keys:
        expected = patched.get(name)
        if actual.get(name) != expected:
            problems.append(f"{name}: expected post-patch {expected}, found {actual.get(name)}")
    if problems:
        raise RuntimeError(f"source proof failed ({phase}): {'; '.join(problems[:8])}")
    digest = hashlib.sha256()
    for name in keys:
        digest.update(f"{name}:{actual[name]}\n".encode())
    return {"phase": phase, "keys": len(keys), "hash": digest.hexdigest(), "hashes": actual}


def ancestor_ignore_files(path: Path) -> list[str]:
    found: list[str] = []
    current = path.resolve()
    while True:
        for ignore_name in (".gitignore", ".ignore"):
            candidate = current / ignore_name
            if candidate.is_file():
                try:
                    first = candidate.read_text().strip().splitlines()
                except OSError:
                    first = []
                found.append(f"{candidate} ({len(first)} lines)")
        if current.parent == current:
            return found
        current = current.parent


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", required=True, type=Path, help="Private stage directory to create (must not exist)")
    parser.add_argument("--base-repo", type=Path, default=DEFAULT_BASE_REPO)
    parser.add_argument("--patch", type=Path, default=DEFAULT_PATCH)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--tools", type=Path, default=DEFAULT_TOOLS)
    parser.add_argument("--store", type=Path, default=DEFAULT_STORE)
    parser.add_argument("--cache", type=Path, default=DEFAULT_CACHE)
    parser.add_argument("--overlay-commit", default="", help="Optional Web-area commit SHA the patch was generated from")
    parser.add_argument("--reference-css", type=Path, default=None,
                        help="Optional released app-shell CSS used for the class-presence regression audit")
    args = parser.parse_args()

    if platform.machine() != "x86_64":
        raise SystemExit("build-patched-web: only x86_64 is supported for this release")
    if args.out.exists():
        raise SystemExit(f"build-patched-web: --out must not exist: {args.out}")
    manifest = json.loads(args.manifest.read_text())
    base = manifest["pinnedBase"]
    overlay = manifest["overlay"]
    allowlisted = validate_allowlist(manifest)

    node_dir = args.tools / f"node-{NODE_VERSION}-linux-x64"
    node = node_dir / "bin" / "node"
    pnpm = args.tools / f"pnpm-{PNPM_VERSION}" / "node_modules" / ".bin" / "pnpm"
    for tool, label in ((node, "node"), (pnpm, "pnpm")):
        if not tool.exists():
            raise SystemExit(f"build-patched-web: missing {label} at {tool}")

    stage = args.out
    stage.mkdir(parents=True, exist_ok=False)
    stage.chmod(0o700)
    source = stage / "source"
    source.mkdir()

    for suffix in ("downloads", "corepack", "xdg-cache", "xdg-data", "xdg-config", "npm", "node-gyp", "tmp"):
        (args.cache / suffix).mkdir(parents=True, exist_ok=True)
    empty_config = stage / "empty-npmrc"
    empty_config.write_text("")
    empty_global = stage / "empty-global-npmrc"
    empty_global.write_text("")

    env = {
        "PATH": f"{args.tools / f'pnpm-{PNPM_VERSION}' / 'node_modules' / '.bin'}:{node_dir / 'bin'}:/usr/local/bin:/usr/bin:/bin",
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
        "TZ": "UTC",
        "CI": "true",
        "PNPM_HOME": str(args.tools / "pnpm-home"),
        "COREPACK_HOME": str(args.cache / "corepack"),
        "XDG_CACHE_HOME": str(args.cache / "xdg-cache"),
        "XDG_DATA_HOME": str(args.cache / "xdg-data"),
        "XDG_CONFIG_HOME": str(args.cache / "xdg-config"),
        "TMPDIR": str(args.cache / "tmp"),
        "npm_config_cache": str(args.cache / "npm"),
        "npm_config_userconfig": str(empty_config),
        "npm_config_globalconfig": str(empty_global),
        "npm_config_devdir": str(args.cache / "node-gyp"),
        "npm_config_nodedir": str(node_dir),
        "PLAYWRIGHT_BROWSERS_PATH": str(args.cache / "playwright"),
        "PUPPETEER_CACHE_DIR": str(args.cache / "puppeteer"),
    }

    status: dict[str, object] = {
        "outcome": "failed",
        "base": {"tag": base["tag"], "commit": base["commit"]},
        "overlay": {"patch": str(args.patch), "patchSHA256": overlay["patchSHA256"]},
        "overlayCommit": args.overlay_commit or overlay.get("sourceCommit") or "",
        "sameOrigin": True,
        "viteApiURL": "",
        "stagingPathAncestorIgnoreFiles": ancestor_ignore_files(stage),
        "steps": [],
    }

    def save_status() -> None:
        (stage / "build-status.json").write_text(json.dumps(status, indent=2) + "\n")

    def run(name: str, command: list[str], cwd: Path, extra_env: dict[str, str] | None = None) -> None:
        log = stage / f"{name}.log"
        row = {"name": name, "command": command, "cwd": str(cwd), "log": str(log)}
        status["steps"].append(row)
        save_status()
        run_env = dict(env)
        if extra_env:
            run_env.update(extra_env)
        with log.open("wb") as output:
            result = subprocess.run(command, cwd=cwd, env=run_env, stdout=output, stderr=subprocess.STDOUT)
        row["exitCode"] = result.returncode
        save_status()
        if result.returncode:
            raise RuntimeError(f"{name} failed with exit {result.returncode}; see {log}")

    try:
        save_status()
        # 1. Pinned base archive, asserted by hash.
        archive = stage / "base-source.tar"
        subprocess.run(
            ["git", "-C", str(args.base_repo), "archive", "--format=tar", f"--output={archive}", base["commit"]],
            check=True,
        )
        archive_sha = sha256_file(archive)
        if archive_sha != base["archiveSHA256"]:
            raise RuntimeError(f"pinned base archive SHA-256 mismatch: {archive_sha}")
        with tarfile.open(archive) as bundle:
            bundle.extractall(source, filter="data")
        status["base"]["archiveSHA256"] = archive_sha
        baseline = tree_hashes(source)
        (stage / "source-hashes-before.json").write_text(json.dumps(baseline, indent=2) + "\n")

        # 2. Overlay patch; the diff against the base must be exactly the allowlist.
        patch_sha = sha256_file(args.patch)
        if patch_sha != overlay["patchSHA256"]:
            raise RuntimeError(f"overlay patch SHA-256 mismatch: {patch_sha}")
        run("patch-check", ["git", "apply", "--check", str(args.patch)], source)
        run("patch-apply", ["git", "apply", str(args.patch)], source)
        patched = tree_hashes(source)
        changed = sorted(
            (set(baseline) ^ set(patched))
            | {name for name in baseline.keys() & patched.keys() if baseline[name] != patched[name]}
        )
        if changed != allowlisted:
            raise RuntimeError(f"overlay changed files differ from the allowlist: {changed}")
        for name in allowlisted:
            expected = overlay["changedFiles"][name]["afterPatchSHA256"]
            if patched.get(name) != expected:
                raise RuntimeError(f"patched file hash mismatch for {name}: {patched.get(name)}")
        status["overlay"]["changedFiles"] = changed
        status["sourceChanges"] = changed

        # 3. Lockfile must be the pinned one, byte for byte.
        lockfile_sha = sha256_file(source / "pnpm-lock.yaml")
        if lockfile_sha != base["lockfileSHA256"]:
            raise RuntimeError(f"pnpm-lock.yaml changed by the overlay: {lockfile_sha}")
        status["base"]["lockfileSHA256"] = lockfile_sha

        run("node-version", [str(node), "--version"], stage)
        run("pnpm-version", [str(pnpm), "--version"], stage)
        node_version_output = (stage / "node-version.log").read_text().strip()
        pnpm_version_output = (stage / "pnpm-version.log").read_text().strip()
        if node_version_output != NODE_VERSION:
            raise RuntimeError(f"node version mismatch: expected {NODE_VERSION}, got {node_version_output!r}")
        if pnpm_version_output != PNPM_VERSION:
            raise RuntimeError(f"pnpm version mismatch: expected {PNPM_VERSION}, got {pnpm_version_output!r}")
        status["tools"] = {
            "node": {"version": NODE_VERSION, "binarySHA256": sha256_file(node)},
            "pnpm": {"version": PNPM_VERSION, "packageJSONSHA256": sha256_file(
                args.tools / f"pnpm-{PNPM_VERSION}" / "node_modules" / "pnpm" / "package.json"
            )},
        }

        # 4. Offline frozen install from the shared store.
        run(
            "dependency-install",
            [str(pnpm), "--dir", str(source), "--filter", "@botiverse/raft-web...", "install",
             "--frozen-lockfile", "--offline", "--store-dir", str(args.store), "--reporter=append-only"],
            source,
        )

        # 5a. Dependency install must not touch any pinned/allowlisted source file.
        install_proof = verify_source_proof(source, "post-install", baseline, patched, allowlisted)
        status["sourceProof"] = {"post-install": {key: install_proof[key] for key in ("keys", "hash")}}

        # 5. Tailwind candidate scan probe. A blinded scan ships missing utilities;
        #    fail here with the ancestor-include diagnosis instead.
        probe_script = stage / "scan-probe.mjs"
        probe_script.write_text(SCAN_PROBE_JS.replace("REQUIRED", json.dumps(list(SCAN_PROBE_REQUIRED_CLASSES))))
        web_package = source / "packages" / "web"
        probe = subprocess.run(
            [str(node), str(probe_script)],
            cwd=web_package,
            env=env,
            capture_output=True,
            text=True,
        )
        (stage / "scan-probe.log").write_text(probe.stdout + probe.stderr)
        try:
            probe_result = json.loads(probe.stdout.strip().splitlines()[-1])
        except (IndexError, json.JSONDecodeError):
            probe_result = {"error": "unparseable scan probe output", "stdout": probe.stdout[-2000:]}
        status["scanProbe"] = probe_result
        save_status()
        if probe.returncode != 0:
            raise RuntimeError(
                "Tailwind scan probe failed: the candidate scanner cannot see the extracted sources "
                f"(ancestor ignore files: {status['stagingPathAncestorIgnoreFiles']}). "
                "Build from a data-disk path whose ancestor `.gitignore` does not hide the tree; "
                f"probe log: {stage / 'scan-probe.log'}"
            )

        # 6. Release build with explicit, non-inherited identity.
        built_at = datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")
        overlay_short = (args.overlay_commit or patch_sha)[:8]
        release_id = f"web-stage-1.21.23-{datetime.datetime.now(datetime.timezone.utc):%Y%m%dT%H%M%SZ}-{uuid.uuid4().hex[:8]}"
        build_env = {
            "VITE_API_URL": "",
            "VITE_DEPLOYMENT_ENV": "production",
            "VITE_COMMIT_SHA": base["commit"],
            "VITE_FRONTEND_RELEASE_ID": release_id,
            "VITE_BUILD_AT": built_at,
            "VITE_APP_VERSION": "1.21.23",
            "VITE_RELEASE_BRANCH": f"{base['tag']}+overlay.{overlay_short}",
        }
        status["build"] = {
            "releaseId": release_id,
            "builtAt": built_at,
            "environment": "production",
            "sameOriginAPI": True,
            **{key: value for key, value in build_env.items() if key.startswith("VITE_")},
        }
        run("web-build", [str(pnpm), "--dir", str(source), "--store-dir", str(args.store),
                          "--filter", "@botiverse/raft-web", "run", "build"], source, build_env)

        # 7. Artifact identity + class-presence audit.
        dist = source / "packages" / "web" / "dist"
        files = {
            str(path.relative_to(dist)): {"sha256": sha256_file(path), "bytes": path.stat().st_size}
            for path in sorted(dist.rglob("*")) if path.is_file()
        }
        for required in ("index.html", ".vite/manifest.json", "feedback/index.html", "feedback/.vite/manifest.json",
                         "desktop-manifest.json", "_headers"):
            if required not in files:
                raise RuntimeError(f"release artifact missing {required}")
        (stage / "artifact-hashes.json").write_text(json.dumps(files, indent=2) + "\n")
        app_css = [path for path in dist.glob("assets/app-shell-*.css")]
        if len(app_css) != 1:
            raise RuntimeError(f"expected one app-shell CSS asset, found {len(app_css)}")
        css_bytes = app_css[0].read_bytes()
        status["artifacts"] = {
            "dist": str(dist),
            "fileCount": len(files),
            "totalBytes": sum(item["bytes"] for item in files.values()),
            "hashManifest": str(stage / "artifact-hashes.json"),
            "hashManifestSHA256": sha256_file(stage / "artifact-hashes.json"),
            "appShellCSS": {"file": str(app_css[0].relative_to(dist)), "bytes": len(css_bytes),
                            "sha256": sha256_file(app_css[0])},
            "important": {name: files[name] for name in (
                "index.html", ".vite/manifest.json", "feedback/index.html",
                "feedback/.vite/manifest.json", "desktop-manifest.json", "_headers")},
        }

        new_classes = css_class_tokens(css_bytes.decode("utf-8", "replace"))
        js_sources = [path.read_text(encoding="utf-8", errors="replace") for path in dist.glob("assets/*.js")]
        used_tokens = js_literal_class_tokens(js_sources)
        audit: dict[str, object] = {
            "newCSS": str(app_css[0].relative_to(dist)),
            "newCSSClassCount": len(new_classes),
        }
        if args.reference_css is not None:
            reference_bytes = args.reference_css.read_bytes()
            reference_classes = css_class_tokens(reference_bytes.decode("utf-8", "replace"))
            missing = reference_classes - new_classes
            missing_used = sorted(name for name in missing if name in used_tokens)
            audit.update({
                "referenceCSS": str(args.reference_css),
                "referenceCSSClassCount": len(reference_classes),
                "missingClassCount": len(missing),
                "missingUsedClassCount": len(missing_used),
                "missingUsedClasses": missing_used[:200],
                "missingClasses": sorted(missing)[:500],
            })
        (stage / "class-presence-audit.json").write_text(json.dumps(audit, indent=2) + "\n")
        status["classPresenceAudit"] = {key: audit[key] for key in (
            "referenceCSS", "newCSS", "newCSSClassCount", "referenceCSSClassCount",
            "missingClassCount", "missingUsedClassCount", "missingUsedClasses") if key in audit}
        if audit.get("missingUsedClassCount", 0) > 0:
            raise RuntimeError(
                "class-presence audit failed: utilities used by the built JS are missing from the "
                f"built CSS ({audit['missingUsedClassCount']} classes, e.g. {audit['missingUsedClasses'][:5]})"
            )

        # 8. Post-build source verification: every baseline/allowlisted file must
        #    still hash to its post-patch value (allowlist authorizes the patch,
        #    never drift after it).
        build_proof = verify_source_proof(source, "post-build", baseline, patched, allowlisted)
        status["sourceProof"]["post-build"] = {
            key: build_proof[key] for key in ("keys", "hash", "hashes")
        }
        (stage / "source-proof.json").write_text(json.dumps(status["sourceProof"], indent=2) + "\n")
        status["outcome"] = "passed"
        print(f"PASS {stage}")
        return 0
    except Exception as error:  # noqa: BLE001 - every failure must be recorded in the stage
        status["error"] = str(error)
        print(f"FAILED {error}", file=sys.stderr)
        return 1
    finally:
        status["finishedAt"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        save_status()
        print(f"STATUS {stage / 'build-status.json'}")


if __name__ == "__main__":
    sys.exit(main())

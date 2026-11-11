#!/usr/bin/env bash
#
# Build a reproducible release of the Swift Raft "Main" server from a clean,
# detached worktree of the deploy-linux-docker repository.
#
# Usage:  build-main-release.sh <commit>
#
# Properties:
#   * The checkout lives at build/main-<short> and is reused only when it is
#     already detached at the same full commit and git status is empty.
#   * The build never runs in, and never writes to, the source worktree: the
#     SwiftPM scratch path, cache path, TMPDIR and HOME all live under
#     /mnt/data/raft-swift-development.
#   * Tracked bytes are hashed before and after the build and must be
#     identical; git status must be empty both times.
#   * A build proof JSON is written to
#     qualified-artifacts/main-<short>-v1/build-proof.json.
#
# This script does not start, stop or install anything. It only writes under
# /mnt/data/raft-swift-development.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "$SCRIPT_DIR/env.sh"
swift_production_require DEV_ROOT SOURCE_REPO SWIFT || exit 2
DEV=$DEV_ROOT
REPO=$SOURCE_REPO
SHORT_LEN=8
ARTIFACT_ROOT=${ARTIFACT_ROOT:-$DEV/qualified-artifacts}
LOG_DIR="$DEV/tmp/release-tools"

usage() {
    printf 'usage: %s <commit>\n' "$(basename "$0")" >&2
    exit 2
}
die() {
    printf '[build-main] FAIL: %s\n' "$*" >&2
    exit 1
}
log() {
    printf '[build-main] %s\n' "$*"
}

[[ $# -eq 1 ]] || usage
COMMIT_ARG=$1
[[ -n "$COMMIT_ARG" ]] || usage

mkdir -p "$LOG_DIR"
[[ -x "$SWIFT" ]] || die "pinned toolchain is not executable: $SWIFT"

FULL=$(swift_production_full_commit "$COMMIT_ARG") \
    || die "cannot resolve commit: $COMMIT_ARG"
[[ "$FULL" =~ ^[0-9a-f]{40}$ ]] || die "resolved commit is not a full SHA: $FULL"
SHORT=${FULL:0:$SHORT_LEN}

WORKTREE="$DEV/build/main-$SHORT"
SCRATCH="$DEV/build/scratch-release-$SHORT"
CACHE="$DEV/cache/swiftpm"
BUILD_TMP="$DEV/tmp/build-$SHORT"
BUILD_HOME="$DEV/tmp/home-$SHORT"
ARTIFACT_DIR="$ARTIFACT_ROOT/main-$SHORT-v1"
PROOF="$ARTIFACT_DIR/build-proof.json"
BUILD_LOG="$LOG_DIR/build-main-$SHORT.log"

mkdir -p "$DEV/build" "$DEV/cache" "$BUILD_TMP" "$BUILD_HOME" \
    "$ARTIFACT_DIR" "$LOG_DIR"

# Hash every tracked path in the checkout. Paths are sorted so the aggregate is
# deterministic; symlinks are hashed as their target text, never followed.
tracked_hash() {
    python3 - "$1" <<'PY'
import hashlib
import os
import stat
import subprocess
import sys

root = sys.argv[1]
raw_names = subprocess.check_output(
    ["git", "-C", root, "ls-files", "-z"], stderr=subprocess.DEVNULL
)
names = sorted(name for name in raw_names.split(b"\0") if name)
aggregate = hashlib.sha256()
for raw in names:
    relative = os.fsdecode(raw)
    path = os.path.join(root, relative)
    info = os.lstat(path)
    digest = hashlib.sha256()
    if stat.S_ISLNK(info.st_mode):
        digest.update(b"link\0")
        digest.update(os.fsencode(os.readlink(path)))
    elif stat.S_ISREG(info.st_mode):
        with open(path, "rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
    else:
        raise SystemExit("tracked path is not a regular file or symlink: " + relative)
    aggregate.update(raw + b"\0" + digest.hexdigest().encode("ascii") + b"\n")
print(aggregate.hexdigest())
PY
}

write_proof() {
    local exit_code=$1
    local tracked_unchanged=$2
    local clean_after=$3
    local failure=$4
    python3 - "$PROOF" \
        "$FULL" "$SHORT" "$WORKTREE" "$SCRATCH" "$CACHE" \
        "$PRODUCTS" "$BINARY" "$BINARY_SHA" \
        "$TOOLCHAIN_VERSION" "$TOOLCHAIN_TARGET" \
        "$STARTED_AT" "$FINISHED_AT" "$BUILT_AT" "$ELAPSED" \
        "$exit_code" "$PRE_HASH" "$POST_HASH" "$PRE_COUNT" \
        "$tracked_unchanged" "$CLEAN_BEFORE" "$clean_after" \
        "$BUILD_LOG" "$WORKTREE_ACTION" "$failure" <<'PY'
import json
import os
import sys
from pathlib import Path

(
    proof_path,
    full,
    short,
    worktree,
    scratch,
    cache,
    products,
    binary,
    binary_sha,
    toolchain_version,
    toolchain_target,
    started_at,
    finished_at,
    built_at,
    elapsed,
    exit_code,
    pre_hash,
    post_hash,
    pre_count,
    tracked_unchanged,
    clean_before,
    clean_after,
    build_log,
    worktree_action,
    failure,
) = sys.argv[1:]

proof = {
    "schemaVersion": 1,
    "releaseKind": "main",
    "gitCommit": full,
    "buildSourceCommit": full,
    "sourceTreeClean": clean_before == "true",
    "sourceTreeCleanBefore": clean_before == "true",
    "sourceTreeCleanAfter": clean_after == "true",
    "trackedBytesUnchanged": tracked_unchanged == "true",
    "trackedFileCount": int(pre_count),
    "trackedHashBefore": pre_hash,
    "trackedHashAfter": post_hash,
    "toolchain": {
        "path": os.environ.get("SWIFT", ""),
        "version": toolchain_version,
        "target": toolchain_target,
    },
    "worktree": worktree,
    "worktreeAction": worktree_action,
    "scratchPath": scratch,
    "cachePath": cache,
    "productsPath": products,
    "binaryPath": binary,
    "binarySHA256": binary_sha,
    "startedAt": started_at,
    "finishedAt": finished_at,
    "builtAt": built_at,
    "buildDurationSeconds": int(elapsed),
    "exitCode": int(exit_code),
    "buildLog": build_log,
    "failure": failure or None,
}
Path(proof_path).parent.mkdir(parents=True, exist_ok=True)
temporary = Path(proof_path).with_name(".build-proof.json.tmp")
temporary.write_text(json.dumps(proof, indent=2) + "\n")
os.chmod(temporary, 0o644)
temporary.replace(proof_path)
print(json.dumps(proof, indent=2))
PY
}

# ---------------------------------------------------------------------------
# 1. Clean detached checkout (create or reuse)
# ---------------------------------------------------------------------------
log "commit $FULL (short $SHORT)"
if [[ -e "$WORKTREE" || -L "$WORKTREE" ]]; then
    [[ -d "$WORKTREE" ]] || die "worktree path exists but is not a directory: $WORKTREE"
    git -C "$WORKTREE" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        || die "existing path is not a git worktree: $WORKTREE"
    ACTUAL=$(git -C "$WORKTREE" rev-parse HEAD)
    [[ "$ACTUAL" == "$FULL" ]] \
        || die "existing worktree is at $ACTUAL, not $FULL; remove $WORKTREE or choose that commit"
    [[ -z "$(git -C "$WORKTREE" status --porcelain)" ]] \
        || die "existing worktree is dirty: $WORKTREE"
    WORKTREE_ACTION=reused
    log "reusing clean worktree $WORKTREE"
else
    git -C "$REPO" worktree add --detach "$WORKTREE" "$FULL"
    WORKTREE_ACTION=created
    log "created worktree $WORKTREE"
fi

[[ "$(git -C "$WORKTREE" rev-parse HEAD)" == "$FULL" ]] \
    || die "worktree HEAD does not match $FULL"
[[ "$(git -C "$WORKTREE" rev-parse --show-toplevel)" == "$WORKTREE" ]] \
    || die "path is not the root of its own worktree: $WORKTREE"
[[ -z "$(git -C "$WORKTREE" status --porcelain)" ]] \
    || die "worktree is not clean before build"
CLEAN_BEFORE=true

PRE_HASH=$(tracked_hash "$WORKTREE")
PRE_COUNT=$(git -C "$WORKTREE" ls-files | wc -l | tr -d ' ')
log "pre-build tracked hash $PRE_HASH ($PRE_COUNT files)"

# ---------------------------------------------------------------------------
# 2. Build with the pinned toolchain
# ---------------------------------------------------------------------------
TOOLCHAIN_VERSION=$("$SWIFT" --version | head -n 1)
TOOLCHAIN_TARGET=$("$SWIFT" --version | sed -n '2p')
[[ "$TOOLCHAIN_VERSION" == *"6.4.1"* ]] \
    || die "unexpected toolchain version: $TOOLCHAIN_VERSION"

STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
START_EPOCH=$(date +%s)
PRODUCTS=""
BINARY=""
BINARY_SHA=""
POST_HASH="$PRE_HASH"
BUILT_AT="$STARTED_AT"
FINISHED_AT="$STARTED_AT"
ELAPSED=0

log "building (log: $BUILD_LOG)"
set +e
(
    cd "$WORKTREE"
    env -i \
        PATH=/usr/local/bin:/usr/bin:/bin \
        HOME="$BUILD_HOME" \
        TMPDIR="$BUILD_TMP" \
        XDG_CACHE_HOME="$DEV/cache" \
        LANG=C.UTF-8 \
        LC_ALL=C.UTF-8 \
        "$SWIFT" build \
            -c release \
            --product RaftServer \
            --scratch-path "$SCRATCH" \
            --cache-path "$CACHE" \
            -j 8 \
            --force-resolved-versions
) >"$BUILD_LOG" 2>&1
BUILD_RC=$?
set -e

FINISHED_AT=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
BUILT_AT="$FINISHED_AT"
END_EPOCH=$(date +%s)
ELAPSED=$((END_EPOCH - START_EPOCH))

if [[ $BUILD_RC -ne 0 ]]; then
    POST_HASH=$(tracked_hash "$WORKTREE" 2>/dev/null || printf 'unavailable')
    tail -n 60 "$BUILD_LOG" >&2 || true
    write_proof "$BUILD_RC" false "$([[ -z "$(git -C "$WORKTREE" status --porcelain)" ]] && echo true || echo false)" "build command failed" >/dev/null
    die "swift build failed with exit code $BUILD_RC; see $BUILD_LOG"
fi
log "build finished in ${ELAPSED}s"

# ---------------------------------------------------------------------------
# 3. Locate the product and binary
# ---------------------------------------------------------------------------
PRODUCTS="$SCRATCH/out/Products/Release-linux-x86_64"
if [[ ! -f "$PRODUCTS/RaftServer" ]]; then
    CANDIDATE=$(find "$SCRATCH/out/Products" -maxdepth 2 -type f -name RaftServer 2>/dev/null | head -n 1 || true)
    [[ -n "$CANDIDATE" ]] || die "build succeeded but RaftServer is missing under $SCRATCH/out/Products"
    PRODUCTS=$(dirname "$CANDIDATE")
fi
BINARY="$PRODUCTS/RaftServer"
[[ -x "$BINARY" ]] || die "built binary is not executable: $BINARY"
BINARY_SHA=$(sha256sum "$BINARY" | awk '{print $1}')
[[ -d "$PRODUCTS/raft-server-swift_RaftHTTP.bundle" ]] \
    || die "resource bundle missing from build products: $PRODUCTS"
log "binary $BINARY ($BINARY_SHA)"

# ---------------------------------------------------------------------------
# 4. Verify tracked bytes were not changed by the build
# ---------------------------------------------------------------------------
POST_HASH=$(tracked_hash "$WORKTREE")
POST_STATUS=$(git -C "$WORKTREE" status --porcelain)
if [[ "$POST_HASH" != "$PRE_HASH" || -n "$POST_STATUS" ]]; then
    [[ -z "$POST_STATUS" ]] || printf '%s\n' "$POST_STATUS" >&2
    write_proof 1 false false "tracked bytes or worktree status changed during build" >/dev/null
    die "tracked bytes changed during build (before=$PRE_HASH after=$POST_HASH); see $PROOF"
fi
log "post-build tracked hash unchanged: $POST_HASH"

write_proof 0 true true "" >/dev/null
log "build proof: $PROOF"

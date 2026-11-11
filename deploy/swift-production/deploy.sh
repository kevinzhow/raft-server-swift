#!/usr/bin/env bash
# Full production deployment: build -> stage -> verify -> upgrade.
#
# Usage: deploy.sh <commit>       (or: make deploy COMMIT=<sha>)
#
# Every environment-specific value comes from local.env (see README.md). The
# upgrade step takes the quick production pg_dump backup, closes the gateway,
# swaps the release, verifies it and restores the previous gateway.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "$SCRIPT_DIR/env.sh"
swift_production_require DEV_ROOT SOURCE_REPO ARTIFACT_ROOT || exit 2

ARG=${1:?usage: deploy.sh <commit>}
FULL=$(swift_production_full_commit "$ARG")
SHORT=${FULL:0:8}
ARTIFACT="$ARTIFACT_ROOT/main-$SHORT-v1"

printf '== build %s\n' "$FULL"
"$SCRIPT_DIR/build-main-release.sh" "$FULL"

printf '== stage %s\n' "$FULL"
python3 "$SCRIPT_DIR/stage-main-release.py" "$FULL"

printf '== verify %s\n' "$FULL"
python3 "$SCRIPT_DIR/verify-staged-release.py" "$ARTIFACT/release"

printf '== upgrade %s\n' "$FULL"
"$SCRIPT_DIR/upgrade-main.sh" "$FULL"

printf 'DEPLOY OK %s\n' "$FULL"

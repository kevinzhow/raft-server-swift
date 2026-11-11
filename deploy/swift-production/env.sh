#!/usr/bin/env bash
# shellcheck shell=bash
#
# Load environment-specific deployment settings for the Swift production tools.
# Sourced by every deploy script; never executed directly.
#
#   source "$(dirname "$0")/env.sh"
#
# Settings come from local.env next to this file (git-ignored).  Existing
# process environment values are not overridden, so a caller can point at a
# rehearsal copy for one run.
#
# No secret, domain or IP address belongs in this file or in local.env.example.

SWIFT_PRODUCTION_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SWIFT_PRODUCTION_LOCAL_ENV="${SWIFT_PRODUCTION_ENV:-$SWIFT_PRODUCTION_DIR/local.env}"

if [[ -f "$SWIFT_PRODUCTION_LOCAL_ENV" ]]; then
    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" == \#* ]] && continue
        key="${key#export }"
        key="${key//[[:space:]]/}"
        [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
        value="${value%$'\r'}"
        if [[ "$value" == \"*\" || "$value" == \'*\' ]]; then
            value="${value:1:${#value}-2}"
        fi
        if [[ -z "${!key+x}" ]]; then
            printf -v "$key" '%s' "$value"
            export "${key?}"
        fi
    done <"$SWIFT_PRODUCTION_LOCAL_ENV"
fi

swift_production_require() {
    local key value
    for key in "$@"; do
        value="${!key:-}"
        if [[ -z "$value" ]]; then
            printf 'missing deployment setting: %s\n' "$key" >&2
            printf 'Create %s from local.env.example (see deploy/swift-production/README.md).\n' \
                "$SWIFT_PRODUCTION_LOCAL_ENV" >&2
            return 1
        fi
    done
}

swift_production_full_commit() {
    local argument=$1
    git -C "$SOURCE_REPO" rev-parse --verify "${argument}^{commit}"
}

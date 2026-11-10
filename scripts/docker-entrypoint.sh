#!/bin/sh
set -eu

fail() {
    printf 'Raft startup refused: %s\n' "$1" >&2
    exit 1
}

[ "${NODE_ENV:-}" = production ] || fail 'NODE_ENV must be production.'
jwt_secret=${JWT_SECRET:-}
[ "${#jwt_secret}" -ge 32 ] || fail 'JWT_SECRET must contain at least 32 characters; run scripts/init-deployment.sh.'
case "$jwt_secret" in
    *[![:space:]]*) ;;
    *) fail 'JWT_SECRET must not be blank.' ;;
esac
credential_key=${CREDENTIAL_ENCRYPTION_KEY:-}
[ "${#credential_key}" -eq 44 ] || fail 'CREDENTIAL_ENCRYPTION_KEY must be canonical base64 for an independent 32-byte key.'
canonical_key=$(printf '%s' "$credential_key" | base64 --decode 2>/dev/null | base64 | tr -d '\n')
key_bytes=$(printf '%s' "$credential_key" | base64 --decode 2>/dev/null | wc -c)
[ "$canonical_key" = "$credential_key" ] && [ "$key_bytes" -eq 32 ] || fail 'CREDENTIAL_ENCRYPTION_KEY must be canonical base64 for exactly 32 bytes.'
[ "$credential_key" != "$jwt_secret" ] || fail 'CREDENTIAL_ENCRYPTION_KEY must be independent from JWT_SECRET.'
case "${RAFT_RELEASE_SHA:-}" in
    *[!0-9a-fA-F]*|'') fail 'RAFT_RELEASE_SHA must be the actual 40-character commit SHA.' ;;
esac
[ "${#RAFT_RELEASE_SHA}" -eq 40 ] || fail 'RAFT_RELEASE_SHA must be the actual 40-character commit SHA.'
[ -n "${RAFT_BUILD_AT:-}" ] || fail 'RAFT_BUILD_AT is required.'
[ -n "${RAFT_RELEASE_BRANCH:-}" ] || fail 'RAFT_RELEASE_BRANCH is required.'
case "${SLOCK_E2E_AUTO_VERIFY_EMAIL:-0}" in
    0) ;;
    1) printf '%s\n' 'TRIAL ONLY: explicit registration email-verification bypass is enabled.' >&2 ;;
    *) fail 'E2E_AUTO_VERIFY_EMAIL must be 0 or 1.' ;;
esac
case "${DATABASE_URL:-}" in
    postgresql://*|postgres://*) ;;
    *) fail 'DATABASE_URL must configure PostgreSQL; in-memory deployment is not allowed by this package.' ;;
esac
case "${REDIS_URL:-}" in
    redis://*|rediss://*) ;;
    *) fail 'REDIS_URL is required.' ;;
esac
case "${1:-}" in
    --migrate-only|migrate)
        fail 'BLOCKER: --migrate-only is not wired into Main yet. Do not bypass migrations or claim business persistence.'
        ;;
esac
for mail_value in "${RESEND_API_KEY:-}" "${FROM_EMAIL:-}"; do
    case "$mail_value" in
        *[![:space:]]*) ;;
        *) fail 'Mail is not ready: configure real RESEND_API_KEY and FROM_EMAIL; email auto-verification is not a substitute.' ;;
    esac
done
printf '%s\n' 'BLOCKER: business PostgreSQL/Redis integration and restart recovery are still awaiting implementation and verification.' >&2
exec /app/RaftServer "$@"

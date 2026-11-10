#!/usr/bin/env bash
set -euo pipefail
umask 077

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -- "$script_dir/.." && pwd -P)"
env_path="$repo_root/.env"
fail() { printf 'Initialization refused: %s\n' "$1" >&2; exit 1; }

# Refuse symlinks as well as regular files; never rotate or print an existing secret.
if [[ -e "$env_path" || -L "$env_path" ]]; then
    fail '.env already exists; keep it and edit it deliberately. Nothing was overwritten.'
fi
release_sha="${RAFT_RELEASE_SHA:-}"
release_branch="${RAFT_RELEASE_BRANCH:-}"
git_root="$(git -C "$repo_root" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ "$git_root" == "$repo_root" ]]; then
    release_sha="${release_sha:-$(git -C "$repo_root" rev-parse HEAD)}"
    release_branch="${release_branch:-$(git -C "$repo_root" symbolic-ref --short -q HEAD || printf 'detached')}"
fi
[[ "$release_sha" =~ ^[0-9a-fA-F]{40}$ ]] || fail 'Set RAFT_RELEASE_SHA to the actual source commit SHA when using an archive without .git.'
[[ -n "$release_branch" ]] || fail 'Set RAFT_RELEASE_BRANCH to the actual source branch (or detached) when using an archive.'
build_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
random_secret() { od -An -N32 -tx1 /dev/urandom | tr -d ' \n'; }
jwt_secret="${JWT_SECRET:-}"
if [[ -z "$jwt_secret" ]]; then
    jwt_secret="$(random_secret)"
fi
[[ ${#jwt_secret} -ge 32 && "$jwt_secret" == *[![:space:]]* ]] || fail 'JWT_SECRET must contain at least 32 characters and must not be blank.'
postgres_password="${POSTGRES_PASSWORD:-$(random_secret)}"
redis_password="${REDIS_PASSWORD:-$(random_secret)}"
for password in "$postgres_password" "$redis_password"; do
    [[ "$password" =~ ^[A-Za-z0-9_-]{32,}$ ]] || fail 'Database passwords must contain at least 32 URL-safe characters (letters, digits, underscore, hyphen).'
done
credential_key="${CREDENTIAL_ENCRYPTION_KEY:-$(head -c 32 /dev/urandom | base64 | tr -d '\n')}"
[[ "$credential_key" =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]] || fail 'CREDENTIAL_ENCRYPTION_KEY must be canonical base64 for exactly 32 bytes.'
[[ "$credential_key" != "$jwt_secret" ]] || fail 'CREDENTIAL_ENCRYPTION_KEY must be independent from JWT_SECRET.'
attachment_key="${ATTACHMENT_ENCRYPTION_KEY:-$(head -c 32 /dev/urandom | base64 | tr -d '\n')}"
[[ "$attachment_key" =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]] || fail 'ATTACHMENT_ENCRYPTION_KEY must be canonical base64 for exactly 32 bytes.'
[[ "$attachment_key" != "$credential_key" && "$attachment_key" != "$jwt_secret" ]] || fail 'ATTACHMENT_ENCRYPTION_KEY must be independent from provider and JWT keys.'
attachment_provider="${ATTACHMENT_STORAGE_PROVIDER:-s3}"
[[ "$attachment_provider" == s3 ]] || fail 'Production attachments require the configured S3 backend.'
s3_bucket="${S3_BUCKET:-}"
s3_region="${S3_REGION:-auto}"
s3_prefix="${S3_KEY_PREFIX:-attachments/}"
s3_endpoint="${S3_ENDPOINT:-}"
s3_access="${S3_ACCESS_KEY_ID:-}"
s3_secret="${S3_SECRET_ACCESS_KEY:-}"
email_provider="${RAFT_EMAIL_PROVIDER:-resend}"
[[ "$email_provider" == resend || "$email_provider" == cloudflare ]] || fail 'RAFT_EMAIL_PROVIDER must be resend or cloudflare.'
resend_api_key="${RESEND_API_KEY:-}"
cloudflare_account_id="${CLOUDFLARE_ACCOUNT_ID:-}"
cloudflare_email_api_token="${CLOUDFLARE_EMAIL_API_TOKEN:-}"
[[ -z "$cloudflare_account_id" || "$cloudflare_account_id" =~ ^[0-9a-fA-F]{32}$ ]] || fail 'CLOUDFLARE_ACCOUNT_ID must be a 32-character hexadecimal account ID.'
from_email="${FROM_EMAIL:-}"
bind_address="${RAFT_BIND_ADDRESS:-127.0.0.1}"
http_port="${RAFT_HTTP_PORT:-8080}"
daemon_port="${RAFT_DAEMON_PORT:-8081}"
socket_port="${RAFT_SOCKET_PORT:-8082}"
for port in "$http_port" "$daemon_port" "$socket_port"; do
    [[ "$port" =~ ^[0-9]{1,5}$ ]] || fail 'Published ports must be integers between 1 and 65535.'
    (( 10#$port >= 1 && 10#$port <= 65535 )) || fail 'Published ports must be integers between 1 and 65535.'
done
server_url="${SERVER_URL:-https://raft.example.com}"
app_url="${APP_URL:-https://raft.example.com}"
auto_verify=0
[[ "${E2E_AUTO_VERIFY_EMAIL:-0}" == 0 ]] || fail 'Production initialization requires real email verification.'
for url in "$server_url" "$app_url"; do
    [[ "$url" == http://* || "$url" == https://* ]] || fail 'SERVER_URL and APP_URL must use http:// or https://.'
done
# Emit single-quoted Compose values. Reject quote/newline injection and interpolation.
for value in "$release_sha" "$release_branch" "$build_at" "$jwt_secret" "$credential_key" "$attachment_key" "$attachment_provider" "$s3_bucket" "$s3_region" "$s3_prefix" "$s3_endpoint" "$s3_access" "$s3_secret" "$resend_api_key" "$cloudflare_account_id" "$cloudflare_email_api_token" "$from_email" "$bind_address" "$server_url" "$app_url"; do
    case "$value" in
        *$'\n'*|*$'\r'*|*"'"*|*'\'*) fail 'Configuration values must not contain newlines, single quotes, or backslashes.' ;;
    esac
done
# noclobber also protects against another initializer creating .env after the check.
set -o noclobber
{
    printf '# Generated locally. Contains a secret; do not commit or distribute.\n'
    printf "JWT_SECRET='%s'\nPOSTGRES_PASSWORD='%s'\nREDIS_PASSWORD='%s'\n" "$jwt_secret" "$postgres_password" "$redis_password"
    printf "CREDENTIAL_ENCRYPTION_KEY='%s'\nRAFT_EMAIL_PROVIDER='%s'\nRESEND_API_KEY='%s'\nCLOUDFLARE_ACCOUNT_ID='%s'\nCLOUDFLARE_EMAIL_API_TOKEN='%s'\nFROM_EMAIL='%s'\n" "$credential_key" "$email_provider" "$resend_api_key" "$cloudflare_account_id" "$cloudflare_email_api_token" "$from_email"
    printf "ATTACHMENT_ENCRYPTION_KEY='%s'\nATTACHMENT_STORAGE_PROVIDER='%s'\nS3_BUCKET='%s'\nS3_REGION='%s'\nS3_KEY_PREFIX='%s'\nS3_ENDPOINT='%s'\nS3_ACCESS_KEY_ID='%s'\nS3_SECRET_ACCESS_KEY='%s'\n" "$attachment_key" "$attachment_provider" "$s3_bucket" "$s3_region" "$s3_prefix" "$s3_endpoint" "$s3_access" "$s3_secret"
    printf "RAFT_RELEASE_SHA='%s'\nRAFT_BUILD_AT='%s'\nRAFT_RELEASE_BRANCH='%s'\n" "$release_sha" "$build_at" "$release_branch"
    printf "RAFT_BIND_ADDRESS='%s'\nRAFT_HTTP_PORT='%s'\nRAFT_DAEMON_PORT='%s'\nRAFT_SOCKET_PORT='%s'\n" "$bind_address" "$http_port" "$daemon_port" "$socket_port"
    printf "SERVER_URL='%s'\nAPP_URL='%s'\nE2E_AUTO_VERIFY_EMAIL='%s'\n" "$server_url" "$app_url" "$auto_verify"
} > "$env_path"
chmod 600 "$env_path"
printf '%s\n' 'Created .env with permissions 600. Secret values were not printed.'
printf '%s\n' 'Review SERVER_URL and APP_URL, then configure email credentials/verified FROM_EMAIL and independent S3 credentials/bucket. Preserve both encryption keys outside the host.'
printf '%s\n' 'BLOCKER: real migrations, business persistence and restart recovery must pass before this package can be used for production data.'

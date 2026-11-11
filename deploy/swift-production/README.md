# Swift production release tools

Reproducible build, staging, verification and maintenance-ordered upgrade for
the production Swift Raft **Main** server. These are the out-of-repo release
tools moved into the repository so the procedure ships with the code.

## Configuration

All environment-specific values come from `local.env` next to these scripts.
That file is git-ignored and must never be committed. Copy the example and fill
in this machine's values:

```bash
cp deploy/swift-production/local.env.example deploy/swift-production/local.env
chmod 600 deploy/swift-production/local.env
```

| Key | Meaning |
| --- | --- |
| `DEV_ROOT` | Development root for builds, caches, temp files and artifacts |
| `SOURCE_REPO` | Clean checkout of the deploy trunk used to resolve commits |
| `SWIFT`, `SWIFT_SDK`, `JSC_LIBRARY` | Pinned toolchain and JavaScriptCore runtime |
| `PRODUCTION_ROOT`, `RELEASE_ROOT_PREFIX` | Production deployment root and release directory |
| `BASELINE_COMMIT` | Currently deployed commit used as the staging reference |
| `HOST_PLATFORM_PROOF` | Deployed host-platform allowlist proof |
| `ARTIFACT_ROOT` | Where build/stage/verify evidence is written |
| `LAUNCHER`, `SERVICE_UNIT` | Production `launch-verified.py` and user unit name |
| `GATEWAY_FILE`, `GATEWAY_CLOSED_PROFILE`, `GATEWAY_CONTAINER` | Gateway maintenance entry points |
| `GATEWAY_HEALTH_URL`, `PRIVATE_HEALTH_URL`, `PUBLIC_VERSION_URL` | Verification URLs (`PUBLIC_VERSION_URL` optional) |
| `POSTGRES_CONTAINER`, `PRODUCTION_DATABASE` | Backup and before/after row-state diff |

No credential, token, domain or IP address belongs in `local.env` itself beyond
the loopback/private values the operator chooses for this machine. The upgrade
reads the production database container's own `POSTGRES_USER` and the launcher
reads the production secret environment file; this tool never does.

## Commands

```bash
# One command: build -> stage -> verify -> upgrade.
make deploy COMMIT=<sha>

# Or step by step:
deploy/swift-production/build-main-release.sh <commit>
python3 deploy/swift-production/stage-main-release.py <commit>
python3 deploy/swift-production/verify-staged-release.py \
  "$ARTIFACT_ROOT/main-<short>-v1/release"
deploy/swift-production/upgrade-main.sh <full-commit>
```

`<commit>` may be a short SHA, full SHA or any revision accepted by
`git rev-parse --verify <commit>^{commit}`. The full SHA is the release
identity; the first 8 characters name the artifact directory.

## Properties

* **Clean build.** A detached worktree at `DEV_ROOT/build/main-<short>` is
  created (or reused only when detached at the same full commit and clean). The
  build uses SwiftPM scratch/cache paths under `DEV_ROOT`; tracked bytes are
  hashed before and after and must be identical, and the tree must be clean.
* **Runtime closure.** The binary, the pinned Swift runtime and the dynamically
  loaded JavaScriptCore library form the closure root. `readelf -dW` supplies
  `DT_NEEDED`/`SONAME`/`RUNPATH`; host-baseline libraries must match the deployed
  allowlist, everything else is packaged and inventoried.
* **Manifest location.** The manifest and launch spec live next to `release/`,
  not inside it: a manifest cannot inventory itself.
* **Verification environment.** The staged server starts with an explicit,
  non-inherited environment: `NODE_ENV=test`, throwaway JWT secret, free
  loopback ports, release identity, `LD_LIBRARY_PATH` to the staged runtime and
  no `DATABASE_URL`. No production secret file is read.
* **Upgrade order.** `pg_dump` backup → closed-all gateway → stop unit → swap
  manifest and launch spec (old copies kept) → start unit → private checks
  (health 200, version SHA, PID mappings) → restore the previous gateway →
  before/after durable-row diff. A failure prints rollback instructions.
* **No installation outside the production root.** The build/stage/verify steps
  write only under `ARTIFACT_ROOT` and `DEV_ROOT`; only `upgrade-main.sh`
  installs into the production release root and restarts the unit.

Logs go to `DEV_ROOT/tmp/release-tools/`.

## Relationship to the out-of-repo copies

`/mnt/data/raft-swift-development/release-tools/` is kept until this directory
is merged into the deploy trunk. The scripts are the same procedure; this copy
reads `local.env` instead of hardcoded paths.

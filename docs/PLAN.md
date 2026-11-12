# Delivery plan and current status

Current status only. Fixed defects live in their commits; deliberate differences
in [DEVIATIONS.md](DEVIATIONS.md), [PARITY.tsv](PARITY.tsv) and
[ARCHITECTURE.md](ARCHITECTURE.md).

## Objective

Deliver the Swift reimplementation of `raft-source` tag `v1.21.23-source.1`:
HTTP/socket contract, fixed Web/CLI consumers, PostgreSQL persistence, the
daemon/Computer path and deployment. Parity tests evidence the contract, not a
complete user path.

## Delivered runtime baseline

Production runs `ab04cacf` from the real upgrade off `b23b2516`; `/health` and
`/api/version` answer 200 at `1.21.23`/`ab04cacf`. The runtime remains
`ab04cacf8e0cb45252eb379f08bcc7274242d11d` through this documentation round;
the release selector stays immutable at `ab04`. The b23 release, its
175,278-byte dump (checksum `b6599ade…`) and the 223,640-byte public backup
remain rollback; gateway config `1b0fd817…` and manifest `c4ebd84a…` are pinned.

The qualified source landed by no-ff merge
`d244fe30d8840f56fe679c37e229538069179964`; later documentation commits leave
`Sources/` and `Tests/` unchanged. `ab04` carries Engine.IO v4 polling and
ordered responses; its commits remain the behavior record.

## ab04 final evidence

This qualifies `ab04` only, not the current round.

- **Gate and persistence.** All five gate steps PASS with 3,250 tests in 6
  shards and empty `failures[]`; serial `make test-pg` PASS with 49 cases.
- **Deployment and acceptance.** Build/stage/verify, `pg_dump`, upgrade and
  restore ended `UPGRADE OK`/`DEPLOY OK`; 14-check acceptance passed 14 PASS,
  0 FAIL/BLOCKED/SKIP in 204.7 s including attachment, restart and keep-session.
- **Web and soak.** Five authenticated pages returned HTTP 200 with only the
  known D5 404; origin/public reports each passed 36/36; the 600 s monitor
  finalized `HEALTHY` with 10 rounds and zero monitored regressions.
- **State and cleanup.** Durable-state review found lifecycle writes, not
  corruption, with owner data and business lists intact; cleanup executed the
  18 READY objects with 0 failures, and `B-ccf41374` remains the one KEEP.

## Route and module limits

The original agreed limits remain binding: route baseline C0 has 644 upstream
versus 611 Swift routes, 583 exact, 1 variant, 57 raw missing (5 false
positives, 52 exclusions) and 27 extra, with 0 reachable Class C.
`PARITY.tsv` has 406 modules, 230 mapped. These are explicit limits, not full
parity, and this round does not widen them.

## Current architecture optimization round

The user cancelled the Computer setup and authorized a new architecture
optimization round; the user's separate Computer home is not touched. The Lead
created `integrate-architecture-1` from trunk `03132e6b`; it is clean and no
source slice is integrated yet. Runtime is still `ab04`.

Active slices, all unshipped:

- **Task 13, snapshot encoding.** In implementation on `arch-snapshot-encoding`
  (test-pg worktree), not committed or integrated. Design counts are 28 encodes
  per transaction, 42 effects-only and 14 with the proposed canonical
  post-wiring committed cache. The implementation seeds the comparison base
  from wired live owners at activation and advances it only on confirmed
  commit; effects-only commits reuse pending snapshots.
- **Task 14, production Auth/OAuth/Integrations composition.** In
  implementation on `arch-production-composition` in the auth-identities
  worktree, not committed or integrated. The proposed same-owner
  `ProductionFeatureGraph` supplies the Auth, OAuth and Integrations mounts;
  planned focused coverage includes `/api/auth/me`, `/api/auth/providers` and
  `/api/integrations/clients` from the explicit graph.
- **Task 15, attachment slow-I/O short-transaction design.** Read-only design
  still; no attachment source, test or deployment change.

The 28/42/14 counts are design measurements, not shipped performance or
acceptance claims.

## Completion criteria

Each accepted source slice passes its focused tests. The Lead then runs
`make gate` on the integration commit, followed by serial `make test-pg`;
integration uses real merge commits. This round is complete only when every
accepted slice is integrated into `integrate-architecture-1`; gate and test-pg
pass on that commit; deployment takes the quick `pg_dump` and keeps rollback
intact; and actual use-case API checks plus the authenticated Web are verified
on the affected boundaries. Evidence must be current, with no domain, IP or
credential in Git. Until then no performance or new acceptance result is claimed.

## Evidence

The round baseline root
`/mnt/data/raft-swift-development/tmp/architecture-optimization-20261112/`
holds `baseline-runtime.json` (health 200, version `ab04`, both units active,
integration clean) and `architecture-baseline.log` (22 PASS); these baseline
the round only. The ab04 final root
`/mnt/data/raft-swift-development/tmp/qualification-engineio-v4/` and cleanup
root `/mnt/data/raft-swift-development/tmp/stage-cleanup-execution-ab04cacf/`
remain historical evidence. All artifacts stay on the data disk; domains, IPs
and credentials stay out of Git.

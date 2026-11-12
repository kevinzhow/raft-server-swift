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
created `integrate-architecture-1` from trunk `03132e6b`; all source slices are
reviewed and integrated. Documentation sync precedes the frozen-candidate full
gate and serial PG gate. Runtime is still `ab04`; no candidate is deployed.

Active slices, all unshipped:

- **Task 13, snapshot encoding.** Reviewed `9762745e` integrated. Actual real-PG
  proof measures 14 pending encodes per transaction versus the old 28/42 paths;
  post-wiring reads preserve revisions, thrown operations retain durable edits,
  rollback/effects/restart and failed-CAS fail-closed behavior pass. The targeted
  PG run also passes both existing cancellation/supervisor fail-closed cases.
  Canonical bytes seed from wired owners; only confirmed commits advance them.
- **Task 14, production Auth/OAuth/Integrations composition.** Reviewed commits
  `37ce070d` and `363b714e` integrated with the same retained owners. The actual
  mounts consume `ProductionFeatureGraph`; 2 targeted graph tests, 71 related
  regressions and the later 19-test OAuth run passed (overlapping runs, not a
  unique-test total). OAuth proof includes scoped discovery, tenant isolation,
  exact issuer/endpoint/cache fields and live deployment updates.
- **Task 15/17, attachment I/O.** Reviewed `44ff3bb0` and `da5993cf` integrated.
  Selected raw UUID bodies/previews and human upload use short committed phases;
  legacy paths stay unchanged. All 9 targeted real-PG cases pass: independent
  writes while get/put blocks, post-I/O revocation/binding refusal, cleanup,
  shielded cancellation, lost-writer retention, internal legacy upload, non-UUID
  errors and a full transfer budget. Lost-writer evidence is a post-callback
  connection failure, not a successful COMMIT with a lost acknowledgement.
- **Task 19, transfer preparation budget.** Reviewed `df5fd5cc` integrated and
  wired by Task 17; 6 focused tests pass, including cancellation/grant stress.
  Four preparations may run while unrelated business writes remain independent.
  The budget does not cap slow-client response buffers or the overall heap.
- **Web baseline.** Fresh ab04 capture: 5/5 authenticated pages at HTTP 200,
  zero runtime exceptions, only the accepted D5 feedback 404; screenshots reviewed.

The 28/42/14 values are codec-call counts verified by targeted real-PG tests,
not shipped end-to-end latency/throughput measurements.

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

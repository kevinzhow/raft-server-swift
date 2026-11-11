# Delivery plan and current status

Current status only. Fixed defects live in their commits; deliberate differences
in [DEVIATIONS.md](DEVIATIONS.md), [PARITY.tsv](PARITY.tsv) and
[ARCHITECTURE.md](ARCHITECTURE.md).

## Objective

Deliver the Swift reimplementation of `raft-source` tag `v1.21.23-source.1`:
HTTP/socket contract, fixed Web/CLI consumers, PostgreSQL persistence, the
daemon/Computer path and deployment. Parity tests evidence the contract, not a
complete user path.

## Runtime and frozen candidate

Production still runs `b23b2516`
(`b23b251667a3740d4e25fc4ed9f161ad959e3145`), merged to trunk as
`07a9bce02be669253ae685623230f0bdb78477c4`; its full tree equals candidate
`232f219230025297a9920dd58b64145b2f422e71`. The previous `db2ebc71` release and
dump remain for rollback.

Frozen candidate `ab04cacf` (`ab04cacf8e0cb45252eb379f08bcc7274242d11d`) is
neither deployed nor accepted. Its full tree is
`92bfd00849a2fbc34f3c06fb52836b7260fa32da`, Sources
`0f169a0def324ab5b8be32a6ee735f4fb23a31c0`, Tests
`a016d6ff840922f8061a093226d3a8bb9d982271`. Qualification is in flight, so b23
remains the only runtime claim.

b23 is normally usable: acceptance 14/14, official Web/CLI consumers use its
WebSocket path, and the authenticated pages and full-static profile are healthy.
It serves fixed-WebSocket transport only; upstream polling and upgrade are a
real gap at that commit, not a gateway regression or a D2 split.

## Retained b23 qualification

- **Gate.** `make gate` passed all five steps on b23: 3,209 tests in 6 shards,
  one isolated Kimi known-gap retry passed, `failures[]` empty; E2E, smoke,
  architecture and parity-check passed. Logs:
  `/mnt/data/raft-swift-development/batch/integrate-4/.build/gate-logs/20261111T165554Z/`.
- **Persistence.** Full `make test-pg` passed: 49 gated startup cases, 0 failed;
  database-health and infrastructure checks passed. Logs:
  `/mnt/data/raft-swift-development/batch/integrate-4/.build/test-pg/20261111T170912Z/`.
- **Artifact.** Release build and staged verification passed; staging, verify,
  upgrade and deploy installed b23.

These facts qualify b23 only; ab04 needs its own full qualification.

## Retained b23 actual acceptance

The real 14-check acceptance finished 14 PASS, 0 FAIL, 0 BLOCKED, 0 SKIP in
217.6 s. The hidden nonce existed only in the uploaded bytes; the recipient read it in
two consecutive real replies (seq 114, 116). Main restart produced reply 121;
Computer restart replies 123 and 125; keep-session `mode=restart` returned 202
with replies 127 and 129. Owner login and refresh passed, all 14 durable rows
stayed unchanged, and DM, mention, task, attachment preview and thread passed.
Proof: `/mnt/data/raft-swift-development/tmp/qualification-b23b2516/acceptance-full.json`
and driver log. The browser pass is not a persistence test for a new UI account.

## Retained b23 Web, full-static and canary

Five authenticated pages are healthy; only D5 Hands-feedback 404 remains. The
10-minute canary completed exit 0: 10 rounds x 5 pages = 50 authenticated
checks, `alerts[]` empty, `changes` 0 every round, HEALTHY, started 17:43:43Z
and last captured 17:52:54Z after the 600 s wait.

Full-static remains loaded at profile
`1b0fd817da7515a55b8c33ce527f3f9e5b1d50c41fb5c7474f69f3a381b7ee1f`; the
publication rehearsal covered closed-all and restricted rollback, then applied
it with the same Main PID and inode. Live facts: `/api/version` 200 with SHA
b23, main health 200, both units active. Proof:
`/mnt/data/raft-swift-development/tmp/qualification-b23b2516/browser-canary/monitor-report.json`
and `.../publication-r2/publication.json`. This canary qualifies b23 only.

## Frozen candidate ab04

`ab04cacf` merges the completed Engine.IO transport work, no longer missing or
in progress, frozen for unified qualification. The source slices are:

- Engine.IO v4 polling transport, auth, hub and default client.
- Content-Length and chunked framing, legal and illegal framing, and the
  original negative-Range fatal defect.
- Late GET, close and final Probe cleanup; repeated probe pings answered with
  probe pongs.
- Per-request response slots that remove the synchronous no-op and pipeline
  multi-SID failure for ordered HTTP responses, releasing all pending work on
  disconnect; header overflow answers 431 like Node.

Focused proof at source tip `9eeb13b3`: 75 tests PASS (68 realtime in 6 suites,
7 active auth/publication in 2); architecture 22 and parity-check PASS; official
client default, polling, WebSocket and invalid token pass. That proves the
source commit, not the unified ab04 gate; no new deliberate difference was
added, and D2 only separates listeners. Fixed WebSocket client transport is not
server parity.

## Qualification in flight

On frozen ab04 the unified `make gate` has started, followed by `make test-pg`
serially in the same worktree; it has produced no result, so no gate or
PostgreSQL pass is claimed. A release build runs in a separate immutable
worktree. Both avoid production writes; no Source writers are active, the
integration worktree and HEAD are untouched, and this merge waits for the Lead.

## New qualification record

`/mnt/data/raft-swift-development/tmp/qualification-engineio-v4/candidate.json`
records candidate `ab04cacf`, the hashes above, baseline b23, `frozen: true`,
`worktreeClean: true`, and qualification pending the full gate then serial
PostgreSQL. A fresh b23 baseline captured five authenticated screenshots with
only D5 feedback 404. The 36-case HTTP public helper has a prepared 6/6 Node
reference but has not run against production; neither item accepts the release.

## Next steps

1. Finish `make gate`, then the serial `make test-pg`, on frozen ab04; record
   logs and any isolated retry honestly.
2. Build and verify the artifact, take the pre-deploy backup, deploy ab04 and
   preserve the previous release and dump for rollback.
3. On production, repeat the actual 14-check acceptance, the authenticated Web
   pass, the 36-case HTTP origin plus public check and the 10-minute monitor.
4. Run guarded stage cleanup, then publish the final current-state plan and
   acceptance record.

## Cleanup and route proof

Stage cleanup has run zero stop/delete operations. The earlier read-only
inventory recorded 19 entries as 18 READY and 1 KEEP (a Bccf missing artifact
copy); that is not an actual deletion count. The hardened b23 executor's 42
self-tests covered non-real cleanup only, and the private ab04 retarget is being
prepared. No final canary file exists, so no cleanup is claimed.

Port 28443 is `PROVEN_UNUSED`: live connector configuration version 9 has 8
ingress rules and zero references, observed read-only; recheck before cleanup.
Cleanup and final closure wait for the new candidate and the Lead's record.
Route baseline C0: 644 upstream versus 611 Swift, 583 exact, 1 variant, 57 raw
missing (5 false positives, 52 exclusions), 27 extra; 0 reachable Class C.
`PARITY.tsv`: 406 modules, 230 mapped; explicit limits, not full coverage.

## Completion conditions and limits

- Gate and PostgreSQL pass on the deployed commit; the 14-check acceptance is
  14 PASS, 0 FAIL/BLOCKED/SKIP with hidden-nonce, restart and Web proof (met
  for b23; required again for ab04).
- Audited Web pages have no console/HTTP errors except documented exclusions,
  and the official Computer/Codex path survives restart (met for b23; required
  again for ab04).
- Engine.IO 4 polling and WebSocket upgrade match upstream observable
  behavior; fixed WebSocket client transport is not server parity.
- Full-static is published, the 10-minute canary passes and rollback is
  rehearsed on the same release (met for b23; required again for ab04).
- Remaining differences are in `docs/DEVIATIONS.md`; no undocumented
  deviation, widened exclusion or route match is claimed as parity.

## Evidence

Evidence stays on the data disk under
`/mnt/data/raft-swift-development/tmp/qualification-b23b2516/` and
`/mnt/data/raft-swift-development/tmp/qualification-engineio-v4/` (release,
deployment, acceptance and browser logs), the gate and PostgreSQL logs above,
and the upgrade provision directory. Quote paths, not logs; keep the owner
environment, data disk and credentials intact.

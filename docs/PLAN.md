# Delivery plan and current status

Current status only. Fixed defects live in their commits; deliberate differences
in [DEVIATIONS.md](DEVIATIONS.md), [PARITY.tsv](PARITY.tsv) and [ARCHITECTURE.md](ARCHITECTURE.md).

## Objective

Deliver the Swift reimplementation of `raft-source` tag `v1.21.23-source.1`:
HTTP/socket contract, fixed Web/CLI consumers, PostgreSQL persistence, the
daemon/Computer path and deployment. Parity tests evidence the contract, not a
complete user path.

## Current stage

Production runs `b23b251667a3740d4e25fc4ed9f161ad959e3145` (`b23b2516`), merged
to trunk as `07a9bce02be669253ae685623230f0bdb78477c4`; the full tree equals
candidate `232f219230025297a9920dd58b64145b2f422e71`. The previous `db2ebc71`
release and dump remain for rollback; the upgrade kept a 143,283-byte backup.

b23 is normally usable: acceptance is 14/14, official Web/CLI consumers use its
WebSocket path, and the authenticated pages and full-static profile are healthy.
The source still lacks upstream Engine.IO polling/upgrade, an existing gap, not
a new gateway regression; closing it needs the new candidate and qualification.

## Release qualification

- **Gate.** `make gate` passed all five steps on b23: 3,209 tests in 6 shards
  (build 221.7 s, tests 377.3 s, total 601.6 s), one isolated Kimi known-gap
  retry passed, `failures[]` empty; E2E, smoke, architecture and parity-check
  passed. Logs: `/mnt/data/raft-swift-development/batch/integrate-4/.build/gate-logs/20261111T165554Z/`.
- **Persistence.** Full `make test-pg` passed: 49 gated startup cases, 0 failed;
  database-health and infrastructure check passed. Logs:
  `/mnt/data/raft-swift-development/batch/integrate-4/.build/test-pg/20261111T170912Z/`.
- **Artifact.** Release build 391 s; tracked-file hash unchanged
  `6f38abe06430cffe99e0aba9235b8288a78a95382038951e8b580892fbdf86c1` (1,690 files);
  binary `7eae69e694613b38ab987ed3d5123819c546d6bdd3c6d89f8b30cec694314cb1`;
  staging, verify, upgrade, deploy installed b23.

## Actual acceptance

The real 14-check acceptance finished 14 PASS, 0 FAIL, 0 BLOCKED, 0 SKIP in
217.6 s. The hidden nonce existed only in the uploaded bytes; Cindy read it in
two consecutive real replies (seq 114, 116). Main restart produced reply 121;
Computer restart replies 123 and 125; keep-session `mode=restart` returned 202
with replies 127 and 129. Owner login and refresh passed, all 14 durable rows
stayed unchanged, and DM, mention, task, attachment preview and thread passed.
Proof: `/mnt/data/raft-swift-development/tmp/qualification-b23b2516/acceptance-full.json`
and driver log; the browser pass is not a persistence test for a new UI account.

## Web, full-static and canary

Five authenticated pages are healthy; only the known D5 Hands-feedback 404
remains. On b23 the 10-minute browser canary completed with exit 0 (job
`bash-60b2`, received by the Lead): 10 rounds × 5 pages = 50 authenticated page
checks, `alerts[]` empty, `changes` 0 every round, HEALTHY. It started
17:43:43Z and last captured 17:52:54Z; the script waits 600 s before exit, so
the last capture is not a short run. Post-canary live facts on b23: public
`/api/version` 200 with SHA b23, main health 200, both units active, full-static
hash `1b0fd817da7515a55b8c33ce527f3f9e5b1d50c41fb5c7474f69f3a381b7ee1f`.
Proof: `/mnt/data/raft-swift-development/tmp/qualification-b23b2516/browser-canary/monitor-report.json`
and `post-canary-live-facts.json`.

Full-static is loaded; the corrected publication run rehearsed closed-all and
restricted rollback, then applied the full profile with the same Main PID and a
preserved inode. Profile SHA-256 `1b0fd817da7515a55b8c33ce527f3f9e5b1d50c41fb5c7474f69f3a381b7ee1f`;
the first rehearsal stopped only because a restricted local entry expected 200,
and the restricted profile restored automatically, not an application failure. Proof:
`/mnt/data/raft-swift-development/tmp/qualification-b23b2516/publication-r2/publication.json`.

This canary qualifies b23 only; the polling/upgrade candidate still needs its
own full gate, persistence, deploy, 14-check acceptance, Web pass and canary.

## Qualified fixes in b23

The source fixes qualified in b23 are merged, each with focused/affected tests
plus the full gate and PostgreSQL qualification. The 14-check acceptance proves
attachment, Main restart and continuous DM recovery specifically, not per-case
coverage of every contract.

- A completed Main turn clears the recoverable restart fence and releases
  queued DMs; unacknowledged or ambiguous writes remain manual.
- DM task claim converts a plain message, keeps the host unchanged, and publishes
  only the task event with durable PostgreSQL state.
- Exact canonical peer/assignee matching, 8-hex and typed DM grammar. A raw
  retained assistant owner binding restricts posting regardless of
  `identity_borrowing` or membership; `liveOwner` still borrows, no new flag.
- History, search, action card, modern/legacy send and DM thread list share
  canonical DM references; one escaping path defines the DM wire.

No new deliberate difference was added; D12 still excludes the built-in app conversation.

## Open work

Polling is a real existing source gap, not a D2 listener split or intentional deviation.
Upstream `socket/index.ts` lines 77-83 call `newServer` without `transports`, so
the default is polling plus WebSocket. The Swift NIO listener serves WebSocket
only and answers polling with 400 and an empty body. The Web client's fixed WS
transport is not server parity; D2 only separates listeners, and the 75-worker
private verified helper (31/31) proves only current WS, not upstream polling.

A candidate is being prepared on `fix-engineio-polling` in the warm
`restart-recovery` worktree (DeepSeek 0564) to implement Engine.IO 4 GET/POST
long-poll, auth, frames, ping and upgrade; the live deployment is unchanged. The
postload helper expected no `sha256-` ETag prefix and flagged two traversal
differences; those are QA-script-only. The real body hash, strong ETag, 304
response, pinned SPA hash, no-secret response and edge 400 are correct; do not
add this to `DEVIATIONS.md` or use D2 to exclude polling.

1. Land the polling/upgrade fix on a verified candidate.
2. Run one full gate and PostgreSQL serial gate, take the backup, deploy it, and
   repeat the real 14-check acceptance, authenticated Web pass and public canary.
3. Recheck the route proof, then run the planned stage cleanup.

## Cleanup and route proof

Stage cleanup has not run; stage remains at zero stop/delete and only cleanup
executor `6d7` prepared privately. No cleanup is claimed. Port 28443 is
`PROVEN_UNUSED`: live connector configuration version 9 has 8 ingress rules and
zero references to it, observed read-only; recheck before cleanup because it can
change. The b23 canary alone does not authorize cleanup or a final all-parity
closure; both wait for the polling/upgrade candidate and the Lead's final record.

## Completion, limits and evidence

- Gate and PostgreSQL pass on the deployed commit; the 14-check acceptance
  records 14 PASS, 0 FAIL/BLOCKED/SKIP with hidden-nonce, restart and Web proof
  (met for b23; required again for the polling/upgrade candidate).
- Audited Web pages have no console/HTTP errors except documented exclusions,
  and the official Computer/Codex path survives restart and stop/start (met for
  b23; required again).
- Engine.IO 4 polling and WebSocket upgrade match upstream observable behavior;
  fixed WS client transport is not server parity.
- Full-static is published, the 10-minute public browser canary passes and
  rollback is rehearsed on the same release (publication/rollback met for b23;
  the final release still needs its canary).
- Remaining differences are in `docs/DEVIATIONS.md`; no undocumented deviation,
  test mapping, test count or route match is claimed as parity.
- Route baseline C0: 644 upstream versus 611 Swift, 583 exact, 1 variant, 57 raw
  missing (5 false positives, 52 exclusions), 27 extra; 0 reachable Class C.
  `PARITY.tsv`: 406 modules, 230 mapped; explicit limits, not full upstream parity.

Evidence stays on the data disk under
`/mnt/data/raft-swift-development/tmp/qualification-b23b2516/` (release,
deployment, acceptance and browser logs), the logs above and the upgrade
provision directory. Quote paths, not logs; keep the owner environment, data
disk and credentials intact.

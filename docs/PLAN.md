# Delivery plan and current status

Current status only. Fixed defects live in their commits; deliberate differences
in [DEVIATIONS.md](DEVIATIONS.md), the route ledger in [PARITY.tsv](PARITY.tsv)
and the guardrails in [ARCHITECTURE.md](ARCHITECTURE.md). No secret belongs here.

## Objective

Finish the production delivery of the Swift reimplementation of `raft-source`
tag `v1.21.23-source.1`: the published HTTP/socket contract, the fixed Web and
CLI consumers, real PostgreSQL persistence, the daemon/Computer path and the
existing deployment. Parity tests evidence the contract, not a complete user path.

## Current stage

Production still runs `db2ebc71` (`db2ebc71013db8c6cc89a84e68d59c43ecbe5bcb`),
the unchanged release artifact. That artifact is immutable and tested; its
source was merged to trunk by `3be7bcc` (tree `fd58f0aa`), and a docs-only trunk
commit followed at `34be1afe`. The release selector is `db2ebc71`, not a merge SHA.

The process worktree started clean at `f5c1d94`. This is a docs-only milestone.
`integrate-4` was merged with `--no-ff`; the merge commit is `3c86db23` and it
brings `bbd3e73` (Core/Main), `0c09992+0736ce0d` (Task), `16865709` (DM) and
the prior docs, ending at `008a1480`. This commit changes only `docs/PLAN.md`:
no Source, Tests, scripts, PARITY, DEVIATIONS or root files.

The integration is UNRELEASED. Its source fixes are not fully qualified: the
full gate and full persistence gate below ran on the `db2ebc71` candidate, not
on `008a1480`.

The real 14-check acceptance on `db2ebc71` finished 22:55 JST with 12 PASS,
2 FAIL, 0 blocked/skipped, 497.0 s. `attachment-read` and `restart-main` failed
with no agent reply within 180 s. The read-only sweep left all 14 durable root
rows unchanged. Main is healthy; the owner account and Codex login were not reset.

## Confirmed causes

- **Main restart.** The accepted seq 95 turn was still running when Main
  restarted. The same Daemon reconnected and reported ready, which correctly
  kept the fence. The turn's completion at 13:50:25Z (22:50:25 JST) cleared
  `inFlight` but not the fence or the release hold, so seq 97 was not delivered
  until the later Computer restart.
- **Attachment read.** The hidden 33-byte nonce file downloads normally over
  GET; the file path is healthy. The failure is the agent reply path, not the
  download, and no harness change was made.
- **Task claim.** A mandatory claim to `dm:@owner` answered 400, and claim
  message conversion was missing. `0c09992` plus `0736ce0d`, merged by
  `e9fa8a1f`, add canonical DM names and typed errors, the writable claim gate,
  source-message conversion and published events. 88 affected tests and the
  architecture check pass.
- **DM canonical names.** `16865709`, merged by `008a1480`, resolves send,
  history and search peers by exact canonical handles only. Typed kind errors,
  read-only receipt handling and owner restrictions are preserved. Seven tests
  went red then green, with affected-suite proof.
- **Main recovery.** `bbd3e73`, merged by `42f435dc`, releases the queued human
  message only on a committed completion with no unsettled writes. It passed
  25 recovery units, 87 affected tests and 3 real-PostgreSQL restart cases.
- **Same-class TaskRoot fixes.** Two pending worker fixes close the remaining
  class without source overlap with the merge. `e6b5a1d8` on `agent-contract`
  closes the Task family writable and owned-assistant paths, typed conflict and
  thread refs, and a dedicated real-PG claim, conversion and durable outbox.
  `67886e61` on `dm-list` closes known-history and reminder prefixes, thread
  suffixes, the `~kind` projection, search DM targets and malformed sender
  grammar. Neither is in `008a1480`; neither deployed a new fix.

## Qualified evidence and limits

- **Full gate.** PASS on `db2ebc71` only: 3,161 tests in 6 shards, 561.0 s
  (build 181.1 s, test 372.3 s), one isolated retry for the pre-existing Kimi
  known-gap test. E2E 48 s, smoke 25 s, architecture 22/0, parity-check pass.
  Logs: `/mnt/data/raft-swift-development/batch/integrate-4/.build/gate-logs/20261111T131259Z/`.
- **Persistence gate.** PASS on `db2ebc71` only: 47 gated startup tests,
  database-health 4/4, infrastructure checks. Logs:
  `/mnt/data/raft-swift-development/tmp/qualification-db2ebc71/pg-serial/`.
- **New Main proof.** The real-PostgreSQL restart cases above prove the new
  Main fence behavior, but they are not the full-candidate persistence gate.
- **G1.** Real-PG proof only: normal HTTP login and refresh 200 and the empty
  `[]` server collection before membership. It does not claim a fresh
  production UI account was created.
- **G3.** After the 14 checks, five authenticated browser pages showed zero
  console changes against the baseline; Cindy's icon was online and the owner
  name correct. Only the known D5 `/api/product-feedback/tickets` 404 remains.
  Proof: `/mnt/data/raft-swift-development/tmp/qualification-db2ebc71/browser-canary/round-report.json`
  and `round-1-members.png`.
- **Route audit.** 644 upstream / 611 Swift registrations: 583 exact, 1
  parameter-variant, 57 raw missing, 27 raw extra. The 57 are 5 Class A false
  positives, 15 Class B and 37 Class B* documented exclusions, 0 Class C
  reachable missing; all 52 intentional exclusions are in DEVIATIONS. This is
  the baseline C0 audit, not a semantic-completeness claim.
- **Full-static.** The private candidate has 41 structural assertions and is
  NOT applied. The live gateway remains restricted (Caddy digest `6ae598ed...`);
  the prepared full-static Caddyfile has SHA-256 `1b0fd817...`, symbolic fields
  and no sensitive URLs in Git.
- **Cleanup.** The stage cleanup is still a read-only plan review. No deletion
  has run and no removed count is claimed.
- **Known gap.** The built-in app conversation remains absent and documented
  under D12; no new deviation was adjudicated.

## Next steps

1. Let the two pending TaskRoot fixes land on their area branches; review the
   dedicated real-PG claim/conversion/outbox and DM history/reminder coverage.
2. Freeze the final candidate after both land, then run ONE full gate and the
   full persistence gate sequentially in the same worktree.
3. Build, stage, verify, take the quick backup and upgrade that candidate;
   rerun the actual 14 checks plus a fresh authenticated Web pass.
4. Run the full-static canary only if every earlier step passes, then clean the
   stage. Keep rollback available.
5. Recheck G3 on the new release after all 14 checks; the `db2ebc71` visual
   presence result can be closed at that scope.

## Completion conditions

Complete only when all of these hold on one qualified release:

- `make gate` and `make test-pg` pass on the deployed commit.
- The 14-check actual acceptance passes (or records reviewed skips), including
  the hidden-file attachment read and all restart paths.
- The deployed Web path has no console errors on audited pages except DEVIATIONS.
- The official Computer/Codex path survives Main restart and Computer stop/start
  without manual intervention.
- Full-static is intentionally published, the canary passes, and rollback is
  rehearsed on the same release.
- Remaining differences are in `docs/DEVIATIONS.md`; no undocumented deviation,
  test mapping, test count or route match is claimed as parity.

## Evidence and reporting

Evidence stays on the data disk under
`/mnt/data/raft-swift-development/tmp/qualification-db2ebc71/` (gate, PG and
acceptance logs, browser baseline and canary, original pending recovery), under
the gate leaf above and under the upgrade provision directory. Quote paths
instead of pasting logs. Swift test counts are not upstream coverage; a locked
ledger or unit test is not the production path. Keep the owner environment,
data disk and credentials intact.

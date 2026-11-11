# Delivery plan and current status

Current status only. Fixed defects live in their commits; deliberate differences
in [DEVIATIONS.md](DEVIATIONS.md), [PARITY.tsv](PARITY.tsv) and
[ARCHITECTURE.md](ARCHITECTURE.md).

## Objective

Deliver the Swift reimplementation of `raft-source` tag `v1.21.23-source.1`:
HTTP/socket contract, fixed Web/CLI consumers, PostgreSQL persistence, the
daemon/Computer path and deployment. Parity tests evidence the contract, not a
complete user path.

## Delivered runtime

Production runs `ab04cacf` from the real upgrade off `b23b2516`; `/health` and
`/api/version` answer 200 at `1.21.23`/`ab04cacf`. The release selector stays
immutable at `ab04`; documentation commits never become the runtime. The b23
release, its 175,278-byte dump (checksum `b6599ade…`) and the 223,640-byte public
backup remain for rollback; gateway config `1b0fd817…` and manifest `c4ebd84a…`
are pinned.

The qualified source was landed by the no-ff merge
`d244fe30d8840f56fe679c37e229538069179964`; later documentation commits leave
`Sources/` and `Tests/` unchanged.

## Durable-state clearance

The original comparison kept `post-deploy-verification.json` `passed: false`;
reviewed `post-deploy-reviewed.json` records `passed: true` as expected lifecycle
writes, not corruption; 11 of 14 payloads were identical. `agents_runtime`
re-encoded Set-backed values, added a connection epoch and one synthetic notice
(not a messages row) plus dispatch; `auth_profiles` had two owner-family refresh
rotations; `machines_and_computers` changed detection metadata, per-kind model
`updatedAt` and status-version increments (the two presence transitions).

Owner, password hash, roles, secrets, rights, sessions and durable lists stayed
unchanged; no message, task, OAuth, server or domain was lost. Raw payloads are
not claimed identical during the upgrade.

## Qualified candidate

`ab04cacf` is fully qualified on its frozen tree:

- **Gate.** All five steps PASS: 3,250 tests in 6 shards (485.5 s), the known
  Kimi retry passed, and `failures[]` is empty; E2E, smoke, architecture and
  parity-check passed. Logs: `/mnt/data/raft-swift-development/batch/integrate-4/.build/gate-logs/20261111T200430Z/`.
- **Persistence.** Full serial `make test-pg` PASS: 49 cases, 0 failed.
- **Release.** Initial build 423 s produced `5f69c8bc…`; 1,700 tracked files kept
  hash `9c98039d…`; deployment reused it in 12 s (cached no-op, not a build); artifacts stay on the data disk.
- **Deployment.** Build/stage/verify, `pg_dump`, upgrade and gateway restore ended `UPGRADE OK`/`DEPLOY OK`; `actualObserved: true`.
- **Privacy.** Two production JSON env files parsed; four configured private patterns
  plus one host pattern had zero matches. Searched scope only, not every key/config.

## Behavior delivered in ab04

`ab04` carries the completed Engine.IO v4 polling transport (auth, hub, default
client), Content-Length/chunked framing including illegal framing and the
negative-Range defect, late GET with close and final-Probe cleanup, probe pings
answered with probe pongs, and per-request response slots fixing the synchronous
noop response hang (noop6 still required). Responses remain ordered under
multi-SID failure; header overflow answers 431 like Node. D2 only separates
listeners; fixed WebSocket client transport is not server parity, and this is
not a full upstream semantic test-suite port.

## Acceptance, Web and soak

The actual ab04 14-check acceptance passed: 14 PASS, 0 FAIL/BLOCKED/SKIP in
204.7 s; attachment nonces at seq 170/173, Computer restart at 180/182, keep at
184/186, 14 durable rows. Reproduce: `scripts/acceptance/acceptance.py --full --restart-main --restart-computer --computer-service-unit raft-swift-production-computer.service --restart-agent keep-session --reply-timeout 180`.

The five-page authenticated Web round and post-cleanup Node Web job both passed:
five pages at HTTP 200, only the known D5 `/api/product-feedback/tickets` 404,
`alerts` empty — zero monitored regressions (errors, status, performance), not
page-content identity; messages and tasks differ. Lead inspected the five screens;
layout was normal. The gateway rehearsal kept Main on ab04 at the same PID, config
inode, root 503/503/200 and five authenticated pages.

`postload-origin-final.json`/`postload-public-final.json` each pass 36/36 on ab04.
The 600 s monitor finalized `HEALTHY`: 600.373 s, exit 0, 10 rounds, 50
authenticated pages at HTTP 200, zero alerts/changes; `canary-completed.json`
selects the monitor and reports.

## Cleanup execution

The read-only preflight was `READY_TO_EXECUTE`: 19 objects, 18 READY, one KEEP
(`B-ccf41374`, qualified copy absent). Execution handled exactly 18: 2 scopes
STOPPED, 3 containers removed (images and bind data kept), 13 directories
(7 scratch, 6 release) removed; 0 failures, no abort. Six stage ports gone;
production units, gateway config and DB were unmodified during cleanup; no production deploy/API/message/login change.

The postcheck is clean: `noExtraDeletions` true, 63 KEEP, stage images, restore containers,
four backups, owner/Codex, tunnel and ab04/b23/db2/152/94a/1c40/f70 unchanged; disk fell 21,745,786,880 bytes (~20.25 GiB), apparent removal 21,206,786,882.

## Route and module limits

Route baseline C0: 644 upstream versus 611 Swift, 583 exact, 1 variant, 57 raw
missing (5 false positives, 52 exclusions) and 27 extra; 0 reachable Class C.
`PARITY.tsv` has 406 modules, 230 mapped — explicit limits, not full parity.

## Delivery status and next steps

Delivery is COMPLETE within the agreed scope. Remaining operations: keep the b23
rollback release and dumps available, and leave the `B-ccf41374` scratch until its
qualified copy is available; no new work without need.

## Completed checks

All completion checks are MET. The gate, PostgreSQL and 14-check acceptance
passed on ab04 with 14 PASS, 0 FAIL/BLOCKED/SKIP, real nonce reads, correlated
restart replies, and Computer/Codex keep-session intact. The five-page Web round,
gateway-closed restricted rehearsal and both 36-case origin/public reports passed
with only the known D5 404; the 600 s monitor passed with 10 rounds, 50
authenticated pages and zero monitored regressions. The rollback release, dump
and path stay intact.

Cleanup executed only the unchanged 18 READY objects of the 19-object whitelist
after the pinned manifest, final canary and read-only preflight, with one KEEP,
0 failures and a clean postcheck. Only intentional differences remain in
`docs/DEVIATIONS.md`: D5 leaves the `/api/product-feedback/tickets` UI path at
404, D12 leaves built-in app conversations/DM absent, and the route/module
limits stay explicit. No new deviation, widened exclusion, full test-suite port
or route match is claimed.

## Evidence

The ab04 qualification root
`/mnt/data/raft-swift-development/tmp/qualification-engineio-v4/` holds the
candidate, gate/PG logs, build proof, deployment log, browser baseline,
`browser-canary/`, monitor/canary/acceptance JSON, both 36-case reports, gateway
publication, verification/reviewed JSON and deployment-state facts. The cleanup root
`/mnt/data/raft-swift-development/tmp/stage-cleanup-execution-ab04cacf/` has the
manifest, preflight, execution result and postcheck; its prior `REPORT.md` stays
historical. Upgrade provision holds the record, dump and launch specs; keep the
owner environment, data disk and credentials intact.

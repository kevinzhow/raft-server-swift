# Independent verification — raft-server-swift

- Verifier: `verifier` (independent Team member, task-2)
- Date: 2026-11-05 (Asia/Tokyo)
- Repo: `/mnt/data/raft-server-swift`
- Toolchain: `/mnt/data/opt/swift-6.4.1-RELEASE-ubuntu26.04/usr/bin/swift` (6.4.1, verified via `Testing Library Version: 6.4.1 (804dc4530ef3666)`)
- HEAD verified: `55ecd0e7eb259c0b10fe38bb1977ececec34fbe0` — *Forward canonical agent feedback report ids and native product types.*
- Write scope: this file only. No `Sources/`, `Tests/`, `docs/PARITY.tsv`, `docs/BEHAVIOR.md`, or `docs/PLAN.md` content was modified.

## Overall status

**PASS with documentation discrepancies.** Gates green: `make parity`, `ProbeGateTests`, final `make test` (run 2), `make test-e2e`, manual single-process startup smoke. One full-suite run failed on a timing-sensitive `RaftDaemonClientTests` case; the required single rerun was green and the case passed 5/5 in isolation — classified as the known scheduler flake, unrelated to current HEAD changes. No functional blocker. Two documentation defects are reported (PLAN overall case sum; one orphaned commit hash in `docs/PARITY.tsv`) plus stale historical numbers in PLAN/README.

| # | Check | Result |
| --- | --- | --- |
| 1 | `git status --short`, `git log -3`, HEAD | PASS |
| 2 | `make parity` (exact module/case numbers) | PASS |
| 3 | `swift test --filter ProbeGateTests` | PASS (4/4) |
| 4 | `make test` (known flake; rerun once) | PASS on rerun; run 1 had 1 flaky failure |
| 5 | `make test-e2e` | PASS (2/2) |
| 6 | Single-process startup smoke | PASS (no `smoke`/`startup` make target; ran README-documented manual smoke) |
| 7a | PLAN snapshot numbers vs `make parity` | PASS for module counts/route cases; **overall case row off by 8** |
| 7b | Locked `docs/PARITY.tsv` commits exist in `git log` | **1 of 389 locked rows cites an unreachable commit** |

---

## 1. Repository state

```text
$ git status --short
(empty — clean tracked tree)

$ git log -3
55ecd0e7eb259c0b10fe38bb1977ececec34fbe0 2026-11-05 15:06:04 +0900 Forward canonical agent feedback report ids and native product types.
6ab46198dd6072e56f2b5089ca411e8792ad5594 2026-11-05 15:01:41 +0900 Pin feedback webhook removal and unconfigured native attribution.
4a561b221623bcf0fc59757aba38c9f0f0dfed7c 2026-11-05 14:54:28 +0900 Close canonical feedback tickets and reject non-image replies.
```

HEAD at end of verification: still `55ecd0e` (no commits or tracked-file changes were made during verification).

Note: during the run another Team member created `docs/team/AUDIT.md`; at the end `git status --short` shows only the untracked `docs/team/` directory (this file plus `AUDIT.md`). The tracked tree is unchanged.

## 2. `make parity`

```text
$ make parity
upstream source : /mnt/data/tmp/grok/raft-source-v1.21.23
ledger          : /mnt/data/raft-server-swift/docs/PARITY.tsv (406 modules listed)

area     modules  listed  locked  partial  pending   cases  locked cases  coverage
----------------------------------------------------------------------------------
route        219     219     202       17        0    2000          1490     74.5%
socket         7       7       7        0        0      16            16    100.0%
daemon       180     180     180        0        0    2616          2616       n/a

route coverage    : 1490/2000 cases locked (partial modules are not credited)
```

Largest un-locked route modules (top of printed list): `internalAgentApi.auth` 93, `agents.api` 87, `auth.api` 45, `internal.channelMembership.api` 43, `channels.api` 37, `oauth.api` 34, `channels.membership.api` 28, `internal.attestedSend.api` 25, `internalAgentKnowledge.api` 24, `internalComputer.agentMigration` 22.

Independent ledger recount from `docs/PARITY.tsv` (406 data rows): route 219 (202 locked / 17 partial / 0 pending), socket 7 locked, daemon 180 locked, 389 locked rows — matches the report exactly.

`python3 scripts/parity.py --check` exits 0 with no ledger problems (it validates module names and that each `locked` commit passes `git cat-file -e <hash>^{commit}`).

## 3. `swift test --filter ProbeGateTests`

```text
✔ Test concurrentRequestsForTheSameKeyShareOneRunAndResult() passed after 0.020 seconds.
✔ Test failingRunRejectsJoinedCallersAndFreesKeyAndSlot() passed after 0.100 seconds.
✔ Test settledRunStartsAFreshRunAndDifferentKeysRespectTheLimitInOrder() passed after 0.130 seconds.
✔ Test limitMustBePositiveAndTheDefaultGateNeverQueuesDifferentKeys() passed after 0.201 seconds.
✔ Test run with 4 tests in 0 suites passed after 0.201 seconds.
```

Result: **PASS, 4/4**, exit 0. No flake observed in this invocation.

## 4. `make test`

### Run 1 — FAIL (1 real failure + 1 recorded known issue)

Exit status 2. Per-target Swift Testing summaries:

```text
Test run with 2 tests in 0 suites passed            (RaftServerStartupTests — skipped without RAFT_E2E)
Test run with 22 tests in 1 suite passed            (RaftRealtimeTests)
Test run with 6 tests in 0 suites passed            (RaftMachineSocketTests)
Test run with 59 tests in 0 suites passed           (RaftHTTPTests)
Test run with 1106 tests in 1 suite passed          (RaftHTTPServerTests)
Test run with 559 tests in 1 suite failed after 6.887 seconds with 2 issues (including 1 known issue)  (RaftDaemonClientTests)
Test run with 17 tests in 0 suites passed           (RaftConnectAuthTests)
Note: Some test targets reported failures:
  - RaftDaemonClientTests (Swift Testing)
make: *** [Makefile:6: test] Error 1
```

Failing case:

```text
✘ Test aRequestAfterOurDeadlineJoinsTheRunningListingInsteadOfStartingASecond()
  recorded an issue at OarListModelsTests.swift:160:5:
  Expectation failed: await eventually { thirdScheduler.count == 1 }
  ✘ failed after 0.040 seconds with 1 issue.
```

Other reported issue in the same target was the expected documented gap:

```text
━ Test knownGapLoginBetweenComparisonAndRenameIsOverwritten() recorded a known issue
  at KimiTokenRefreshTests.swift:383:13: Expectation failed: stored.refreshToken == "rt-login"
  (wrapped in withKnownIssue; does not fail the suite)
```

### Run 2 (required single retry) — PASS

```text
Test run with 2 tests in 0 suites passed
Test run with 22 tests in 1 suite passed
Test run with 6 tests in 0 suites passed
Test run with 59 tests in 0 suites passed
Test run with 1106 tests in 1 suite passed after 12.027 seconds
Test run with 559 tests in 1 suite passed after 7.896 seconds with 1 known issue
Test run with 17 tests in 0 suites passed
```

Exit 0. 1771 test results reported across the seven targets (2+22+6+59+1106+559+17); the only skips are the 2 `RAFT_E2E`-gated `RaftServerStartupTests` (skipped in `make test`, run in `make test-e2e`), and the known issue is recorded, not counted as a failure. Zero `✘` lines in run 2.

### Flake classification

- Isolated reruns of the failing case: **5/5 pass** (`swift test --filter aRequestAfterOurDeadlineJoinsTheRunningListingInsteadOfStartingASecond`).
- Root cause is scheduler timing: the case polls `eventually { thirdScheduler.count == 1 }` after a shared listing settles; under full-suite parallel load the third `detect` can be scheduled too late for the poll window (`OarListModels.joinOrStart` clears the in-flight task from a detached `Task`, and the test's `eventually` has a fixed budget). It is a test-timing race, not a product-behavior assertion change.
- Not related to current HEAD: `Tests/RaftDaemonClientTests/OarListModelsTests.swift` and `Sources/RaftDaemonClient/OarListModels.swift` were last touched by `329fe3d` (2026-11-04, "Port the OAR model listing projection"); HEAD (`55ecd0e`) and its two predecessors touch only `Sources/RaftHTTP/EmailLogin.swift` and `Tests/RaftHTTPServerTests/ProductFeedbackSubmitTests.swift`. `docs/PLAN.md` round-closeout text already records the same class of flake ("ProbeGate 并发用例偶发依赖调度，隔离通过后整包重跑通过").
- Verdict: **known flake; final full-suite result is PASS after the mandated single rerun.**

## 5. `make test-e2e`

```text
$ make test-e2e
RAFT_E2E=1 RAFT_SERVER_BIN=.../.build/debug/RaftServer RAFT_DAEMON_BIN=.../.build/debug/RaftDaemon swift test --filter RaftServerStartupTests
◇ Test twoRaftServerProcessesStartAndStayIndependent() started.
◇ Test theServerProcessServesHealthAndAcceptsADaemon() started.
two-RaftServer gate complete: A=http://127.0.0.1:60095 B=http://127.0.0.1:35849
✔ Test twoRaftServerProcessesStartAndStayIndependent() passed after 0.199 seconds.
✔ Test theServerProcessServesHealthAndAcceptsADaemon() passed after 0.334 seconds.
✔ Test run with 2 tests in 0 suites passed after 0.334 seconds.
```

Result: **PASS, 2/2**, exit 0. Real processes, real ports, `/daemon/connect` + socket.io + `RaftDaemon` handshake exercised, two-`RaftServer` gate logs its completion line.

## 6. Single-process startup smoke

There is **no** `smoke` or `startup` target in the `Makefile`, and no single dedicated smoke script in `README.md`/`AGENTS.md` (AGENTS.md states the policy "every slice runs a single-process startup smoke"; README "Run" documents the executable manually). So the smoke was run exactly as README documents it, with isolated ports:

```bash
PORT=39080 DAEMON_CONNECT_PORT=39081 SOCKET_PORT=39082 ./.build/debug/RaftServer
```

Observed (exit 0 on `SIGTERM`; no leaked process):

```text
raft-server ready http=127.0.0.1:39080 daemon-connect=127.0.0.1:39081 realtime=127.0.0.1:39082
[Vapor] Server started   (host=127.0.0.1 port=39080)

GET /health        503  {"status":"error","detail":"database unreachable"}          (expected without DATABASE_URL)
GET /livez         200  {"status":"ok","ok":true,"db":"ok","msSinceDbSuccess":89}   (expected in first ~60s)
GET /api/version   503  {"error":"Build identity unavailable", ... "code":"build_identity_unavailable", ...}
GET /robots.txt    200
GET /definitely-not-a-route  404  {"error":"Not found","code":"not_found","path":"/definitely-not-a-route"}
SIGTERM -> graceful exit, code 0
```

All documented startup/health semantics in README and AGENTS.md matched. **PASS.**

Two environment/robustness observations (not counted as failures):

1. A first attempt used `PORT=18080`; that port is already bound on this host by an unrelated `gost` proxy (`ss -ltnp` → `users:(("gost",pid=50302,fd=3))`). The server printed its ready line, then Vapor logged `Cannot start the server: 127.0.0.1:18080 is already in use`, and the process did **not** exit on `SIGTERM` within ~5 s (needed `SIGKILL`; log showed `Cannot schedule tasks on an EventLoop that has already shut down` errors). That is a bind-failure path, not the normal startup path; the clean-port smoke above is the valid result. Worth a follow-up if a bind-failure exit code matters operationally.
2. Every startup logs one `info codes.vapor.routingkit: [RoutingKit] [Routing] Overriding duplicate route for leaf` line. No documentation of this in `docs/`, and it is not asserted by any test visible here. Informational only — implies at least one route leaf is registered twice; behavior impact was not established during this verification.

## 7. Documentation cross-checks

### 7a. `docs/PLAN.md` snapshot vs `make parity`

The declared current snapshot ("### 2026-11-03 当前快照", docs/PLAN.md lines 43–56) matches the parity report for every module count and for route cases:

| PLAN snapshot | PLAN value | `make parity` | Verdict |
| --- | --- | --- | --- |
| route modules locked | 202 / 219 (92.2%) | 202 / 219, 92.2% | MATCH |
| route cases locked | 1490 / 2000 (74.5%) | 1490 / 2000, 74.5% | MATCH |
| socket modules | 7 / 7 (100%), 16 cases | 7 locked, 16/16 | MATCH |
| daemon modules | 180 / 180 (100%) | 180 locked | MATCH |
| daemon cases | 2616 / 2616 | 2616 / 2616 | MATCH |
| overall modules | 389 / 406 (95.8%) | 202+7+180 = 389 / 406 | MATCH |

**MISMATCH (PLAN bug):** line 52 says `整体用例 | 4114 / 4632（88.8%）`. From the parity report the locked-case total is `1490 (route) + 16 (socket) + 2616 (daemon) = 4122 / 4632 = 89.0%`. PLAN is 8 cases low and 0.2 pp low (4114 and 88.8% are mutually consistent, so this is an arithmetic/refresh error in the 4114 number, not a parity change). Fixing the doc is out of this task's write scope.

**Stale PLAN sections (historical/next-step text that contradicts current parity if read as current):**

- §3.1 "route 收尾队列" (line 65) says "剩余唯一缺口是 route 的 6 个 pending 模块（158/219 模块，919/2000 用例）". Current ledger: 0 pending, 17 partial, 202 locked, 1490/2000. Every module that section queues is now `locked` in `docs/PARITY.tsv`: `appSetup.api` (4b5c49e), `agentAppAccess.api` (6869c4d), `authPendingSocialLink.api` (20eea83), `securityLifecycle.api` (a47d360), `internal.reminders.api` (082603b), `actions.privateAccess.api` (79d85ec).
- Line 57 ("最近锁定的模块" paragraph) still lists `internalAgentApi.send`（65） as a remaining concentration; that module is now `locked` (878ad93).
- "Round 255 closeout" (line 320) states route 194/219 (88.6%), 1362/2000, overall 381/406 — an older round snapshot, superseded by the current 202/1490/389 numbers; it is labelled as a past closeout, so this is historical, but it is the kind of block a reader can mistake for the current metric.
- PLAN header (line 3) still says "最近更新 2026-11-02" although the last snapshot-refresh commit is `875387e` (2026-11-05, "Refresh the plan snapshot after the reminder messages slice"). Metadata is stale.

The core problem is documentation drift, not a parity/measurement failure: `make parity` and the current-snapshot module/route rows agree exactly.

### 7b. `docs/PARITY.tsv` locked commits in `git log`

All 389 `locked` rows were checked (no sampling needed; cheap):

- All 389 have a non-empty, well-formed short hash (7–40 hex chars).
- All 389 resolve to real commit objects (`git cat-file -e <hash>^{commit}` OK).
- 388 are ancestors of HEAD (reachable from `git log`).
- **1 row fails the `git log` criterion:** `providerConnections.api` cites **`7315274`**, which is a **dangling/unreachable commit object** — not contained in `main`, `origin/main`, any tag, or any ref (`git for-each-ref --contains 7315274` empty; `git merge-base --is-ancestor 7315274 HEAD` fails). `git log -1 7315274` shows subject *"Lock the provider connection management surface."* (2026-11-04 02:39). The corresponding reachable commits are `81edb30` ("Lock the provider connection management surface.") and `3d87aff` ("Credit the provider connection management module."), both ancestors of HEAD. This looks like a pre-rebase/amended hash left in the ledger.
- Impact: `scripts/parity.py` `commit_exists()` only calls `git cat-file -e`, so a dangling object still satisfies the "locked needs a real commit" gate and the ledger counts. The credited behavior did land (`81edb30` is in history), so the parity number is not materially inflated — but the "commit exists in `git log`" property the contract relies on is violated for this row. Recommended fix (outside my write scope): re-point the row to `81edb30` or `3d87aff`.
- The 6 `partial` rows that carry a commit all pass both checks (object exists and is an ancestor of HEAD).

### Additional documentation drift (out of required scope, reported as observations)

`README.md` "Status"/"Test suites" numbers are stale relative to what the pinned toolchain actually reports:

| Metric | README claim | Measured (`make test` run 2) |
| --- | --- | --- |
| Total Swift tests | 885 | 1771 |
| `RaftHTTPServerTests` | 723 | 1106 |
| `RaftDaemonClientTests` | 82 | 559 |
| `RaftHTTPTests` | 43 | 59 |
| `RaftRealtimeTests` | 12 | 22 |

(`RaftConnectAuthTests` 17, `RaftMachineSocketTests` 6, `RaftServerStartupTests` 2 still match.) `docs/PLAN.md` §2 "2026-11-02 实测" repeats the 885 number but is explicitly dated, so it reads as a historical baseline. README has no date and is therefore misleading. README also claims 286 registered routes; this was not independently measured (no route-listing surface), so it remains unverified.

## Failures and blockers

- No functional blocker. No parity regression. No test failure that survives the mandated rerun.
- Run-1 `RaftDaemonClientTests` failure: known scheduler flake, unrelated to HEAD's changed files; full-suite rerun green and 5/5 isolated passes.
- Recorded known issue `KimiTokenRefreshTests.knownGapLoginBetweenComparisonAndRenameIsOverwritten`: intentional `withKnownIssue` documenting a known upstream-parity gap; suite exits 0.
- Documentation defects to fix (not blockers, outside verifier write scope): (a) PLAN overall-cases row 4114 → 4122 (88.8% → 89.0%); (b) `docs/PARITY.tsv` `providerConnections.api` commit `7315274` is unreachable — re-point to `81edb30`/`3d87aff`; (c) stale PLAN §3.1/Round-255 numbers, PLAN header date, and README test-count table.

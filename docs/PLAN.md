# Delivery plan and current status

Current status only. Deliberate differences are in [DEVIATIONS.md](DEVIATIONS.md),
module history in [PARITY.tsv](PARITY.tsv), architecture and guardrails in
[ARCHITECTURE.md](ARCHITECTURE.md), and the verification contract in
[VERIFICATION.md](VERIFICATION.md).

## Objective and stage

Verify Swift against `raft-source` tag `v1.21.23-source.1` with separate entry,
behavior, real-client and lifecycle evidence. Deliver a reusable attachment
sample and an upgrade method that keeps version facts, portable rules, private
environment adapters and immutable evidence separate. See
[PARITY-UPGRADES.md](PARITY-UPGRADES.md).

The first **35-rule streaming attachment sample is complete**: upstream 35 PASS,
Swift 35 PASS, paired 35 PASS; no FAIL, BLOCKED, NOT_RUN or invalid PASS evidence
inside that denominator. It includes actual fixed official CLI execution and both
retained-data process restarts. This is not whole-service or all-profile parity.
The separately executed global-off session profile has three paired PASS and two
paired FAIL. Real presign and enabled-session flow profiles remain NOT_RUN.

The accepted integration is landed, pushed and deployed. The installed release
passed build/stage verification, backup/upgrade, actual version and PID mappings,
and restored-gateway checks. The release verification scope is recorded below.

## Qualified source and runtime facts

- Official source: `db5e399f017d584e49597e3a28757645d6807893`, tag
  `v1.21.23-source.1`. The oracle checkout remains read-only. An independent export
  runs actual `server.ts`, the real orchestrator and full RisingWave.
- Swift start: merged download-repair PR #1 at
  `7180d95203a74a25d5fa280fa4064bcdaaaecdd6`.
- Qualified integration: `6431a6ea32c8c59307d26f76f317e0aee0a0776f`.
- Landed trunk merge: `e6783d5f454093a1f476d3ba1287f1723486b6ee`.
  Its tree exactly matches the integration:
  `62325e3dad0e3b6e52b320f8beb4b3b48f921f53`.
- Isolated acceptance Main SHA-256:
  `3655887ad260ffb38db770eecbf84b1e33596eb6d16f174b409d435b19dc9baf`.
  Main is mounted from an immutable candidate, with verified actual host PID,
  start ticks, runtime libraries, pinned image, effective environment and CA.
- The Swift fixture uses formal Main with PG17, Redis and encrypted S3 over
  verified TLS. The reference uses local-disk streaming. Host trust is unchanged.
- Official CLI version `0.0.38` is built from the same source pin. Its four dist
  files, resolved Node ELF and seven interpreter/shared-library files are fixed.
  A hash-checked guard verifies this closure before each real CLI execution.
  Implementation-bundle SHA-256:
  `98849028b95603e8584fea1d683fe4e5af6b9930d5a953391c747f8d60dfc076`.
- Node 24.22.3 is the recorded actual runtime; the source recommends 24.21.0.
  Server `1.21.23` and CLI `0.0.38` are distinct package versions.

The final fixed-client baseline is
`3037739f6c271d6897be6916f972fa3b5c65cd7d5feebaa4d7a90e1f2a9d8bc7`.
Campaign artifacts are outside Git under the data-disk verification campaign.
The final run is `attachment-pilot-streaming-v4`, with raw private HTTP/CLI
observations, state and process-restart receipts. Configurations and raw identity
material remain private. The original pilot report is preserved; a separate
qualified-core report binds its evidence to actual gate receipts.

## Executed acceptance and gates

The shared initial phase proves private creation and GET readback before writes,
three multipart uploads, full metadata and message/history association, Human and
Agent original bytes, MIME/disposition/cache/nosniff protocol, empty-body refusal,
missing/auth refusal, official CLI profile login and output SHA, and removal of a
real previously authorized Agent with an owner byte witness: 24 rules per side.

Only the owned API processes were then restarted. Database, object storage and
fixture IDs were retained. Eleven more rules per side re-read the original
objects and history and recheck the same revoked object plus owner positive
witness. Both process incarnations changed while source, binary, manifest and
configuration identities remained fixed. All 35 paired comparisons pass.

The original v3 client hash covered only a 604-byte loader. Independent review
identified that evidence limitation. The full implementation/runtime closure was
then fixed, an implementation-corruption negative control rejected execution,
and **v4 reran all initial and restart rules**. No v3 PASS row was promoted into
the new baseline. Source/binary and raw v3 evidence remain unchanged.

- Final focused/affected corrections and independent source review pass. Typed
  principal/ancestor deletion boundaries have published-HTTP red/green controls
  with real positive-byte witnesses.
- Integration `make gate`: all five steps PASS. The six shards discovered 3,303
  entries; that is not an executed/non-skipped total. The known Kimi timing test
  passed its isolated retry. Real process E2E, smoke, architecture and parity pass.
- Sequential `make test-pg`: 61 gated startup tests, zero failures; database health
  and infrastructure check PASS on one disposable PG17/Redis pair.
- Integrated Python checks: 60 pilot/evidence/upgrade-planner and 20 inventory
  regressions PASS.
- Latest repository read-only acceptance: health/version, owner login/refresh,
  server scope and GET sweep PASS. All 14 durable revision rows are unchanged.
- Independent final evidence review found no remaining issue after the CLI
  closure repair. Raw reference hashes, original IDs and byte hashes, owner
  witnesses, process identity and qualification records were checked.

The retained known-old `1b456511` binary remains a negative control: the exact
same HTTP byte assertion detects PNG and all-byte corruption despite 200 and
unchanged lengths; text and all Human downloads stay positive. The old isolated
service is stopped. Its state and evidence are retained, not reset.

## Current deployment

Installed Main: `e6783d5f454093a1f476d3ba1287f1723486b6ee`.
Release binary SHA-256:
`acec9879162992e504f41d4ac9f9a479f9efb3ca979f0b00cb06549c5119bff1`.
This release artifact is distinct from the isolated debug acceptance binary;
their source tree is identical, and their own artifact/runtime proofs are retained.

The standard build → stage → verify → backup/upgrade completed. Stage verified
94 files and 28 symlinks, exact no-database health503, version and loaded-library
mappings. Installed private health/version, actual executable/PID, gateway root and
gateway API version checks pass. The pre-upgrade dump and previous `1b456511`
release remain available for rollback. The ignored deployment baseline setting
now points to the verified installed commit.

Upgrade state keeps every domain/key and all non-runtime payloads unchanged;
`agents_runtime` and `machines_and_computers` changed across restart. This is
separate from the isolated read-only sweep, whose 14 revisions were unchanged.
Owner account stores are retained and Codex login files were not modified. No
production message-sending acceptance or all-profile validation is claimed.

## Remaining scope and next risk batch

The inventory preserves 646 upstream operation candidates, 723 registrations and
92 needs-review records, including raw mount/auth/tenant constraints and implicit
method uncertainty. Counts do not establish reachable behavior. The historical
406-module/230-test-file ledger is not this campaign's completeness denominator.

The sample lists seventeen additional rule groups that are not completed by the
core denominator. Apart from the separately reported five-check global-off slice,
unexecuted rules remain NOT_RUN, including full identity/tenant matrices,
linked/thread permissions, presign/expiry, boundaries/effects, read-state/events,
preview/Web behavior, enabled sessions, storage failures, cancellation/concurrency
and managed execution. Targeted backend controls do not promote those whole
groups to PASS.

1. **ATTACHMENT-012, next storage/session owner assigned:** actual global-off
   Human/Agent status is Node403 `UPLOAD_FORBIDDEN` versus Swift404
   `UPLOAD_SESSION_NOT_FOUND`. Both capabilities and active empty-list controls
   match. Separate service presence, global admission, server gate and recovery;
   do not fix only an error string. This is a defect, not an intentional deviation.
2. **ATTACHMENT-011:** production encrypted S3 installs no real presigner. A
   test-injected closure does not qualify real 302/URL/TTL/expiry or safe-follow
   behavior. Use actual production wiring and isolated storage on both targets.
3. Execute enabled session transfer/complete/cancel/recovery profiles with their
   own denominator and current evidence. Neither global-off nor streaming PASS
   qualifies these paths. D5/D22 do not automatically exclude them.
4. Resolve inventory unknowns by authentication/tenant/lifecycle risk, then extend
   the common scenario method to DM, mention, Task and thread flows.

## Reuse and completion rules

The upgrade method, operator guide and conservative delta planner are delivered.
Twenty-two planner regressions pass; an executable rehearsal detects eight
synthetic old/new entry, field, source-helper, rule and uncertainty changes.
Generated queues remain NOT_RUN with false acceptance/release flags. No real new
upstream release was substituted for the active oracle.

Future acceptance starts with old/new source, configuration and client-closure
facts, reviews affected behavior and consumer fields, and creates fresh evidence.
Unknown source coverage widens review. A changed loader, implementation bundle,
Node/runtime dependency, configuration, tool or source baseline invalidates its
affected proof. A matching status/length, historical `locked` row or unexecuted
exception never becomes PASS. Every flow/profile has an explicit denominator;
NOT_RUN/BLOCKED prevents completion of that declared scope.

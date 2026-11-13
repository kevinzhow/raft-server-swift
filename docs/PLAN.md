# Delivery plan and current status

Current status only. Deliberate differences are in [DEVIATIONS.md](DEVIATIONS.md),
module history in [PARITY.tsv](PARITY.tsv), architecture and guardrails in
[ARCHITECTURE.md](ARCHITECTURE.md), and the verification contract in
[VERIFICATION.md](VERIFICATION.md).

## Objective and stage

Verify Swift against `raft-source` tag `v1.21.23-source.1` with separate entry,
behavior, real-client and lifecycle evidence. Current priority is the whole-repo
omission census and mandatory feature-completion system described in
[FEATURE-VERIFICATION.md](FEATURE-VERIFICATION.md). The reusable attachment sample
and [upgrade method](PARITY-UPGRADES.md) remain scoped evidence.

The census registers all **406 historical modules in 20 mutually exclusive
families**. There are 29 source-confirmed discrepancy/capability-gap records,
two runtime-confirmed records (including the existing off-profile discrepancy),
12 re-verification risk groups and ten reviewed-deviation boundary groups. These
include previously known issues; they are not 53 new bugs. Only recorded source
ranges were read; inventoried modules do not become PASS. There are 230 modules
with historical test mappings, 176 unknown mappings, and 223 unique named files.

The completion system now requires a current change plan, source/consumer
contract, raw typed producer/state/consumer assertions and source/build/process/
client/configuration binding. Its initial family contracts are non-qualifiable
drafts. `make check` enforces preflight; `make gate` includes tool adversarial
controls and scoped qualification; normal deployment consumes the full gate
receipt. Global debt remains visible and whole-family/global completion stays
false. This round changes tooling and process; it does not fix or deploy the
individual business gaps.

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

1. **B00, mandatory verification system:** complete independent review and
   adversarial validation of the new change/contract/raw/runtime gates, then keep
   them mandatory for every later slice. No module count or green helper suite
   replaces the declared producer/consumer/state obligations.
2. **B01, authorization and read-state effects:** session TTL, Agent grant/scopes,
   consume=false and server-scoped frontier. Use public positive/refusal controls
   and actual before/after authority, not pre-granted fixtures.
3. **B02/B03, human activity and canonical state:** ordinary message producer to
   Activity plus the complete Web consumer; rename mirrors, archive query and
   read-mutation execution. Reevaluate exact deviation/consumer conflicts.
4. **B04/B07, real ports and integrations:** Skills, bootstrap admission/token,
   translation/provider, MCP draft tools, workspace analytics consent and feedback
   binary transport. Missing provider stays explicit, never fabricated success.
5. **B05, storage profiles:** ATTACHMENT-012 global-off Node403 UPLOAD_FORBIDDEN
   versus Swift404 UPLOAD_SESSION_NOT_FOUND; ATTACHMENT-011 real presigner; enabled
   sessions, quota accounting and unsent Files admission. Streaming35 stays valid
   within its existing scope and does not qualify these profiles.
6. **B06/B08/B09, daemon/product/entry closure:** decide official Computer versus
   Swift daemon scope first, then real duplex/runner stop and retained recovery;
   content loaders and remaining source/consumer flows; unresolved registrations,
   middleware, independent listeners and HEAD/OPTIONS. Inventory-only modules
   remain planned unknowns until their actual scoped flows are executed.

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

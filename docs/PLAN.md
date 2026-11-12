# Delivery plan and current status

Current status only. Deliberate differences are in [DEVIATIONS.md](DEVIATIONS.md),
module history in [PARITY.tsv](PARITY.tsv), architecture and guardrails in
[ARCHITECTURE.md](ARCHITECTURE.md), and the verification contract in
[VERIFICATION.md](VERIFICATION.md).

## Objective and stage

Verify the Swift reimplementation against `raft-source` tag `v1.21.23-source.1`
with separate entry, behavior and real-client evidence. The first attachment
sample covers privacy prerequisites, multipart upload, message association,
history, human/Agent downloads, real CLI output, permission removal and
retained-data restart. Whole-service entry inventory runs alongside the sample. The deliverable also includes a reusable
version-alignment method: stable rules, separate version/runtime facts, conservative
upgrade differences and review queues, fresh evidence rules and an executable
synthetic upgrade rehearsal. See [PARITY-UPGRADES.md](PARITY-UPGRADES.md).

Stage: reviewed source and reusable tooling are integrated. The first complete
integration gate stopped in sharded tests at four reproducible assertion failures;
the source owner is checking their old header/auth/golden expectations against the
pinned specification. Further live acceptance stays paused and the isolated Swift
runtime remains stopped. No new slice is release-qualified and no deployment has
occurred in this campaign. Existing `locked` entries and prior gates do not
establish complete user paths.

## Baselines and executed evidence

Official source is `db5e399f017d584e49597e3a28757645d6807893`
(`v1.21.23-source.1`). The source oracle stays read-only. A separate export has
frozen dependencies, the built official CLI, actual `server.ts`, the real
orchestrator and full RisingWave bootstrap. Source/lock integrity was checked;
Node 24.22.3 is the recorded runtime rather than the source's 24.21.0 pin.

[PR #1](https://github.com/kevinzhow/raft-server-swift/pull/1) merged at
`7180d95203a74a25d5fa280fa4064bcdaaaecdd6`. Arbitrary attachment, external-avatar
and announcement-image bytes now use a typed binary response with lengths from
actual bytes. Its tree `c15d18d937a0b8417d45eb1e1b5146e32d576877` matches qualified
local integration `59f72e5c`. Independent review, focused binary/image tests and
all five gate steps passed. Shards discovered 3,287 entries; that is not an
executed/non-skipped case count. The gate summary is in the attachment area's
`.build/gate-logs/20261112T124828Z/summary.txt`.

The isolated Swift runtime used this merged source with formal production Main,
PG17, Redis and encrypted S3 over verified TLS. Its private CA initially did not
reach NIO's default trust path: setting `SSL_CERT_FILE` was insufficient. The same
existing actual NIO/Soto production-storage test failed with original trust and
passed with the private bundle mapped inside an isolated container. Host trust,
source, keys and binary were unchanged. Paired multipart execution then succeeded;
the original environment failures remain recorded as ENV, not product fixes.

The second paired run completed execution for its then-declared initial scope:
reference 23 PASS; Swift 14 PASS and 9 FAIL. Three additional history envelopes differ at the paired-comparison layer. Eleven
restart rules per side remained NOT_RUN. Both implementations returned all original bytes for PNG, all 256 byte
values and UTF-8 text. Reference real CLI login/download passed; Swift CLI login
failed identity validation. These are partial results for a fixed baseline, not
attachment acceptance or a release decision.

The current runner adds an explicit privacy prerequisite, bringing its required
sample to 35 rules. Both channel creation and GET readback must establish the
private type before dependent writes proceed. It also requires restart receipts,
checks running source/tool/CLI identities, preserves failed observations and
separates execution, completion and release eligibility. The latest focused
Python checks on the integrated tree pass: 60 pilot/evidence/upgrade-planner tests
and 20 inventory tests. Source area `ab39a7c1` and tooling `421959d5` were joined by
real merges at `6a8f2450`; the source/test/package objects match the independently
reviewed area. The first integration gate discovered 3,303 test entries (not an
executed/non-skipped total). Four failures remained after isolated retry:
integrations/app-access bytes, idless Agent upload headers, realtime Agent auth
bytes and wake-hint missing-auth shape. The known Kimi timing test passed its
isolated retry. Remaining gate steps and real-PG qualification have not run.

## Current deployment

The last documented deployed Main is
`1b456511c825105a290895192dc9ff4f6f59663b`; this campaign has not changed it or
re-probed production. Keep the installed release, isolated runtime and new source
candidate distinct. That rollout contains native MD4C and the controlled pinned-Web
avatar overlay D38, with the existing D23 original-image policy. Prior avatar
read-only/browser evidence does not qualify this attachment batch. Retain the
`57b6775f` release, pre-upgrade dump and documented rollback assets.

## Source repairs and immediate qualification work

The delivered source addresses the v2 privacy/contract findings: requested private
creation and selected members, canonical removal/read authority, complete upload
and history metadata, Agent byte/header presentation, missing/wrong-principal
errors and the root identity required by the real CLI. Ordinary create now has its
full 37-field birth envelope and conditional read-receipt projection.

Independent review also required typed legacy membership without posting rows,
single filename repair, consistent object-aware create/detail/list/mutation
capabilities, same-UUID Human/Agent isolation and tombstone checks at every
parent. These boundaries have direct public-HTTP red/green controls, including
positive bytes. Six removal/leave paths preserve the other principal's typed
membership. Visibility retains the source's additional current Human membership
prerequisite even for a server owner.

The broad affected run covered 608 tests, exposing nine old functions/ten
instances with 17 issues, including the omitted visibility prerequisite. Its
reviewed five-line restoration and seven strict fixture/golden corrections pass
a 24-test correction run. Final boundary checks, architecture and parity pass;
scoped independent review found no remaining actionable source issue. Exact
review fingerprints were checked before integration.

The immediate work is to resolve the four full-gate assertion failures against
the pinned source, preserve exact response/header/frame checks, then rerun the
integration gate followed by the real-PG gate. These are qualification steps;
source regressions or a review conclusion cannot substitute for a new live run.
The old runtime, original binary snapshot and raw evidence remain retained.

## Inventory and remaining verification scope

The new static inventory retains 646 upstream operation candidates, 723
registration candidates and 92 needs-review records. A directly executed single
Vapor dump test exported 611 registrations with `nodeEnv=test`: 584 normalized
matches, one variant, 58 raw missing and 26 extra. These counts are matching aids;
they do not establish reachable behavior, middleware, implicit methods, Socket.IO
or daemon coverage. Ten attachment mount/helper records have source-based review
notes without being relabeled runtime-verified.

The sample has source/behavior/scenario mappings. Seventeen additional rule groups
remain explicit NOT_RUN, including identity/tenant matrices, linked/thread
permissions, presign/expiry, upload boundaries and effects, read state/events,
preview/Web behavior, enabled sessions, storage failures, cancellation/concurrency
and managed Agent/Computer execution. Session-off expectations require the actual
service branch: a null service gives human 403 / Agent 404, while formal global-off
bootstrap retains a Durable recovery service with different gate/refusal behavior.
Swift production has no installed presigner; changing S3 environment values cannot
make encrypted originals into plaintext signed downloads. D5/D22 do not automatically
exclude these real capability profiles, which remain open functional scope.
The upgrade planner and how-to are implemented without changing the active pinned
oracle. Its 22 planner regressions and the 38 existing verifier regressions pass;
a replay through the actual CLI detects all 8 synthetic upgrade controls while
retaining `NOT_RUN` queue states and false acceptance/release flags. These plans
cannot inherit old PASS results or authorize a release.

A verified pre-repair `1b456511` release supplied the actual binary corruption
counterexample. Its full closure and host dependencies were rechecked; a separate
database and three authenticated encrypted object copies preserved the exact
inputs. The same shared HTTP byte assertion rejects its PNG and all-256-byte
responses despite status 200 and unchanged lengths. Both match the known lossy
UTF-8 transformation; text and all three human downloads are positive controls.
The repaired baseline passes all three Agent byte checks. The old service is
stopped and its fixture/evidence retained. This direct-HTTP counterexample does
not qualify URL generation or the old implementation's user flows.

## Completion conditions and next steps

Correct and integrate the full-gate findings without weakening strict source-backed
assertions, then run the integration gate and required PG gate sequentially in the
warm area. Freeze the resulting artifact/configuration identities before startup.
Execute a new-baseline paired sample, actual CLI output, same-object revocation
witnesses and retained-data restart without reseeding. The known-old corruption
counterexample already uses the same byte assertion and retains text/human
positive controls.

Every required result needs current evidence and matching source/configuration.
NOT_RUN/BLOCKED prevents that declared scope's completion. Separate streaming,
presign and upload-session profiles; resolve or explicitly carry their missing
branches without turning deviations into PASS. Deliver the reusable sample,
truthful current limits and prioritized follow-up work. Historical C0 counts and
the 406-module/230-test-file ledger retain their original scope and are not this
campaign's completeness denominator.

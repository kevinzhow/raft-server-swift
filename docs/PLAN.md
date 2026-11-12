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
retained-data restart. Whole-service entry inventory runs alongside the sample.

Stage: the download repair is merged and qualified. Both isolated production
bootstrap paths have run, and paired initial scenarios found real contract and
privacy defects. Further live write acceptance is paused; the Swift candidate
is stopped while its area owner develops HTTP regressions and repairs. No new
slice is release-qualified and no deployment has occurred in this campaign.
Existing `locked` entries and prior gates do not establish complete user paths.

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
Python runs passed 38 pilot/evidence tests and 20 inventory tests. Integration
gates for the new tooling and source repairs remain pending.

## Current deployment

The last documented deployed Main is
`1b456511c825105a290895192dc9ff4f6f59663b`; this campaign has not changed it or
re-probed production. Keep the installed release, isolated runtime and new source
candidate distinct. That rollout contains native MD4C and the controlled pinned-Web
avatar overlay D38, with the existing D23 original-image policy. Prior avatar
read-only/browser evidence does not qualify this attachment batch. Retain the
`57b6775f` release, pre-upgrade dump and documented rollback assets.

## Confirmed defects and immediate work

- Private creation: the ordinary Swift channel path ignores `visibility: private`.
  V2's creation response omitted type, and its setup did not verify readback.
  Its post-removal 200 cannot alone prove a leak from an established private
  channel. New independent HTTP red tests lock private creation and readback.
- Membership removal: human and Agent member-removal paths leave posting
  membership after deleting the other membership source. Shared access ORs the
  sources. Independent HTTP red tests with a genuinely private channel reproduce
  continued reads; the self-leave control denies correctly. Repair creation,
  canonical read authority and every affected removal path together.
- Upload metadata: all three Swift 200 envelopes contain only `id` and `filename`,
  omitting official MIME, size, dimensions and preview fields.
- Agent downloads: bytes match, but MIME/charset, disposition, cache and nosniff
  protocol assertions differ from the pinned source.
- Agent principal/identity: missing Agent auth returns the human-session error;
  the real CLI rejects the successful credential's root identity payload.

One area owner handles these source fixes in the attachment worktree. The old
candidate is stopped and its unchanged binary snapshot and raw evidence are
retained. Do not resume live writes or replace the candidate until focused and
affected checks support a new explicit baseline. Membership/persistence changes
also require real-PG qualification before landing.

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
and managed Agent/Computer execution. Capability-off upload-session refusal also
differs by principal upstream: human 403 and Agent 404; do not use a blanket 404.

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

Finish the privacy fixes first, then the remaining confirmed payload/protocol and
CLI defects. Review and integrate source/tooling branches with real merge commits;
run the integration gate and required PG gate sequentially in the warm area.
Execute a new-baseline paired sample, actual CLI output, same-object revocation
witnesses and retained-data restart without reseeding. Demonstrate the known-old
corruption with the same byte assertion, retaining a text positive control.

Every required result needs current evidence and matching source/configuration.
NOT_RUN/BLOCKED prevents that declared scope's completion. Separate streaming,
presign and upload-session profiles; resolve or explicitly carry their missing
branches without turning deviations into PASS. Deliver the reusable sample,
truthful current limits and prioritized follow-up work. Historical C0 counts and
the 406-module/230-test-file ledger retain their original scope and are not this
campaign's completeness denominator.

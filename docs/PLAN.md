# Delivery plan and current status

Current status only. Fixed defects live in commits; differences are in
[DEVIATIONS.md](DEVIATIONS.md) and [PARITY.tsv](PARITY.tsv), architecture and
guardrails in [ARCHITECTURE.md](ARCHITECTURE.md).

## Objective

Deliver the Swift reimplementation of `raft-source` tag `v1.21.23-source.1`:
HTTP/socket contract, fixed Web/CLI consumers, PostgreSQL persistence, the
daemon/Computer path and deployment. Parity tests evidence the contract, not a
complete user path.

## Current deployment

`57b6775fe5d90e4f1f48b21ceefa7b2e3c33a545` is deployed, preserving the
architecture rollout and adding native Markdown parsing. The change was merged
into `deploy-linux-docker` first, then `main` was fast-forwarded to the same merge;
both branches were pushed before deployment. Documentation-only follow-ups do
not change the installed product SHA.

Build (427 s), stage, verification, `pg_dump`, upgrade and gateway restoration
passed. Private/public version endpoints report `57b6775f` at `1.21.23`; health
is 200. The 282,914-byte pre-upgrade dump has a verified SHA-256. The previous
`a6bf8699` release, launch spec and manifest remain available for rollback.

## Qualified source and gate

The architecture/native integration at `57b6775f` passes all five `make gate`
steps: 3,277 sharded test entries, E2E, smoke, architecture and parity-check.
The existing Kimi race test passed its isolated retry; final failure list is
empty. Evidence: `.build/gate-logs/20261112T093150Z/summary.txt`.

## Native Markdown rollout

The native parser change `88cfc840` is integrated and deployed. It replaces
JavaScriptCore with pinned MD4C and documented source-range/GFM adaptations.
JS remains an offline oracle under `Tools/MarkdownParser/reference`; production
resources carry the combined native MIT notices. Each parser invocation owns
its scratch, with no global parsing lock.

Qualification passed 9,189 identical raw-range/surface comparisons, 17,492
ASan/UBSan/leak-check inputs, focused human/agent and raw/typed HTTP mention
cases, and the process-map startup test. The map test rejects the old JSC
executable. Staged and deployed native processes have no JavaScriptCore mapping.

The public API canary passed all 14 parser cases, including code/link/image
exclusions, reference forms, GFM boundaries, Unicode, entity targets, and
original persisted source. It used a synthetic unknown handle and a new channel
with owner-only membership and zero agents before every send. The channel was
soft-deleted; 14 synthetic message rows and a fresh login session remain.
No browser or full agent/attachment acceptance was rerun for this parser rollout.

At upgrade checkpoints before canary traffic, 12 of 14 aggregate rows preserve
revision, codec and payload checksum; no aggregate was added or removed. Only
`agents_runtime` and `machines_and_computers` changed. Their payloads were not
extracted, so this audit does not claim lifecycle-only differences or field-level
preservation inside them. Gateway bytes match the saved pre-upgrade copy.
Evidence: `durable-audit.json` in the current rollout artifact directory.

Three matching debug startup checkpoints have median RSS 95.4 MiB (JSC) versus
64.0 MiB (native), before database state or user traffic. An isolated parser
driver after 16,623 parses reports 108.8 versus 20.0 MiB. Live snapshots were
160.6 MiB before deployment and 97.7 MiB after the API canary; the old process
was long-running and the new one fresh, so this is not a controlled savings
estimate. Commands are in `Tools/MarkdownParser/README.md`.

## Prior architecture qualification

The following PostgreSQL/OIDC/API/attachment/browser evidence belongs to the
previous `a6bf8699` rollout. It is retained as qualification of the architecture
source preserved in this merge; it is not a claim those campaigns ran again
against `57b6775f`.

### PostgreSQL qualification

The PostgreSQL runner listed 60 entries; the main pass executed 55. The
queued-restart entry then passed its isolated 1/1 run. Four entries are
intentional standalone cases: the native stage-seed helper, the snapshot
child-process case (covered by its parent test), and two E2E-only entries
already run by the full gate.

Thus 56 of 60 listed entries actually ran against PostgreSQL. The 60-entry list
is not a claim that 60 tests executed. The runner keeps a fresh database per
case, continues after a failure, and preserves its logs and cleanup behavior.

### Live OIDC composition

The post-deploy probe passed 12 requests and 189 checks on both the loopback and
public entrances; both report SHA `a6bf8699` and the issuer/endpoint/cache fields
match. Report:
`/mnt/data/raft-swift-development/tmp/architecture-optimization-20261112/composition-probe/probe-20261112T050926Z-postdeploy-a6bf8699ccda.json`.

### Durable-state audit

Verdict: `EXPECTED_LIFECYCLE_WRITES`. Twelve of fourteen durable rows are
byte- and revision-identical. Only `agents_runtime` and
`machines_and_computers` changed:

- `agents_runtime`: reconnect epochs, order-only Set re-encodes and two synthetic
  onboarding notices/dispatches, with no queued user work or permission change.
- `machines_and_computers`: machine-reported detection, status-version and
  runtime-model metadata refresh; additive catalog entries only.

Owner, identity, sessions, 10 credential keys, attachments and agent-machine
bindings are preserved. The other 12 unchanged bindings span 11 domains (10
business plus auth; notifications has two); no business revision moved.

### API, attachment and monitoring

The 14-check API campaign passed 14 PASS, 0 FAIL/BLOCKED/SKIP in 240.4 s with
two nonce attachment reads and Main/Computer/Agent keep-session recovery
(`acceptance-full.json`). The attachment probe passed 20/20 over real R2 bytes:
GET/HEAD, 206/416, preview, 401/400/404, empty HEAD and Content-Length
(`attachment-probe/results/attachment-probe-20261112T051833Z.json`).

The 600 s monitor completed exit 0 in 600.349 s: 10 rounds x 5 pages, 50/50
authenticated HTTP 200 pages, 0 runtime exceptions, 0 confirmed alerts, all home
versions `a6bf8699`. Only accepted D5 `/api/product-feedback/tickets` 404
remains. One first cold-start load fluctuation did not recur; no alert or
throughput/latency claim. Root reviewed the four independent home (Computers)/
channel/Tasks/members views as normal. Evidence: `final-validation.json`, `monitor-report.json`.

## Route and module limits

The agreed limits are unchanged: route baseline C0 has 644 upstream versus 611
Swift routes, 583 exact, 1 variant, 57 raw missing (5 false positives, 52
exclusions) and 27 extra, with 0 reachable Class C. `PARITY.tsv` has 406 modules,
230 mapped. These are explicit limits, not full parity.

## Completion criteria

The native parser is merged, published, deployed and verified through public
message APIs. The previous release and pre-upgrade dump remain intact.
Future architecture debt is in [ARCHITECTURE.md](ARCHITECTURE.md).

## Evidence

Current native rollout evidence is under
`/mnt/data/raft-swift-development/artifacts/native-markdown-release-20261112/`:
`integration-gate.log`, `deploy-57b6775f.log`, `canary-live.json`, and the
before/after service snapshots. Release build/stage verification is under
`/mnt/data/raft-swift-development/qualified-artifacts/main-57b6775f-v1/`.
Prior architecture evidence remains under
`/mnt/data/raft-swift-development/tmp/architecture-optimization-20261112/`.
Artifacts stay on disk; domains/IPs/credentials stay out of Git.

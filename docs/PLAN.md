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

`a6bf8699ccdae20b91b4a7d59a6c2e6a4983fcb2` is deployed from the real upgrade off
`ab04cacf8e0cb45252eb379f08bcc7274242d11d`. Build took 374 s; stage, verify,
`pg_dump`, upgrade and gateway restore passed; deployment exited 0. Private/public
`/api/version` both answer `a6bf8699` at `1.21.23`; `/health` 200. The upgrade
took a 260,806-byte dump with matching SHA-256; ab04 release, dump and launch
spec remain rollback.

## Qualified source and gate

The product source and full-gate input are frozen at `61bf4aa6`. Full `make gate`
passed all five steps: 3,274 sharded test entries in six shards with one known
Kimi isolated retry, plus E2E, smoke, architecture and parity-check.
The only later change, `f8882121` in `scripts/test-pg.sh`, enabled the
queued-restart PG case and tightened skip detection. Product/full-gate inputs are
unchanged (source-equivalence proof); deployed `a6bf8699` includes that runner-only
correction, not a product-source change.

## Native Markdown rollout

The native parser change `88cfc840` is being integrated with the latest deployment
trunk before merging to `main`. It replaces JavaScriptCore with pinned MD4C and
documented source-range/GFM adaptations. JS remains an offline oracle under
`Tools/MarkdownParser/reference`; production resources carry the combined native
MIT notices. Each parser invocation owns its scratch, with no global parsing lock.

Standalone qualification passed 9,189 identical raw-range/surface comparisons,
17,492 ASan/UBSan/leak-check inputs, targeted human/agent and raw/typed HTTP
mention cases, and the process-map startup test. The map test rejects the old
JSC executable. The latest architecture/native integration passes all five
full-gate steps, with evidence at
`.build/gate-logs/20261112T093150Z/summary.txt`. Production remains `a6bf8699`
until the verified upgrade completes.

Three matching debug startup checkpoints have median RSS 95.4 MiB (JSC) versus
64.0 MiB (native), before database state or user traffic. An isolated parser
driver after 16,623 parses reports 108.8 versus 20.0 MiB. Neither is production
steady-state memory; commands are in `Tools/MarkdownParser/README.md`.

## PostgreSQL qualification

The PostgreSQL runner listed 60 entries; the main pass executed 55. The
queued-restart entry then passed its isolated 1/1 run. Four entries are
intentional standalone cases: the native stage-seed helper, the snapshot
child-process case (covered by its parent test), and two E2E-only entries
already run by the full gate.

Thus 56 of 60 listed entries actually ran against PostgreSQL. The 60-entry list
is not a claim that 60 tests executed. The runner keeps a fresh database per
case, continues after a failure, and preserves its logs and cleanup behavior.

## Live OIDC composition

The post-deploy probe passed 12 requests and 189 checks on both the loopback and
public entrances; both report SHA `a6bf8699` and the issuer/endpoint/cache fields
match. Report:
`/mnt/data/raft-swift-development/tmp/architecture-optimization-20261112/composition-probe/probe-20261112T050926Z-postdeploy-a6bf8699ccda.json`.

## Durable-state audit

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

## API, attachment and monitoring

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

This round is complete within the agreed scope. The API, attachment HEAD, OIDC,
PostgreSQL, persistence and browser/monitor checks passed; ab04 rollback stays
intact. Future architecture debt is in [ARCHITECTURE.md](ARCHITECTURE.md); final
merge/push is Root's step. No performance result is claimed.

## Evidence

The round root `/mnt/data/raft-swift-development/tmp/architecture-optimization-20261112/`
holds frozen candidate, gate/PG/deploy/OIDC/durable evidence, acceptance and
browser/monitor reports; artifacts stay on disk, domains/IPs/credentials out of Git.

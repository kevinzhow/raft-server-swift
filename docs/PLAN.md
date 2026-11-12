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
`pg_dump`, upgrade and gateway restore all passed and deployment exited 0. Private
and public `/api/version` both answer `a6bf8699` at `1.21.23`; `/health` answers 200.
The upgrade took a 260,806-byte `pg_dump`; its SHA-256 matches the recorded
checksum. The ab04 release, its dump and launch spec remain rollback.

## Qualified source and gate

The product source and full-gate input are frozen at `61bf4aa6`. Full `make gate`
passed all five steps: 3,274 sharded test entries in six shards with one known
Kimi isolated retry, plus E2E, smoke, architecture and parity-check.
The only later change is `f8882121` in `scripts/test-pg.sh`, which enabled the
queued-restart PG case and tightened its skip detection. Product and full-gate
inputs are unchanged, as recorded by the source-equivalence proof; the deployed
`a6bf8699` tree includes that runner-only correction, not a product-source
change.

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

Owner, identity, session families, the same 10 credential keys, attachments and
agent-machine bindings are preserved. The other 12 unchanged bindings span 11
domains (10 business plus auth; notifications has two); no business revision
moved.

## API, attachment and monitoring

The actual 14-check API campaign passed 14 PASS, 0 FAIL/BLOCKED/SKIP in 240.4 s,
including two nonce attachment reads and Main/Computer/Agent keep-session
recovery (`acceptance-full.json`). The actual attachment probe passed 20/20
checks against real R2 bytes: GET/HEAD, 206/416, preview, 401/400/404 denials,
empty HEAD bodies and Content-Length
(`attachment-probe/results/attachment-probe-20261112T051833Z.json`).

The 600 s normal-operation monitor is running after browser-session restoration;
the earlier pre-connection failure was not a site failure. Browser screenshots and
monitor completion remain; no HEALTHY claim yet. Final push follows.

## Route and module limits

The agreed limits are unchanged: route baseline C0 has 644 upstream versus 611
Swift routes, 583 exact, 1 variant, 57 raw missing (5 false positives, 52
exclusions) and 27 extra, with 0 reachable Class C. `PARITY.tsv` has 406 modules,
230 mapped. These are explicit limits, not full parity.

## Completion criteria

This rollout is complete when the 600 s monitor is healthy, browser screenshots
are verified, and the durable-state audit remains expected. The ab04 rollback
release and dump must stay intact. No performance result is claimed.

## Evidence

The round root `/mnt/data/raft-swift-development/tmp/architecture-optimization-20261112/`
holds the frozen candidate, gate summary, PostgreSQL audit, deployment log, OIDC
probes, durable audit and acceptance logs. Artifacts stay on the data disk;
domains, IPs and credentials stay out of Git.

# Delivery plan and current status

Current status only. Fixed defects live in their commits; deliberate differences
in [DEVIATIONS.md](DEVIATIONS.md), [PARITY.tsv](PARITY.tsv) and
[ARCHITECTURE.md](ARCHITECTURE.md). This file tracks rollout and qualification;
the architecture and guardrail detail live in `ARCHITECTURE.md`.

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

The PostgreSQL runner listed 60 entries. The main pass actually executed 55. The
queued-restart entry was then enabled and passed its isolated 1/1 run. The four
remaining entries are intentional standalone cases: the native stage-seed manual
helper, the snapshot child-process case covered by its parent restart test, and
two E2E-only entries already executed by the full gate.

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

Owner, identity, session families, the same 10 credential keys, attachments,
agent-machine bindings, and the other 12 rows (11 domain names, including both
notifications roots) are preserved. No read path moved a business revision.

## Acceptance and monitoring

The 14-case API campaign is running under Root's sole campaign. It is not
complete, so no PASS is claimed yet. Attachment `HEAD` verification, the
authenticated Web check and the 600 s normal-operation monitor are still pending.
The final result will be recorded after those complete.

## Route and module limits

The agreed limits are unchanged: route baseline C0 has 644 upstream versus 611
Swift routes, 583 exact, 1 variant, 57 raw missing (5 false positives, 52
exclusions) and 27 extra, with 0 reachable Class C. `PARITY.tsv` has 406 modules,
230 mapped. These are explicit limits, not full parity.

## Completion criteria

This rollout is complete only when the 14-case API campaign passes, attachment
`HEAD` and the authenticated Web are verified, the 600 s normal-operation monitor
is healthy, and the durable-state audit remains expected. The ab04 rollback
release and dump must stay intact. No performance or new acceptance result is
claimed before those checks finish.

## Evidence

The round root
`/mnt/data/raft-swift-development/tmp/architecture-optimization-20261112/`
holds the frozen candidate, gate summary, PostgreSQL execution audit and queued
supplement, deployment log, OIDC pre/post-deploy probes, durable-state audit and
acceptance logs. All artifacts stay on the data disk; domains, IPs and credentials
stay out of Git.

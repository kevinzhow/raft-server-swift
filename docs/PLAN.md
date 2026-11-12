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

`57b6775fe5d90e4f1f48b21ceefa7b2e3c33a545` is deployed with native Markdown.
Build 427 s, stage, verification, `pg_dump`, upgrade and gateway passed; version
is `57b6775f` at `1.21.23`, health 200. The 282,914-byte dump is SHA-verified;
`a6bf8699` remains rollback. Web remains `d4`; no avatar overlay is activated.

## Native Markdown

`88cfc840` is integrated and deployed. Pinned MD4C replaces JavaScriptCore;
parser/sanitizer matrices, focused mention/startup tests and 14 public canary
cases passed; the gate at `57b6775f` passed five steps with 3,277 entries and no
production process maps JSC. No full browser/agent/attachment rerun is claimed.

## Avatar defect

Two confirmed causes keep a new avatar stale in an open channel: Swift channel
roster human rows omit `avatarUrl`, `gravatarHash`, `displayName`, `description`
and related fields, and the Web channel overlay replaces the server row with that
incomplete payload; the pinned Web `authStore` updates only the signed-in user
after a successful avatar/profile write, without reloading the server roster or
invalidating channel-member caches, and previews prefer the cached sender row.

## Final source candidate

Backend `c84588c6` (including `db99367b`) is frozen and real-merged as
`f92ced289e9cff2d683053afb6233015c40bcfe7`, along with native `1a60`, Web overlay
`1225166d` and docs `2a0a2194`. Seven review items are clear; the last A/B
boundary verification remains, with Source frozen.

Root `make gate` is RUNNING on the exact f92 tree; no gate PASS is claimed.
Backend local focused 1 DTO + 11 HTTP and affected 26 are final-green; the 214
broad WIP run predates final A/B and is not f92 evidence. No full test-PG gate is
planned: no PG schema, runtime-adapter or transaction change.

## Web overlay

The client overlay is an allowlisted patch against the pinned
`v1.21.23-source.1` base, changing `authStore`, `useChannelMembers` and two
behavior tests (6 cache-invalidation + 2 roster-race). A successful write reloads
server members and invalidates all channel-member caches. The pinned reference is
untouched; archive/patch replay, source proof, lockfile, Node 24, pnpm 12.11.2 and
safe-stage CSS are verified; Root hash-verified the 210-file candidate and staged
it at release `587a197b…/web-assets`.
Nothing is activated: old `d4` remains active with 19 old immutable chunks from
its verified manifest; CSS unchanged. No server route/WS is added; other clients
refresh on next roster read. D23 bytes/MIME and upstream image pipeline unchanged.

## Validation

The isolated E2E RED on old `a6bf` + old `d4` Web ran 33 assertions: 5/5 predicted
failures, 0 unexpected, report
`/mnt/data/raft-swift-development/tmp/avatar-channel-fix-20261112/acceptance/RED-RESULT.md`.
It confirms missing channel avatar/hash/gravatar and the old UI fallback; it is
not green and does not prove full refresh. GREEN on f92 and production read-only
API/UI/monitor remain pending. The isolated stack uses in-memory ledger/avatar
bytes and PG health only; it proves no SQL/S3 durability.

## Residuals

Saved-item and comment avatars and unknown `joinedAt` remain unfixed. The server
store's `loadMembers` coalescing retains the same race for non-primary channel
search/favorites consumers. No cross-device real-time avatar sync is promised.

## Prior architecture

The `a6bf8699` rollout remains prior evidence and rollback; its campaigns did not
rerun against `57b6775f`. Detail stays in [ARCHITECTURE.md](ARCHITECTURE.md).

## Route and module limits

The agreed limits are unchanged: C0 has 644 upstream versus 611 Swift routes, 583
exact, 1 variant, 57 raw missing (5 false positives, 52 exclusions) and 27 extra,
with 0 reachable Class C. `PARITY.tsv` has 406 modules, 230 mapped.

## Completion criteria

Complete only after f92 passes gate/final E2E, the staged Web activates with full
CSS/provenance, deployment takes a verified backup, and read-only production
API/UI monitoring passes. Compile artifact/binary/deploy SHA remain Root's;
`57b6775f`/rollback stay intact. No owner avatar mutation, performance or
cross-device claim.

## Evidence

Avatar evidence: `/mnt/data/raft-swift-development/tmp/avatar-channel-fix-20261112/`
and `/mnt/data/raft-swift-development/tmp/avatar-web-overlay-20261112/`; no domains/IPs/credentials in Git.

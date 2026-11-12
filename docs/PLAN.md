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
Build 427 s, stage, verification, `pg_dump`, upgrade and gateway restoration
passed; `/api/version` reports `57b6775f` at `1.21.23` and `/health` is 200. The
282,914-byte dump is SHA-verified; `a6bf8699` remains rollback. Web remains the
current `d4` build; no avatar overlay is activated.

## Native Markdown

Native Markdown `88cfc840` is integrated and deployed. Pinned MD4C replaces
JavaScriptCore; parser/sanitizer matrices, focused mention/startup tests and 14
public canary cases passed, and the gate at `57b6775f` passed five steps with
3,277 entries. No production process maps JSC; no full browser/agent/attachment
rerun is claimed for the parser rollout.

## Avatar rollout

Two confirmed causes keep a new avatar stale in an open channel: Swift channel
roster human rows omit `avatarUrl`, `gravatarHash`, `displayName`, `description`
and related fields, and the Web channel overlay replaces the server row with that
incomplete payload; the pinned Web `authStore` updates only the signed-in user
after a successful avatar/profile write, without reloading the server roster or
invalidating channel-member caches, and previews prefer the cached sender row.

### Backend

The Swift roster fix is in final review: draft `db99367b` plus WIP corrections
for joint tenant permission, guest shape, phantom/removed profiles and `#all`
boundaries. It projects current identity from authoritative owners while
preserving visibility; final SHA/review/tests/gate are pending, not integrated.

### Web overlay

The final client overlay is integrated in the current candidate: an allowlisted
patch against the pinned base changing `authStore`, `useChannelMembers` and two
behavior tests, with 6 cache-invalidation + 2 roster-race cases. A successful
write reloads server members and invalidates all channel-member caches. The pinned
reference is untouched; archive/patch replay, source proof, lockfile, Node 24 and
pnpm 12.11.2 are verified, safe-stage CSS is byte-identical, and Root
hash-verified `qualified-web-candidate.json`. Nothing is activated; no server
route or WebSocket frame is added, so other clients refresh on their next roster
read. Provenance is in [WEB-PATCHES.md](WEB-PATCHES.md); D23 bytes/MIME unchanged.

### Validation

An isolated E2E RED on old `a6bf` + old `d4` Web ran 33 assertions: 5/5 predicted
failures, 0 unexpected, report
`/mnt/data/raft-swift-development/tmp/avatar-channel-fix-20261112/acceptance/RED-RESULT.md`.
It confirms missing channel avatar/hash/gravatar and the old UI fallback; it is
not green and does not prove full refresh. GREEN needs the final backend binary;
Root gate, backup, deployment, read-only API/UI and monitor are pending. The stack
uses in-memory ledger/avatar bytes and PG health only, so it proves no SQL/S3
durability.

## Residuals

Saved-item and comment avatars and unknown `joinedAt` remain unfixed. The server
store's `loadMembers` coalescing retains the same race for non-primary channel
search/favorites consumers. No cross-device real-time avatar sync is promised.

## Prior architecture

The `a6bf8699` architecture rollout remains prior evidence and the current
rollback; its campaigns did not rerun against `57b6775f`. Detail stays in
[ARCHITECTURE.md](ARCHITECTURE.md).

## Route and module limits

The agreed limits are unchanged: route baseline C0 has 644 upstream versus 611
Swift routes, 583 exact, 1 variant, 57 raw missing (5 false positives, 52
exclusions) and 27 extra, with 0 reachable Class C. `PARITY.tsv` has 406 modules,
230 mapped. These are explicit limits, not full parity.

## Completion criteria

The avatar rollout is complete only after final backend SHA passes review,
focused/affected tests and integration gate; Web activates with full CSS and
provenance; deployment takes a verified backup; and read-only API/UI refresh and
monitoring pass. `57b6775f`/rollback stay intact; no owner avatar mutation,
performance or cross-device sync claim.

## Evidence

Avatar evidence: `/mnt/data/raft-swift-development/tmp/avatar-channel-fix-20261112/`
and `/mnt/data/raft-swift-development/tmp/avatar-web-overlay-20261112/`; native
artifacts under `artifacts/native-markdown-release-20261112/`; no domains/IPs/credentials in Git.

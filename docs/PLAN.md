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

`1b456511c825105a290895192dc9ff4f6f59663b` is deployed from `57b6775f`. Build
372 s; stage/verify/backup/upgrade/restore passed; version `1.21.23`/`1b4565` and
health 200. Binary `207e62f4…`; staged verification mapped 52 files (48 staged +
4 host) with native parser and JSC false; 1,736 tracked files kept the same hash.
The new 297,448-byte dump matches SHA `90b7c0e1…`; `57b6775f` release, dump and
launch are immediate rollback, with older `a6bf8699` still retained.

## Native Markdown

Native MD4C `88cfc840` remains deployed; no production process maps
JavaScriptCore. Parser/sanitizer matrices, focused mention/startup tests and 14
public canary cases passed. No parser-specific full browser/agent rerun is claimed.

## Avatar defect

Two confirmed causes kept a new avatar stale in an open channel: Swift channel
roster human rows omitted `avatarUrl`, `gravatarHash`, `displayName`, `description`
and related fields, and the Web channel overlay replaced the server row with that
incomplete payload; the pinned Web `authStore` updated only the signed-in user
after a successful avatar/profile write, without reloading the server roster or
invalidating channel-member caches, and previews preferred the cached sender row.

## Qualification

Backend `c84588c6` is final; the A/B review is clear and `c84588c6` to
`f92ced28` is seven files byte-identical. Full gate on f92 passed 5/5 exit 0:
3,286 entries in six shards (build 201.7 s, test 343.7 s, elapsed 547.8 s),
empty `failures[]`, one known Kimi isolated retry; E2E 32 s, smoke 17 s,
architecture 1 s and parity 5 s passed.

Real trunk `1b456511` merges `45051ae3` with tree `c645e9e6`, identical to
integration. Source/full-test inputs match f92; only PLAN/PARITY docs changed,
parity-check PASS and equivalence recorded. No full test-PG was required: no PG
schema/runtime-adapter/transaction change.

## Web overlay

The pinned-base overlay is qualified and active at Web release `587a197b…`
(index `ee169020…`); hashes, build proof and D38 are unchanged. The old `d4`
release and 19 old immutable chunks remain, the Caddy inode is retained and CSS
bytes are unchanged. No server route or WebSocket frame is added; other clients
refresh on their next roster read, and D23 original bytes/MIME remain unchanged.

## Validation

Production read-only passed 5 checks with 9 explicit read-only SKIP, 0
FAIL/BLOCKED, and all 14 durable rows stayed unchanged. Read-only avatar/profile/
roster/graph/history probes passed 52/52 with 0 failures; owner avatar remains
null and was never modified. No production R2 upload or durability claim is made.

Isolated GREEN passed 52/52 (2 setup, 20 API, 3 bundle proof, 19 UI, 8 post-UI
API): no-reload A→B→C (naturalWidth 32), bad-format 400 keeps C, and fresh
observer/rosters show C; in-memory adapters only, not PG/S3 durability evidence.

The 600 s monitor completed in 600.55 s: 10 rounds x 5 pages = 50 authenticated
HTTP 200 checks, `HEALTHY`, 0 confirmed alerts and 0 uncaught errors; every page
loaded the new app-shell `L_alVVAg.js` and 10 home checks reported Main `1b4565`.
Only the known D5 feedback 404 remains. Root reviewed the production channel
screenshot: layout normal, Cindy online, human avatar normal. No general
performance claim is made.

## Residuals

Saved-item and comment avatars and unknown `joinedAt` remain unfixed. The server
store's `loadMembers` coalescing retains the same race for non-primary channel
search/favorites consumers. No global real-time avatar push or cross-device sync
is promised.

## Route and module limits

The agreed limits are unchanged: C0 has 644 upstream versus 611 Swift routes, 583
exact, 1 variant, 57 raw missing (5 false positives, 52 exclusions) and 27 extra,
with 0 reachable Class C. `PARITY.tsv` has 406 modules, 230 mapped.

## Completion criteria

This avatar rollout is complete within the agreed scope. The `57b6775f` rollback
and all listed assets remain, and no owner avatar mutation, global real-time sync
or production R2-upload claim is made.

## Evidence

Final evidence is under `/mnt/data/raft-swift-development/tmp/avatar-channel-fix-20261112/`:
`production-browser-qualification.json`, `monitor-report.json`,
`production-avatar-readonly-acceptance.json`, `rollback-verification.json`, `GREEN-FINAL.json`; no domains, IPs or tokens enter Git.

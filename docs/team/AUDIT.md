# Audit: remaining partial route modules

Read-only audit of the 17 route rows still marked `partial` in `docs/PARITY.tsv`.
Scope: upstream `packages/server/src/routes/*.test.ts` at
`/mnt/data/tmp/grok/raft-source-v1.21.23` (tag `v1.21.23-source.1`) versus
`Tests/RaftHTTPServerTests`, `Tests/RaftRealtimeTests`, `Sources/RaftHTTP`, and
the route table in `Sources/RaftHTTPServer/FallbackApplication.swift`.

No Sources, Tests, PARITY.tsv, BEHAVIOR.md, or PLAN.md was modified. This file
is the only write.

## Baseline (`make parity`, 2026-11-05)

```
route coverage : 1490/2000 cases locked (partial modules are not credited)
74.5%            (partial rows: 17, pending rows: 0)
```

Largest un-locked rows: internalAgentApi.auth 93, agents.api 87, auth.api 45,
internal.channelMembership.api 43, channels.api 37, oauth.api 34,
channels.membership.api 28, internal.attestedSend.api 25,
internalAgentKnowledge.api 24, internalComputer.agentMigration 22.

## Case counting caveat

`scripts/parity.py` counts `test("…")` / `it("…")` only. Several upstream
files build cases with template literals inside `for (const x of [...])` loops;
those execute N cases but parity counts 1. The table records both:
`parity / executable`. Known undercounts:

- `socketMembershipRevocation.api` 1 / 4 (`for (const transition of [3])`)
- `auth.api` 45 / ~49 (3 register-malformed, 2 login-malformed, 2 trace)
- `agents.api` 87 / 88 (`for (const subkind of [2])`)
- `internal.attestedSend.api` 25 / 27 (3 legacy-malformed)
- `productFeedback.api` 20 / 21 (2 client kinds)

A module locks only when every *executable* case is asserted here or excluded
for a contract reason; exclusions below are limited to tracer/query-spy,
injected orchestrator/IO seams, external services that cannot be reached
black-box, and upstream unit-only tests.

## Cross-cutting findings

1. **The ledger is stale for at least two rows.** `auth.api` and `oauth.api`
   still say `partial`, but the OAuth/email slice (`5247150`) and later slices
   added the exact tests their notes still list as "excluded/pending"
   (mobile OAuth, Apple, durable refresh, avatar upload, retirement; OAuth
   discovery/token/serverinfo/agent events/pixel renderer source). Both rows
   look lockable with no new route code; they need a mapping pass and a ledger
   flip, not a port.
2. **Ten rows are still `auto-seed`** (`attachmentUploadSessions.api`,
   `channelAdmin.api`, `channels.membership.api`, `internal.attestedSend.api`,
   `internalAgentApi.raftbench`, `internalAgentKnowledge.api`, `oauth.api`,
   `productFeedback.api`, `productFeedback.multiApp.api`, `publicServer.api`).
   Their status was inferred from Swift test *names*, never from a behavior
   audit. Several are already close to locked; knowledge and raftbench have
   almost no executable surface here. (`socketMembershipRevocation.api` has a
   real note instead, but is equally unaudited.)
3. **Four rows are dominated by a missing subsystem** and are poor next
   slices: knowledge routes (`/internal/agent-api/knowledge/*` absent; only the
   payload projection exists), raftbench (one massive staging-only case),
   productFeedback.multiApp (multi-app route binding unported);
   internal.attestedSend only lacks the receive-ack route for part of its gap.
4. **Partial rows are not comparable by raw case count.** The
   internalAgentApi.auth row carries 93 cases; its remaining executable gap is
   a handful of assertions. The agents.api row carries 87 cases with ~20+
   missing groups.

## Per-module findings

Legend: *par/ex* = parity / executable cases. "Evidence" is the Swift test file
that currently asserts the group (naming is approximate; verify in the slice).

### 1. agents.api — routes/agents.api.test.ts (87 / 88)

Covered evidence: identity/discovery (`AgentsApiIdentityTests`), create +
runtime config/validation (`AgentsApiCreateTests`, `AgentRuntimeConfigTests`,
`AgentsApiRuntimeValidationTests`, `AgentRuntimeCommandTests`,
`MobileV1120SaveRequestsTests`), server roles (`AgentServerRoleTransitionTests`),
external guard (`AgentExternalRuntimeGuardTests`, `ExternalAgent*`), runtime
forms v2 (`BuiltinRuntimeFormTests`, `AgentRuntimeFormTests`), onboarding
identity adoption (`OnboardingIdentityAdoptionTests`), avatar limit
(`AgentAvatarLimitTests`), start/reset (`AgentsApiLifecycleTests`,
`AgentResetAuthorityTests`), migration cancel (`MachineMigrationCancelTests`).

Missing executable groups (≈20–25 cases): built-in preset catalog scope matrix
(task #322, 6), migration start/assign-machine-vs-active-migration (2), skills
surface + failure statuses (5), workspace-files (2), activity-log /
activity-summaries (2), onboarding Cindy create/refusal (3), DM-task claim +
thread target (4), RFC 071 start/reset breaker (1), v2 protocol field-pointing
(2). Subsystem-heavy but every remaining group is reachable over HTTP.

Exclusions: trace acceptance (`…records runtimeConfig trace acceptance…`),
CDN avatar fetch (`GET /api/avatars serves avatars from the configured CDN`),
client-abort socket release, creator-removal DB fence, trace-phase restore,
trace-event skill failure rows.

Likely Swift: `Sources/RaftHTTP/EmailLogin.swift` (agent create/lifecycle),
`Sources/RaftHTTPServer/FallbackApplication.swift` (agent routes 1851–2320);
new `Sources/RaftHTTP/AgentLifecycle.swift` / `AgentSkills.swift` if touched;
tests under `Tests/RaftHTTPServerTests/AgentsApi*.swift`, new
`AgentSkillsTests.swift`, `AgentActivityLogTests.swift`, `AgentDmTaskTests.swift`.

### 2. attachmentUploadSessions.api — routes/attachmentUploadSessions.api.test.ts (10 / 10)

Covered evidence: disabled create/missing/cancel/complete
(`UploadSessionTests.disabledUploadSessionsFailTyped`), capabilities
(`UploadCapabilitiesTests`), agent capability projection
(`AgentUploadCapabilitiesTests`).

Missing executable group (4–5 cases): the "disabled P2" family — default app
keeps disabled mutation paths typed; capabilities absent returns typed instead
of falling through to attachment serve; disabled direct upload advertises the
legacy-safe limit (no direct threshold); disabled mutation paths never reach
the broad attachment routes; dedicated create limiter 429.

Exclusions: the five `enabled fake …` cases and the non-disclosure/fake-output
cases inject `FakeAttachmentUploadSessionService` and count its calls
(`calls.create`, `requestKeys`). That is a DI/orchestrator seam with no
black-box path; the enabled direct-upload service is not ported.

Likely Swift: `Sources/RaftHTTP/EmailLogin.swift`
(`attachmentUploadSessionCreate/Missing`, around 10265) and
`Sources/RaftHTTPServer/FallbackApplication.swift` 2579–2603; tests
`Tests/RaftHTTPServerTests/UploadSessionTests.swift`,
`UploadCapabilitiesTests.swift`.

### 3. auth.api — routes/auth.api.test.ts (45 / ~49)

Covered: all observable groups map to `EmailLoginTests` (44 tests: providers
gate, Apple web/native matrix, register/legal/append-only/invite/stale,
login codes, profile password/displayLanguage/shareUsageData/gravatar/avatar,
web+desktop+mobile OAuth handoffs, durable refresh replay, retirement) plus
`AuthAccountContractTests` (4) and `AuthIdentityUnlinkTests` (2).

Missing executable: none found. The 2 `login traces … without leaking
credentials` cases use `MemoryTraceSink` and are excluded by the tracer rule;
the three malformed register and two malformed login variants are covered by
the shape-rejection tests here.

Recommendation: verification-only lock (see ranked list). No Sources change
expected; if the mapping pass finds a gap it will be a single HTTP assertion.

Exclusions: login-trace scenarios (tracer sink).

### 4. channelAdmin.api — routes/channelAdmin.api.test.ts (12 / 12)

Covered evidence: role/capability projection + role mutation boundaries
(`ChannelAdminProjectionTests`), invisible private channel (`PrivateChannelAdminBoundaryTests`),
archived write freeze (`ArchivedWriteSurfaceTests`, `ChannelArchiveSurfaceTests`),
member add (`ChannelMemberAddTests`, `ChannelMemberMutationTests`), rename
system message (`ChannelRenameSystemMessageTests`), agent channel management
(`AgentChannelManagementTests`), agent server-role/capability.

Missing executable (3–5): creator+initial-members atomic bootstrap and the
action-card `channel:create` bootstrap (2), archived-name collision projects
the target's restore capability (1), mention-add surfaces recheck effective
authority (1), membership system message causal actor/subtype (1; may already
be inside `ChannelRenameSystemMessageTests`).

Exclusions: channel-role outbox retry/dead-letter (service/DB outbox internals,
no HTTP assertion; injected attempt counters).

Likely Swift: `Sources/RaftHTTP/EmailLogin.swift` channel service paths,
`Sources/RaftHTTPServer/FallbackApplication.swift` 2448–2505, 2679–2700; tests
`ChannelAdminProjectionTests`, `ChannelCreateTests`, `ArchivedWriteSurfaceTests`.

### 5. channels.api — routes/channels.api.test.ts (37 / 37)

Covered: message-display settings, unread/visibility, read-all delegation,
#all hide/restore, rename/description system messages, restore-list exclusion.

Missing executable (≈6–9): Activity All/Done/Restore facet matrix (6; the
`RisingWave serving query` case is external and excludable), unfollow-blocks-
ordinary-replies (1), resume-all-agents skipped count (1), channel:updated
broadcast on create and versioned read-state user-room events (socket frames;
assert via realtime tests or exclude as socket surfaces), receiver push
kill-switch / missing io mount (push seam → exclude).

Exclusions: five query-count / query-shape spies
(`records restore-list phases…`, `constant number of queries`, member batch
query counts), push kill-switch and io-mount rows.

Likely Swift: `Sources/RaftHTTP/EmailLogin.swift` (activity facets/read state),
`Sources/RaftHTTPServer/FallbackApplication.swift` 723–838, 1824–1833,
2323–2448; tests `ChannelDisplaySettingsTests`, `ChannelUnread*`,
`AllChannelVisibilityTests`, `ChannelReadAllDelegationTests`.

### 6. channels.membership.api — routes/channels.membership.api.test.ts (28 / 28)

Covered evidence: visibility/membership rules (`ChannelVisibilityTests`,
`AllChannelVisibilityTests`, `ChannelJoinTests`), member add/remove
(`ChannelMemberAddTests`, `ChannelMemberMutationTests`,
`ChannelMemberRemovalArchiveTests`), hidden directory (`HiddenHumanDirectoryTests`,
`AgentChannelsTests`), saved private membership
(`SavedPrivateMembershipTests`), batch add (`ChannelMembersBatchTests`).

Missing executable (≈5–8): GET /channels/dm list phases (query spy → exclude),
DM last-message summaries with non-UUID senders (1), newly-created user DM
hidden from the passive peer (1), DM cannot bypass a hidden directory (1),
authoritative sender membership status in message payloads (1), private-channel
creator leave loses every visibility surface (1), removing from #all writes no
notice (1), self join/leave `channel:members-updated` frames (socket).

Exclusions: DM list query-phase spy, batch "fixed number of queries" spy,
human-add rollback on notice persistence failure (fault-injected DB failure).

Likely Swift: `Sources/RaftHTTP/EmailLogin.swift` (DM creation/list, membership
service), `Sources/RaftHTTPServer/FallbackApplication.swift` 2369–2386,
2441–2500; tests `DirectChannelTests`, `ChannelMember*`, `SavedPrivateMembershipTests`.

### 7. internal.attestedSend.api — routes/internal.attestedSend.api.test.ts (25 / 27)

Covered evidence: `InternalAgentSendHoldTests` (19 tests: hold/first-touch,
seen boundary, draft commit/rehold/anyway, mention count inside boundary,
channel-card hold, DM/thread context identity, deprecated continue, malformed
legacy bodies with side-effect assertions).

Missing executable (≈8–10): default-off preserves normal send and default-on
does not gate legacy sends without a marker (2, `sendFreshnessModeValue`
exists but only `"force"` is tested), E1 formal-mention exemption + left-
exclusive range (2; no `e1_exempt` in Sources), legacy receive-ack volatile /
per-channel / thread-DM checkpoints (3; `/internal/agent-api/receive-ack` route
is not registered), new-thread seed + concurrent first replies (2), replacement
metadata client-declared event-only (1), target-scoped hold variants (2).

Exclusions: trace/activity assertions embedded in the malformed-body and
"records e1_exempt" rows (MemoryTracer/MemoryTraceSink), tracer phases.

Likely Swift: `Sources/RaftHTTP/EmailLogin.swift` (freshness mode around
22887–23050, send handler around 21381), `FallbackApplication.swift`
1297–1311; tests `InternalAgentSendHoldTests`, `AgentSendFreshnessContextTests`.

### 8. internal.channelMembership.api — routes/internal.channelMembership.api.test.ts (43 / 43)

Covered evidence: agent self-service join/leave/unfollow
(`AgentMembershipRouteTests`), server info runtimeContext, channel
create/update/member add/remove for agent admins
(`AgentChannelManagementTests`, `AgentChannelCapabilityTests`), exact denial
payloads, archive lifecycle concurrency (`ChannelArchiveTests`), reactions
cloak (`AgentReactionContractTests`), task parent membership
(`TaskChannelMembershipTests`), status filter, #all leave refusal.

Missing exec/needs subsystem: legacy long-poll receive (4 cases; route absent;
3 are trace-dominated and excludable, "refresh amended task" and "drop queued
private messages after removal" need the receive route), CLI e2e matrix (9
`CLI e2e: slock …` cases; Node CLI is not shipped and each HTTP behavior has a
direct-HTTP mirror case), joint-task cases (exclude: joint model unported),
createChannels denial payload (1, verify), lifecycle born-read under concurrent
retries (1, verify).

Exclusions: receive trace phases/timeout/HTTP-span-on-abort; CLI e2e driver;
joint channel/task surfaces.

Likely Swift: `Sources/RaftHTTP/EmailLogin.swift` (agent membership/server),
`FallbackApplication.swift` 1006–1130; tests `AgentMembershipRouteTests`,
`AgentChannelManagementTests`, `AgentServerInfoTests`.

### 9. internalAgentApi.auth — routes/internalAgentApi.auth.test.ts (93 / 93)

Covered evidence (broad): bound identity/server info/history/task flows,
history windows/exact-seq/consume, mentions, search, resolve, thread list/
unfollow, profile show, reactions, upload/id-less upload/download,
integrations discovery/login/marketplace/register card/whenToUse/manifest
fallback, app list/status hiding, installationId scoping, task
claim/status/delete/convert/assign/receipts, scopes/capability gates, computer
credential surfaces, DM tasks (partial).

Missing executable (≈6–8): `/tasks/resource-receipt` + `requiresResourceReceipt`
+ owner-anchored expiry reminder (1; route absent), bulk task-create inbox
fan-out facts (1), generic action prepare rejects integration approval cards
(1), integration app prepare private-IPv6 unsafe-override (1), unicode PDF
filename download (1; only a space-containing name is asserted), read-only
credential denied on mutating agent-api routes (1; only mentions/join read-only
is asserted), activity-ingest transcript-path gate (1), roster batch activity
read (maybe covered by `ChannelMemberActivityTests`).

Exclusions: constant-query-count task-mine case (query spy), credential auth
phase traces, transient owner secret wake (orchestrator delivery), assignment
rollback/post-commit fan-out failure injection, joint storage/forwarded
snapshot cases (joint model), aborting upstream download socket.

Likely Swift: `Sources/RaftHTTP/EmailLogin.swift` (task create/resource receipt,
action prepare, attachment download, credential gate),
`FallbackApplication.swift` 1297–1610; tests under `AgentApi*.swift`,
`IntegrationAppQueryTests`, new `AgentResourceTaskTests.swift`.

### 10. internalAgentApi.raftbench — routes/internalAgentApi.raftbench.test.ts (1 / 1)

One 254-line case drives `/internal/agent-api/raftbench/{context,submit}` and
`push-webhook` plus `raftbenchConfigs/runs/serviceAgents`, staging-only
`DEPLOYMENT_ENV`, Antiproton provider URL policy and encrypted webhook secrets.
No route is registered here and the whole subsystem is absent. High effort for
1 case — defer; optional exclusion as staging-only synthetic-analysis service
plus external Antiproton provider integration, but it does have HTTP
assertions, so exclusion should be a lead decision, not automatic.

### 11. internalAgentKnowledge.api — routes/internalAgentKnowledge.api.test.ts (24 / 24)

Only `Sources/RaftHTTP/AgentKnowledgeSearch.swift` (payload projection) and
`Tests/RaftHTTPTests/AgentKnowledgeSearchTests.swift` (2 unit tests) exist. All
`/internal/agent-api/knowledge/*` routes are absent, so the corpus, aliases,
telemetry, headers, intent/reason/capability gates and Manual compatibility are
unimplemented. High effort; defer.

### 12. internalComputer.agentMigration — routes/internalComputer.agentMigration.test.ts (22 / 22)

Covered evidence: target import drive (`MigrationTargetImportTests`), cancel ack
(`MigrationCancelAckTests`), manifest/chunk receipts
(`MigrationTransportChunksTests`), body limits
(`MigrationControlBodyLimitTests`), one transport-lost reason and admission
gates (`MachineMigrationTransportTests`), resumable control/upload.

Missing executable (≈11–12): typed transport-lost reasons — object-store,
manifest-size, target-disk, workspace conflict over fallback, entry-count (5),
archive retried after flip (2), wake-lock-skipped start not completed (1),
repeated flip/arrive idempotency (2), old generation rejected (1), holder moved
rejected (1), source-machine drive attempt (1), legacy completed row
reconciliation (1), post-flip cancel "cleaned" not terminalized (1).

Exclusions: none needed beyond DB/outbox internals if they appear; this module
is mostly executable HTTP.

Likely Swift: `Sources/RaftHTTP/EmailLogin.swift` migration state machine
(~12600–13500), `FallbackApplication.swift` 3168–3249; tests
`MigrationTargetImportTests`, `MachineMigrationTransportTests`,
`MigrationCancelAckTests`.

### 13. oauth.api — routes/oauth.api.test.ts (34 / 34)

Covered evidence: discovery (`OAuthDiscoveryTests`), token/client auth
(`OAuthTokenTests`), installation/principal surfaces
(`OAuthInstallationLookupTests`, `OAuthInstallation*`), userinfo/serverinfo
(`OAuthUserinfoTests`, `OAuthServerinfoTests`, `OAuthAgentServerinfoTests`),
agent directory/request/inbound scopes (`OAuthAgentDirectoryTests`,
`OAuthAgentRequestTests`), client lookup/email scope/grandfather
(`OAuthClientLookupTests`, `OAuthEmailScopeTests`, `OAuthScopeGrandfatherTests`),
retired client (`OAuthRetiredClientTests`), marketplace/global
(`OAuthMarketplaceLookupTests`, `OAuthGlobalMarketplaceTests`), offline source
(`OAuthOfflineSourceTests`), PKCE/redirect (`OAuthPKCETests`,
`OAuthRedirectSecurityTests`), third-party events (`AgentInboxTests` drain/
replay/concurrent/unbound, `AgentEventReadTests`).

Missing executable (≈2–4): legacy `slock_secret_`-prefixed client secret
accepted by client auth (1; reachable through the token endpoint by seeding a
legacy-shaped hash — upstream asserts it via the private function, so a small
test + optional source acceptance shim), managed-runtime `/events` cold-start
rebuild (1; verify against `AgentInboxTests`), provenance-prose wording (1;
verify). Pixel-avatar cases (2) are upstream *unit-only* renderer calls; the
SVG is served by `GET /api/avatars/pixel/:file`, so they may be ported as an
HTTP byte assertion or excluded as unit-only per contract.

Exclusions: token unexpected-exchange log/audit redaction (log sink).

Likely Swift: `Sources/RaftHTTP/OAuthLedger.swift`,
`Sources/RaftHTTP/OAuthDiscovery.swift`, `Sources/RaftHTTP/EmailLogin.swift`
(OAuth routes), `FallbackApplication.swift` 3518–3870; tests `OAuth*Tests`,
`OIDCAuthorizeTests`, `AgentInboxTests`.

### 14. productFeedback.api — routes/productFeedback.api.test.ts (20 / 21)

Covered evidence: `ProductFeedbackAttributionTests` (3), 
`ProductFeedbackDiagnosticsTests` (4), `ProductFeedbackSubmitTests` (5),
`ProductFeedbackTests` (fails closed without Hands). 

Missing executable (≈4–6): fixed duration-only upstream timing metrics (1),
server-derived contact formatting (1), reporter attribution omit cases
(malformed X-Server-Id / no server context / multi-server — partly covered; 1–2
left), close-entry sanitized failure stage (1, log), joint pseudo-server
attribution refusal (1, verify), server-row-disappears mid-flight (1; DB
injection → exclude).

Exclusions: close-entry log-only assertion; mid-flight DB row deletion.

### 15. productFeedback.multiApp.api — routes/productFeedback.multiApp.api.test.ts (7 / 7)

Multi-app route binding (per-client app token/route root, 503 when app missing,
cross-source ticket/cursor isolation) is not ported; `productFeedback.ts` has
no app-binding lane here. Implementing the apps JSON binding is real feature
work for 7 cases. Defer (or adjudicate as unported multi-app binding, lead
decision).

### 16. publicServer.api — routes/publicServer.api.test.ts (21 / 21)

Covered evidence: `PublicServerMessagesTests` (16: anonymous surface/history,
display-only attachments/mentions/reactions, typed names, PDF inline,
presigned URLs, translation budget, attachment rate budget), `PublicVisitsTests`
(self-join guest-only/agreement/recheck), `PublicSearchSettingsTests`
(owner-only flip), `PublicFeatureFlags*`.

Missing executable (≈5–6): rollout flag defaults closed at owner and anonymous
boundaries (1), making a channel private clears both Guest audience flags (1),
owner-only Guest admission gate and clearing when Public turns off (1), valid
Guest email invite stays independent of Public self-admission (1), logged-out
visitor leaves no state (1), member server list exposes `publicPageLive` (1).

Exclusions: "evaluates the public-page gate once for all public servers"
(query-count spy).

Likely Swift: `Sources/RaftHTTP/PublicServerDirectory.swift`,
`PublicHistory.swift`, `PublicAttachments.swift`, `PublicVisits.swift`;
`FallbackApplication.swift` 333–610, 3498–3520, 4069–4098; tests
`PublicServerMessagesTests`, `PublicVisitsTests`, `PublicSearchSettingsTests`.

### 17. socketMembershipRevocation.api — routes/socketMembershipRevocation.api.test.ts (1 / 4)

Covered evidence: server-member removal notice ordering and family revocation
(`RealtimeServerTests.membershipRemovalSendsTheNoticeLastAndOnlyToThatServer`,
`familyRevocationClosesOnlyThatSessionFamily`), socket room contract.

Missing executable (4): guest `join:channel` + `sync:resume` must hide a
non-guest-visible channel's messages and thread messages (1), and after
`remove-private-member` / `leave-private-channel` / `remove-server-member` the
socket must stop delivering that private channel's live messages and task
events (3 loop cases).

Exclusions: none needed. The upstream test wraps a server-side
`socket.listeners("join:channel")` handler to await completion; the port can
await the `sync:resume:response`/`rooms:joined` frames instead, so the
assertions stay black-box. The 3 loop cases are only counted as 1 by parity.

Likely Swift: `Sources/RaftRealtime/RealtimeServer.swift`,
`Sources/RaftRealtime/SocketIOProtocol.swift`; tests
`Tests/RaftRealtimeTests/RealtimeServerTests.swift`.

## Ranked shortlist — best next slices by executable cases per effort

Expected credit assumes the module locks (all executable cases asserted, others
excluded with a ledger reason).

### 1. auth.api — verification-only lock (`+45` cases, ~0.3 turn)

Why: every observable upstream case already has a Swift assertion; the row is
stale, not incomplete. This is the cheapest credit on the board and shrinks the
route gap by 2.25 points.

Steps: (a) map all 45 cases to the named tests above; (b) run the two auth test
files (bounded `swift test --filter EmailLoginTests`,
`--filter AuthAccountContractTests`); (c) append the locked-behavior summary to
`docs/BEHAVIOR.md` (provider gates, OAuth handoffs, Apple matrix, replay,
retirement, profile rules); (d) flip the `auth.api` row to `locked` with the
commit; (e) note in the row that the 2 login-trace cases are tracer-only
exclusions. Expected: no Sources change; if the mapping finds a gap, add one
HTTP test (most likely candidate: web social completion "unified transaction
table" row already covered — no gap expected).

Risk: if the lead requires at least one code change per slice, pair it with the
`channelAdmin.api` micro-gap below in the same turn (different files).

### 2. internalAgentApi.auth — finish the bound-agent surface (`+93` cases, ~1.5 turns)

Why: highest absolute credit; the remaining gaps are small additions on already
registered routes, and the exclusion set is stable.

Slice content (target ~6 tests):
1. resource task: `creates_resource` projection + `requiresResourceReceipt` +
   `POST /internal/agent-api/tasks/resource-receipt` validation + done gate
   (409 `"resource receipt required before task can move to done"`) + expiry
   reminder row; exclude the `pushReminderUpsert` spy count and assert the
   reminder only through the reminders HTTP surface/inspected row.
2. bulk task create: one request with N assignees, assert one inbox fact per
   recipient and no duplicates (assert via `/internal/agent-api/inbox` rows,
   not orchestrator wake counters).
3. generic action prepare: rejects integration approval cards; DM-thread target
   prepare succeeds.
4. integration app prepare: private IPv6 literal URL needs the unsafe override
   flag; invalid scopes/categories rejected before card creation.
5. unicode PDF download: filename with non-ASCII characters round-trips in
   `Content-Disposition`; cloaked access redirect ordering preserved.
6. read-only credential: a `read`-only agent credential is denied on mutating
   agent-api routes (`send`, task mutations, upload) with the typed
   capability denial; activity ingest is read-gated and rejects transcript
   paths.

Likely files: `Sources/RaftHTTP/EmailLogin.swift` (task create/resource receipt,
attachment download, credential gate), `FallbackApplication.swift`
1297–1610, tests `Tests/RaftHTTPServerTests/AgentResourceTaskTests.swift`
(new), `AgentApiIdlessUploadTests`, `IntegrationAppQueryTests`,
`AgentAttachmentDownloadURLTests`.

Exclusions to record: query-count task-mine case, credential auth phase
traces, transient owner secret wake (orchestrator), assignment rollback /
post-commit fan-out failure injection, joint storage/forwarded snapshot, abort
of upstream download socket.

Risk: the 93-case row may hide one more straggler (e.g. roster batch activity);
reserve one verification pass over the test titles after the six tests land.

### 3. oauth.api — close the OAuth surface (`+34` cases, ~0.7–1 turn)

Why: 28–30 of 34 cases already asserted; the remaining work is one source shim
plus two/three targeted assertions. Second-best credit per effort and it makes
the whole `oidc/` + `/api/oauth/*` block count.

Slice content:
1. legacy client secret: accept `slock_secret_<48 hex>` when the stored hash is
   legacy-shaped, and reject the raft-shaped secret in that row (source change
   in `OAuthLedger`); assert through `POST /api/oauth/token` (Basic +
   `client_secret_post`) rather than the private function.
2. managed-runtime third-party `/events` cold-start rebuild: assert queued
   events are rebuilt from durable rows and marked delivered on `/events` ack
   (extend `AgentInboxTests`, reuse `POST /api/oauth/agent-events`).
3. provenance wording: assert the third-party event endpoint preserves
   `source` provenance and adds no warning prose.
4. pixel avatar: decide once — either add `GET /api/avatars/pixel/:file` byte
   assertions matching the web PRNG fixture (the renderer already exists in
   `Sources/RaftHTTP/PixelAvatars.swift`) or exclude both cases as upstream
   unit-only.

Likely files: `Sources/RaftHTTP/OAuthLedger.swift`,
`Tests/RaftHTTPServerTests/OAuthTokenTests.swift`, `AgentInboxTests.swift`,
new `PixelAvatarRouteTests.swift` if ported.

Exclusions: token unexpected-exchange redaction (log/audit sink); pixel cases
only if the lead prefers strict unit-only exclusion.

Risk: managed-runtime `/events` rebuild may expose a real gap in the inbox
replay; if so it is a small extension of the existing replay, still inside this
slice.

## Runners-up (cheap wins after the top three)

- **channelAdmin.api** (`+12` for ~0.5 turn): archived-name collision restore
  capability, action-card `channel:create` bootstrap, mention-add authority.
  Pairs well with the auth.api verification turn (different files, no conflict).
- **publicServer.api** (`+21` for ~1 turn): rollout-flag default-closed,
  channel→private clears Guest flags, owner-only Guest admission, Guest email
  invite independence, member list `publicPageLive`.
- **socketMembershipRevocation.api** (`+4` for ~0.75 turn): guest
  join/resume visibility plus the three membership-transition delivery
  suppressions; smallest module, real socket assertions, and it exercises
  `sync:resume`.
- **channels.membership.api** (`+28` for ~1.5–2 turns) and
  **internal.attestedSend.api** (`+25` for ~2 turns, needs the receive-ack
  route) are the next tier.
- **agents.api** is the biggest remaining prize but needs ~20–25 edge-case
  tests; schedule after the block above.

## Deferred / probably not worth a slice now

- `internalAgentKnowledge.api` (24): whole knowledge route family absent.
- `internalAgentApi.raftbench` (1): one huge staging-only case, whole subsystem
  absent; keep as ledger adjudication candidate.
- `productFeedback.multiApp.api` (7): multi-app route binding absent.
- `internalComputer.agentMigration` (22): typed transport-lost/archive-retry
  state-machine work; medium-high effort, schedule when migration is next in
  the plan.
- `channels.api` (37): Activity facet matrix is the bulk; decide first whether
  the RisingWave serving query is in scope (external) before committing.

## Method notes / limitations

- Evidence is static: test titles, route tables, ledger notes, source grep.
  No full suite was run. `make parity` was run once (bounded, <1 min); no test
  target was executed because this audit adds no code and the existing tests
  are shared with the implementation slices.
- "Covered" means a Swift test name/shape plausibly asserts the group; the
  chosen slice must still fail-first each assertion before flipping the ledger.
- Case counts for loop-generated upstream tests are conservative (see caveat);
  parity credit still uses the parity.py count.
- Expected post-top-3 route coverage: `1490 + 45 + 93 + 34 = 1662/2000 = 83.1%`
  (plus `+12` if `channelAdmin.api` rides along → 83.7%).

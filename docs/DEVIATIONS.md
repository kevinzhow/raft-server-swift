# Deliberate deviations from upstream

This is the curated list of where the Swift port intentionally differs from
`raft-source` tag `v1.21.23-source.1`, and of upstream assertions that were
adjudicated as non-executable here. It replaces the append-only
`docs/BEHAVIOR.md` log (removed; history remains in git).

Use this file when reviewing a parity claim, when someone asks "why is this not
implemented?", or before adding a new exclusion. Each entry records **what**
differs, **why**, the **upstream reference**, and the **trigger that should make
us re-evaluate**. Per-module notes remain in `docs/PARITY.tsv`; this file holds
the durable decisions, not a restatement of every test name.

Rules:

- A deviation is deliberate only if it is listed here (or in a module note that
  points at an entry here) and the observable public path it does implement is
  still locked by tests.
- Locked parity cases never imply a deviation is absent. Check this file before
  claiming a complete upstream path.
- Do not use an entry here to justify fabricated success payloads. Unsupported
  capabilities fail explicitly (503/404/410/`unsupported`), they do not return
  invented state.
- Re-evaluate an entry only when its trigger fires or the owner changes scope.
  Do not silently widen an exclusion.

## Environment and architecture

### D1. In-memory authoritative backend, optional PostgreSQL

**What.** Development mode keeps domain state in memory. Production restores
retained owners from PostgreSQL under a fenced writer. Some upstream assertions
observe database rows, transactions or locks directly.
**Why.** The port is a server reimplementation, not a database reimplementation.
The in-memory backend keeps the HTTP/socket contract testable without infra; the
production path adds persistence without changing the published contract.
**Upstream.** `agentApiIdempotentWrites.realPg`, `agentMigrationFence.realPg`,
`inboxPressure.realPg`, `publicSearchSettingsFence.realPg`,
`readMutationFence.realPg`, `releaseNotesConcurrency.realPg`,
`internalAgentApi.systemThread.realPg` and the `*.realPg` rails generally; row /
lock / advisory-lock assertions inside ordinary route modules.
**Re-evaluate.** If a defect can only be reproduced through a DB row or lock
ordering and the observable HTTP result is identical, add a `realPg` acceptance
rail under `Tests/RaftServerStartupTests` (run by `make test-pg`) instead of
porting the row assertion.

### D2. Vapor HTTP plus SwiftNIO listeners

**What.** HTTP is Vapor (pinned revision), `/daemon/connect` is a raw SwiftNIO
listener on `DAEMON_CONNECT_PORT`, and Socket.IO is a SwiftNIO listener on
`SOCKET_PORT`. Upstream is one Node HTTP server carrying all three.
**Why.** The pinned Vapor snapshot has no WebSocket upgrade, and the daemon
protocol needs exact handshake bytes that Vapor's HTTP stack cannot provide.
**Upstream.** `packages/server/src/index.ts` server/bootstrap and
`packages/daemon` connect path.
**Re-evaluate.** Only if the pinned Vapor revision gains a compatible upgrade
path and the daemon byte-level handshake can be preserved exactly.

### D3. `/health` is 503 without a database

**What.** With no `DATABASE_URL` the process stays up and `/health` returns
`503 {"status":"error","detail":"database unreachable"}`.
**Why.** The published degradation contract: no database means the business
surface is not healthy, but the process still serves diagnostics and `/livez`.
**Upstream.** server health route; upstream requires a working database to boot.
**Re-evaluate.** Only with an explicit product decision to serve degraded.

### D4. Web assets are served by the gateway, not by Main

**What.** Main does not serve static Web files. A Caddy `file_server` serves an
immutable versioned directory; the browser and Computer reach the same origin
through Cloudflare.
**Why.** Keeps one static-server implementation and avoids shipping an
unreviewed Node/Web runtime inside Main.
**Upstream.** upstream server mounts the built Web assets.
**Re-evaluate.** If Main must become self-contained for an environment without
the gateway.

### D5. External provider and integration services are not ported

**What.** Hosted agent runtime providers, the Grafana interop container, the
Slack bridge control plane, Hands feedback proxying, CDN/object-storage upload
resource flows and the OTLP trace relay are absent or answer explicit refusal
(503/404/410). Provider-connection test/models endpoints return 410.
**Why.** These are external services with their own protocols and credentials;
the repository contract excludes porting them for test-only assertions.
**Upstream.** `agentRuntimeProviders.api`, `agentAudienceJwt.grafana`,
`slackBridge.api`, `integrations.api`, `otlpRelay`, `productFeedback.api` (Hands
paths), attachment CDN/storage streaming cases.
**Re-evaluate.** If the owner deploys one of these services and the public path
must reach it; implement it as a real adapter with its own acceptance rail, not
as a stub.

### D6. The official Computer/provider acceptance is separate

**What.** The suite locks the daemon wire protocol with controlled peers and
real HTTP/PG/NIO, not an official Computer/Codex/provider run.
**Why.** Official Computer and model providers are external processes with their
own versions and credentials; coupling them to `make gate` would make the gate
unreproducible.
**Upstream.** `packages/daemon` integration suites and provider-backed agent
execution cases.
**Re-evaluate.** Run the official Computer acceptance after any daemon protocol
change; keep the result in the deployment record, not in the unit gate.

## Product-scope exclusions

### D7. Legacy machine-on-behalf attested send is bounded

**What.** `POST /internal/agent/:agentId/send` implements the published legacy
body, refusals, targets, success envelope and idempotency, and the freshness
hold envelope for the legacy path. The credential-route `sendV2` does not exempt
formal mentions from the freshness funnel. Tracer spans, the orchestrator
capability patch and unmute-history details are excluded.
**Why.** Normal CLI and official Computer use credential `sendV2`; the legacy
path exists for older machines. Its tracer/orchestrator internals have no
black-box surface.
**Upstream.** `internal.attestedSend.api` and `docs/PARITY.tsv` notes.
**Re-evaluate.** If a supported client still calls the legacy send with fidelity
requirements beyond the locked body/target/refusal contract.

### D8. No durable-inbox RisingWave chain or cross-replica wake

**What.** Durable inbox pull, inbox push merging, the external inbox chain and
cross-replica wake dispatch are not ported. Read-position semantics are locked
by `internalAgentApi.historyUnread`; wake-hint SSE framing by
`internalAgentApi.wakeHintStream`; offline queueing uses the retained pending
delivery facts.
**Why.** Those assertions depend on an unported RisingWave chain, an
`AgentOrchestrator` stub and test-only selectors; no black-box HTTP path reaches
them.
**Upstream.** `internalAgentApi.externalInboxPull`, `internalAgentApi.inboxPush`,
`internalAgentApi.crossReplicaWake`, `agentCredentialSecurity.api`.
**Re-evaluate.** If a durable inbox backend is actually deployed and the user
path depends on its ordering or wake-up semantics.

### D9. Socket subscription/visibility eviction is not implemented

**What.** Guest policy, role-demotion, public-to-private and hidden-channel
subscription eviction, and send-time audience room delivery are not ported.
Channel room membership is enforced by the existing join/room logic.
**Why.** The upstream channel-subscription epic does not exist as a separate
surface in this port; the observable HTTP/JSON behavior is locked by the channel
and RBAC modules.
**Upstream.** `securityLifecycle.api`, `socketSendTimeAudience.api`,
`roomTargeting.contract`.
**Re-evaluate.** When a second realtime client kind or subscription model is
added.

### D10. Realtime gap-recovery and activity-trajectory internals

**What.** `/api/channels/activity/snapshot` and `/difference` answer 400 with the
`X-Raft-Contract: raft.activity-sync;revision=2` header instead of implementing
gap recovery. Socket `agent:activity` payloads keep the last activity and detail
but not trajectory `entries`; there is no provider-backed activity log.
**Why.** The pinned Web does not consume provider activity logs and strips
`entries` from the public payload; storing a trajectory would be invented state.
**Upstream.** `internalAgentApi.agentStatus`, activity snapshot/difference
contracts.
**Re-evaluate.** If the pinned Web starts consuming activity history or gap
recovery; then add real retained facts first.

### D11. Opener variants: legacy instruction path and hosted extras

**What.** The owner onboarding briefing implements the pinned opener-v2 path.
With the opener flag explicitly off it returns `openerDisabled` and sends no
legacy instruction text. Hosted Cindy specifics and the Day-2 recap are out of
scope.
**Why.** The deployed environment uses opener v2 and the legacy text is not
reachable from the official Web.
**Upstream.** owner onboarding briefing / opener-v2 cases.
**Re-evaluate.** If the flag is turned off in production or a legacy client is
still supported.

### D12. Billing, joint-channel/server model and built-in app conversations

**What.** The billing surface, joint channels across two servers (no
`server.kind`), and built-in app conversations such as `#system.canary` are not
implemented.
**Why.** Not part of the delivered product surface; no consumer in the pinned Web
uses them here.
**Upstream.** `billing.api`, `channels.joint.api`, `internalAgentApi.userChannels`
(built-in app case), `productFeedback.api` (pseudo-server kind row).
**Re-evaluate.** Only with an explicit product scope change.

### D13. Image, document and archive pipelines

**What.** The Node `sharp` image pipeline (EXIF/HEIC/SVG raster), the XLSX
worker-pool preview, and workspace archive/migration file trees are not ported.
Attachment preview is bounded to stored bytes, HTML preview bridging and the
supported download/inline rules.
**Why.** Those pipelines require native image/office dependencies and an
archive worker that are not part of the server contract.
**Upstream.** `attachments` helper module, attachment preview cases, agent
archive/migration export rails.
**Re-evaluate.** If thumbnails or office previews become a user-facing
requirement; add one real pipeline with its own acceptance rail.

### D14. Explicit refusals instead of fabricated state

**What.** Unknown historical metadata, TTLs, survey/handoff intros and physical
workspace deletion are not invented. Active joint HUMAN writes and physical
workspace deletion answer 503; unknown survey/handoff facts stay null; missing
follow time/reason is not synthesized from other timestamps.
**Why.** The presentation layer must not fabricate facts it did not retain.
**Upstream.** survey/handoff, workspace and legacy metadata cases.
**Re-evaluate.** When the corresponding fact is durably written by a real path.

## Adjudicated non-executable upstream assertions

These upstream cases assert things that have no public black-box surface here.
Their user-visible HTTP/socket behavior is locked by the module that remains
listed in `PARITY.tsv`; the excluded assertion itself is not reimplemented as a
stub.

### D15. Trace/span and log-capture assertions

**What.** Span attributes, tracer sink events, structured console diagnostics and
log-capture checks are not ported.
**Why.** The repository contract excludes trace sinks; logs are operational, not
a published contract.
**Upstream.** `authLoginTrace`, `authRefreshTrace`, `authRefreshAttemptRoute`,
`agentApiErrorTrace`, `agentProfileWriteBroadcastContract`, product-feedback
close diagnostics.
**Re-evaluate.** If trace/log output becomes a supported operator contract.

### D16. Orchestrator, spy and failpoint injections

**What.** Cases that only observe an injected orchestrator/spy/fake transport,
test-only race hooks, throttle hooks or failpoints are not ported.
**Why.** Contract: private helpers, query spies, tracer sinks, failpoints and
orchestrator injection are not ported unless the HTTP/frame result is the
assertion.
**Upstream.** `internalAgentApi.idempotentWrites`, `internalAgentApi.send`
orchestrator cases, `publicSearchServiceAccess.api` limiter ordering,
`agentCredentialSecurity.api` seen-touch throttling, `internal.reminders.api`
socket dispatch internals.
**Re-evaluate.** If the injection point becomes a real deployed dependency.

### D17. Source-scan and AST contracts

**What.** Assertions produced by scanning TypeScript source or config files are
not reproduced.
**Why.** This is a Swift port; there is no equivalent source artifact to scan.
**Upstream.** `agentMigrationErrors.contract`, other `*.contract` source scans
that target Node source.
**Re-evaluate.** Only for a genuinely runtime-observable behavior.

### D18. CLI subprocess end-to-end assertions

**What.** Cases that run the `raft` CLI as a subprocess and assert its stdout are
not ported as server tests; the corresponding HTTP semantics are locked.
**Why.** The CLI is a separate executable; the server contract is the HTTP/JSON
it consumes.
**Upstream.** `internal.search.api` CLI-output cases.
**Re-evaluate.** If the CLI becomes a deliverable with its own e2e gate.

### D19. Benchmark and staging-only services

**What.** `raftbench` synthetic analysis and staging-only integrations are not
registered or emulated.
**Why.** No local production consumer; they are external staging infrastructure.
**Upstream.** `internalAgentApi.raftbench`, `raftbench.api`,
`raftbench.canary.api`, `raftbench.progressive.api`.
**Re-evaluate.** If those services are deployed for load testing.

### D20. External-container interop

**What.** Cases that start an external container (for example Grafana) through
Docker and drive a real provider protocol are not run in the gate.
**Why.** Non-reproducible in the unit gate and already covered at the wire level
by the built-in OIDC/JWT suites.
**Upstream.** `agentAudienceJwt.grafana`.
**Re-evaluate.** As a separate deployment acceptance when Grafana is actually
configured.

### D21. Redis atomic Lua and multi-replica ordering

**What.** Redis `EVAL`-based atomic limiters and multi-replica ordering cases are
not ported.
**Why.** The limiter and replica infrastructure is not part of this deployment;
the in-process behavior that remains is locked.
**Upstream.** `publicSearchServiceAccess.api` Redis adapter cases,
cross-replica modules.
**Re-evaluate.** When a Redis-backed limiter or multi-replica writer is deployed.

### D22. Attachment helper and upload-session service injections

**What.** Exported attachment helper units (URL builders, filename normalization,
RFC5987, MIME normalization) and six enabled upload-session fake-service cases are
excluded; the observable attachment HTTP behavior is locked by
`attachments.api`, `attachmentPreviewBridge.api`, `attachmentComments.api` and
`attachmentUploadSessions.api` default surface.
**Why.** Helper-unit and fake-service assertions have no black-box HTTP surface.
**Upstream.** `attachments`, `attachmentUploadSessions.api` enabled-fake cases.
**Re-evaluate.** If a new public upload path is added.

### D23. Malformed-JSON bodies and multi-key strict ordering

**What.** The auth body-schema routes report a missing or malformed JSON body as
`req.body ?? {}` (the schema's required-member issues). Upstream Express also
answers a 400 for malformed JSON, but with the JSON parser's own body before the
route runs. When a `.strict()` auth schema receives several unknown members, the
published `Unrecognized keys` list is sorted by key; upstream prints zod's
received member order.
**Why.** The shared request helper returns `nil` for both "no body" and
"unparseable JSON", and the shared `JSONValue` object is a dictionary without
member order. The projected status (400) and every single-key issue are identical.
**Upstream.** `routes/auth.ts:126-158` (`formatBodyIssues` and the four schemas)
and `express.json()`'s error path; zod 4 `unrecognized_keys` ordering.
**Re-evaluate.** If the request layer exposes whether a body was parsed, or an
ordered JSON object is adopted for request bodies.

## Maintaining this list

1. Add an entry only after the excluded assertion is understood and the
   remaining public path is locked.
2. Put the module name in `docs/PARITY.tsv` notes and reference the entry id
   here (`see docs/DEVIATIONS.md#d15`).
3. When a trigger fires, re-open the module, implement the real path and update
   both this file and the parity ledger in the same commit.
4. Never delete an entry silently; mark it superseded with the commit and the
   reason.

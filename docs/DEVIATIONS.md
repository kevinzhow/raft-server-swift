# Deliberate deviations from upstream

This is the curated list of where the Swift port intentionally differs from
`raft-source` tag `v1.21.23-source.1`, and of upstream assertions that were
adjudicated as non-executable here. It replaces the append-only
`docs/BEHAVIOR.md` log (removed; history remains in git). Route-level raw-table
adjudication (the 5 parser false positives, 57 raw missing, 27 raw extras and
their class counts) is in [ROUTE-DEVIATIONS.md](ROUTE-DEVIATIONS.md).

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

This entry names only the excluded external integration backends. It is **not**
a claim that this deployment has no external services. Cloudflare Email Sending
is configured for transactional email
(`Sources/RaftHTTP/Support/TransactionalEmailCloudflare.swift`;
`docs/DEPLOYMENT.md`), and the encrypted private R2/S3 object bucket is
configured and used for attachments and profile assets (D24). The excluded
storage flow above is the upstream public CDN upload-resource pipeline, not that
private bucket. `integrations.api` also covers the App-side bot routes:
`POST /api/app-bot/token` (OAuth access token to managed-bot credential
exchange; `packages/server/src/app.ts:825-833`,
`packages/server/src/routes/integrations.ts:894-990`) and
`POST /api/integrations/clients/:id/install/bot` (managed-bot grant/revoke;
`routes/integrations.ts:813-885`).

The Slack family is deliberately asymmetric. `GET /api/slack-bridge/provisioning`
is registered and answers `503 {"ok":false,"code":"slack_bridge_provider_unavailable"}`;
`POST /oauth/start`, `POST /events` and `GET /oauth/callback` answer the same
503. The six provisioning mutations (`POST connect`, `PUT/DELETE channel-pairs`,
`POST disconnect`, `POST preflight`, `POST enable`) are not registered and fall
to the fallback 404. `HumanAdmissionMiddleware.swift:54-61` already lists all
six for verified-profile admission, so the asymmetry is visible in review. The
pinned Web loader is gated by the family GET's 503, so the 404s are not a live
owner path; keep them documented until the bridge is deployed.

The hosted-provider callback is absent. The port still builds
`returnUrl = <origin>/api/connections/callback/<serverId>/<agentId>` in
`Sources/RaftHTTP/Services/MachinesAndHostedRuntimeService.swift:680`, while the
callback route is not registered and the provider relay is `.unavailable`
(`Sources/RaftHTTP/Services/RelayServices.swift:60-80`). If a hosted provider is
enabled, register the callback before enabling the provider; see D34.

The Stripe webhook has a status difference from billing. With no Stripe
provider, upstream answers 503 `Billing is not configured` for the registered
billing mutations **and** for `POST /api/webhooks/stripe`; this port registers
the billing mutations (503) but not the webhook, so the webhook answers the
fallback 404. See D12.

**Why.** These are external services with their own protocols and credentials;
the repository contract excludes porting them for test-only assertions.
**Upstream.** `agentRuntimeProviders.api`, `agentAudienceJwt.grafana`,
`slackBridge.api`, `integrations.api`, `otlpRelay`, `productFeedback.api` (Hands
paths), attachment CDN/storage streaming cases; Slack control-plane registrations
in `packages/server/src/app.ts:403-450`; hosted callback in
`packages/server/src/app.ts:783` and
`packages/server/src/routes/agentConnectionCallback.ts:1-25`.
**Re-evaluate.** If the owner deploys one of these services and the public path
must reach it; implement it as a real adapter with its own acceptance rail, not
as a stub. For Slack, register the six 503 refusals or the real mutations only
with the bridge. For the callback, add the route before the hosted provider.

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
delivery facts. The legacy `GET /internal/agent/:id/receive` runs the machine
and agent-scope gates and then answers `{"messages":[]}`, because there is no
orchestrated machine inbox to drain; `block`/`timeout` are accepted and ignored.
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

**What.** Billing publishes only the read projection from retained facts (free
server plan, live member/agent usage, upload quota, permissions), with
`stripeConfigured:false` and null price/subscription; every mutation answers
`503 {"error":"Billing is not configured"}`, and hosted-runtime usage answers the
no-cloud-agents 404. Joint channels across two servers (no `server.kind`) are not
created: the invite/resend/invite/disconnect and conversion-job routes are
registered and answer the pinned flag-off 404. Built-in app conversations such
as `#system.canary` are absent.
**Why.** There is no billing provider or joint-channel model in this deployment,
and no pinned Web consumer uses them here; the registered routes refuse instead
of fabricating a plan, price, subscription or joint channel.

The Stripe webhook is not registered, so `POST /api/webhooks/stripe` answers
the fallback 404 (`{"error":"Not found","code":"not_found","path":...}`), not
the upstream no-provider 503 `{"error":"Billing is not configured"}`. The
registered billing mutations do answer that 503. The difference is deliberate:
the webhook route is absent rather than a fabricated billing refusal. Upstream
registers it before the JSON parser to preserve the raw body and checks
`isStripeConfigured()` first (`packages/server/src/routes/billing.ts:316-330`).

**Upstream.** `billing.api`, `channels.joint.api`, `internalAgentApi.userChannels`
(built-in app case), `productFeedback.api` (pseudo-server kind row);
`packages/server/src/app.ts:236` and
`packages/server/src/routes/billing.ts:316-330` for the Stripe webhook.
**Re-evaluate.** Only with an explicit product scope change or a real Stripe
deployment; then implement the provider adapter and its acceptance rail.

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
emulated. The five `/api/raftbench` routes are registered with the upstream
auth/verified/member ordering, strict request validation and the
`raftbench_server_not_allowed` pilot refusal; an enrolled staging pilot server
answers the typed 403 `raftbench_disabled` instead of a fabricated dashboard.
The agent-side `/internal/agent-api/raftbench/*` routes are not registered.
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
`attachmentUploadSessions.api` default surface. The four upload-session verbs are
registered and answer the pinned direct-uploads-disabled 404 (see D5).
**Why.** Helper-unit and fake-service assertions have no black-box HTTP surface.
**Upstream.** `attachments`, `attachmentUploadSessions.api` enabled-fake cases.
**Re-evaluate.** If a new public upload path is added.

### D23. Profile avatar and integration-logo image processing

**What.** Uploaded profile avatars and integration logos are not resized to
256×256 WebP. The server validates the multipart part type (`image/jpeg`,
`image/png`, `image/gif`, `image/webp`, 5 MB limit), checks the real image
signature, stores the original bytes, and serves them with their real content
type under the upstream capability path (`/api/avatars/<namespace>/<sha256-prefix>.webp`
and `/api/integration-logos/<clientId>/<sha256-prefix>.webp`). The filename hash
is the SHA-256 prefix of the stored bytes; the `.webp` suffix is retained for
consumer and OAuth `picture` URL compatibility.
**Why.** Upstream uses `sharp` to decode and re-encode. The Swift release
closure contains only the Swift runtime and JavaScriptCore; ImageMagick and
`libwebp` exist on the development host but are not in the verified release
closure, so depending on them would make the production artifact unverified.
**Upstream.** `services/avatarService.ts` (`storeProfileAvatar`),
`services/oauthService.ts` (`storeIntegrationLogo`).
**Re-evaluate.** When a packaged WebP encoder is accepted into the release
closure and its artifact inventory; then restore the 256×256 cover resize,
`image/webp` responses and the WebP-content hash.

### D24. Profile asset storage, CDN URLs and unknown-object status

**What.** Avatar and logo bytes use the existing encrypted R2/S3 bucket and
attachment credentials through `S3AttachmentStorage`
(`PUT`/`GET`/`DELETE` public asset methods, AES-GCM with the attachment key and
a `raft-public-asset:v1:` associated-data domain). A development process without
S3 keeps the bytes in memory, mirroring the attachment development fallback.
Published URLs stay on the application paths even when `CDN_BASE_URL` is set. A
missing avatar object answers `404 {"error":"Avatar not found"}`.
**Why.** This deployment has one private encrypted bucket and no public CDN
bucket; publishing `<CDN_BASE_URL>/avatars/...` would expose ciphertext. The
parent task's published-path contract requires an unknown object to answer 404
rather than upstream's catch-all 500.
**Upstream.** `services/storageService.ts` (`getCdnStorage`,
`resolvePublicAssetUrl`), `routes/agents.ts` avatar route, `routes/integrations.ts`
logo route. Upstream's catch-all turns a missing avatar object into
`500 {"error":"Failed to serve avatar"}`; integration logos already answer 404
`{"error":"Logo not found"}`.
**Re-evaluate.** If a public unencrypted CDN bucket is provisioned, publish CDN
URLs from `resolvePublicAssetUrl` and serve bytes without the encryption
boundary; revisit the missing-avatar status only with that storage change.

### D25. Superseded: developer-platform app logo upload without object storage

**What.** The developer-platform route slice first answered the upstream
no-storage 500 (`{error:"Failed to upload OAuth client logo", correlationId}`)
for `POST /api/integrations/clients/:clientId/logo` and did not register the
public logo GET.
**Why it is superseded.** Merged with `gap-avatar-storage`: the logo upload now
stores the original bytes through `AvatarService` and the public
`/api/integration-logos/:clientId/:file` route serves them (D23/D24). The entry
is kept as the branch decision record, not as a current deviation.
**Upstream.** `packages/server/src/routes/integrations.ts:986-1033`,
`services/oauthService.ts:853-871,3095-3300`, `services/avatarService.ts`.
**Re-evaluate.** Never for the refusal; re-open only if the avatar object store
is removed from the deployment.

### D26. No web-push delivery transport

**What.** `/api/push/vapid-key` is public and answers the disabled 503 without a
VAPID key; `/api/push/test` answers the disabled 503, and a stored subscription
that cannot be attempted gets the truthful 409/502 instead of a fabricated
delivery. `prompt-events` persists only the closed event shape and
`DELETE /subscribe` removes the caller's row idempotently.
**Why.** There is no VAPID key pair and no web-push transport in this port, so
delivery cannot be claimed.
**Upstream.** `routes/push.ts:77-208,349-397`.
**Re-evaluate.** When VAPID keys and a real push transport are deployed.

### D27. Provider probes have no daemon carrier

**What.** `GET/POST /api/provider-connections/:id/probes` keep the feature-flag
gate (404 `provider_connections_disabled`) and the owner/admin gate. When the
surface is enabled they answer 410 `provider_connection_retired`; the single
probe read route is not registered.
**Why.** A probe needs a live Computer daemon to materialize the carrier; the
port has no such relay for this surface, and D5 already retires provider test
and model endpoints (410). Returning a receipt or success would fabricate
provider acceptance.
**Upstream.** `packages/server/src/routes/providerConnections.ts:235-388`,
`services/providerProbeService.ts`.
**Re-evaluate.** If the daemon relay exposes `provider-probe:v1` and an
acceptance rail can drive a controlled Computer peer.

### D28. Third-party MCP OAuth and catalog refresh are unreachable

**What.** `POST /api/mcp/servers/:id/oauth/start` keeps the upstream 400
`managed_mcp_oauth_required` for a non-OAuth server, but an OAuth-mode server
answers 502 `managed_mcp_unreachable`; `POST /api/mcp/servers/:id/test` answers
the same 502 for a known server. `DELETE .../oauth` remains a real idempotent
disconnect (204, catalog cleared, `oauthStatus:"disconnected"`).
**Why.** Both routes depend on outbound MCP discovery / dynamic client
registration / tool-catalog fetches to a third-party server, which this
deployment does not configure (D5). The 502 is the upstream transport-failure
status, not an invented authorization URL or tool catalog.
**Upstream.** `packages/server/src/routes/managedMcp.ts:349-373`,
`services/managedMcpOAuthService.ts`, `services/managedMcpGateway`.
**Re-evaluate.** If an MCP transport adapter with a controlled test server is
deployed.

### D29. Hosted runtime model lists are not available

**What.** `GET /api/agent-runtime-providers/:kind/models` keeps the unknown-kind,
capability and availability refusals. When the hosted provider is available it
answers 502 `hosted_runtime_model_unavailable` instead of a model list.
**Why.** The provider client that lists `/provision/models` is not part of this
deployment (D5); inventing an empty or bundled list would misstate the create
form's choices.
**Upstream.** `packages/server/src/routes/agentRuntimeProviders.ts:64-87`,
`services/hostedAgentModelService.ts`.
**Re-evaluate.** If the hosted-runtime provider adapter is deployed.

### D30. Action-card reconfirmation cannot succeed

**What.** `POST /api/actions/:messageId/reconfirm` applies the session,
membership and card-visibility gates, then always answers 409
`action_card_conversion_frozen` with `errorCode`
`action_card_conversion_frozen`.
**Why.** Reconfirmation only exists for action cards frozen by a joint-channel
conversion. This port does not implement joint channel conversion (D12), so no
card can legitimately leave the frozen state; returning a reconfirmed version
would fabricate state.
**Upstream.** `packages/server/src/routes/actions.ts:285-312`,
`services/actionCardConversionService.ts:496-545`.
**Re-evaluate.** If joint channel conversion is implemented; then persist the
conversion epoch/freeze state and lock the real reconfirm transition.

### D31. Legacy machine surface: credential refusal and unregistered siblings

**What.** The registered legacy `/internal/agent/:id/*` routes run the shared
`LegacyAgentMachineGate` (`requireMachineAuth` + `requireAgentScope`). A live
`sk_agent_*` credential and a `sk_computer_*` computer credential are both
refused with 401 `Invalid authentication: machine API key required`; only
`sk_machine_*` and legacy `sk_daemon_*` keys authenticate. Upstream
`requireMachineAuth` also resolves a `sk_computer_*` key to its linked machine
and admits it on `/internal/*`.

The port also does not register these 11 legacy siblings:

```text
GET  /internal/agent/:agentId/integrations
POST /internal/agent/:agentId/integrations/login
POST /internal/agent/:agentId/integrations/app/prepare
POST /internal/agent/:agentId/resolve-channel
GET  /internal/agent/:agentId/knowledge/search
GET  /internal/agent/:agentId/profile
POST /internal/agent/:agentId/profile
POST /internal/agent/:agentId/profile/avatar
POST /internal/agent/:agentId/tasks/unclaim
POST /internal/agent/:agentId/prepare-action
GET  /internal/agent/:agentId/scopes
```

These are not machine-gated because they are not registered. They match the
five-method `/internal/agent/**` catch-all: a live agent credential gets
401 `{"error":"This internal surface is not registered","code":"auth_policy_unregistered_path"}`;
another credential gets `invalid_principal`; a request without a bearer gets
`auth_required` (`Sources/RaftHTTPServer/FallbackApplication.swift:348-363`;
`Sources/RaftHTTP/Services/AgentsLifecycleError.swift:29,39,83,96`).
Credential-surface equivalents are registered for profile (including avatar),
integrations (including login and app/prepare), knowledge/search,
resolve-channel, prepare-action and tasks/unclaim. There is no
credential-surface scopes route: upstream has none either (the human
`GET/PUT /api/agents/:id/scopes` routes are registered and matched), so the
legacy scope set is not represented on `/internal/agent-api/*`.

Four old machine routes are also unregistered:

```text
GET  /internal/machine/self
GET  /internal/machine/agents
POST /internal/machine/agents/:agentId/start
POST /internal/machine/agents/:agentId/stop
```

There is no `/internal/machine/**` catch-all, so these answer the fallback
404 (`{"error":"Not found","code":"not_found","path":...}`), not the 401 policy
envelope. The one registered machine route is
`POST /internal/machine/scope-attestation`.

**Why.** This port has no `findComputerByApiKey`/linked-machine lookup on the
legacy machine surface; the computer principal exists only on
`/internal/computer/*` and `/daemon/connect`. Admitting the key without the
upstream machine binding would either invent an identity or bypass the
machine-ownership check, so the gate fails closed. `sk_agent_*` is the
credential-surface principal and was never a machine principal upstream either.
The unregistered siblings are the compatibility remainder upstream itself marks
as legacy ("DO NOT ADD OR EXPAND ROUTES HERE ... kept only for compatibility
until it can be deleted"); the pinned CLI rewrites the prefix to
`/internal/agent-api/*`, and the pinned daemon uses `/internal/computer/*`.
**Upstream.** `packages/server/src/routes/internal.ts:6-19` (legacy-surface
notice), `:1400-1512` (machine routes) and `:1512-5356` (the 11 legacy
handlers); `middleware/auth.ts:482-568` (`requireMachineAuth`,
`isComputerApiKey` branch); `docs/PARITY.tsv` `internalAgentApi.registryParity`.
**Re-evaluate.** When a Computer credential registry can resolve
`computer.machineId` to a live machine on the legacy surface; then map it to the
same `LegacyAgentMachinePrincipal` instead of refusing. Re-open the 11 legacy
siblings or the four machine routes only if a pre-RFC daemon or a legacy-machine
CLI mode is actually deployed.

### D32. Malformed-JSON bodies and multi-key strict ordering

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

### D33. Timezone alias canonicalization is a finite map

**What.** `parseCanonicalBrowserTimezone` keeps its explicit alias table for the
`US/*` legacy names and the `Etc/*`/`Asia/Kolkata` cases. Every other
`Area/Location` id is stored exactly as the client sent it. Upstream asks ICU
(`Intl.DateTimeFormat().resolvedOptions().timeZone`) for the canonical id, which
also rewrites, for example, `Europe/Kyiv` -> `Europe/Kiev`,
`Asia/Kathmandu` -> `Asia/Katmandu`, `Australia/Canberra` -> `Australia/Sydney`
and `Asia/Ho_Chi_Minh` -> `Asia/Saigon` (Node 22 / ICU 78.2).
**Why.** Foundation on this Linux toolchain exposes no canonical-id API:
`TimeZone(identifier: "US/Pacific")!.identifier` returns `"US/Pacific"`, not
`"America/Los_Angeles"`, and neither the `TimeZone` Swift API nor its
`CFTimeZoneCreateWithName` bridge has a canonicalization option. ICU's
`ucal_getCanonicalTimeZoneID` exists only as the private
`swift_ucal_getCanonicalTimeZoneID` symbol of `lib_FoundationICU.so`, which is
not a package dependency and is not linkable portably. The alternative, a
complete ICU alias table derived from CLDR/tzdata, cannot be generated from the
shipped runtime without that symbol.
**Upstream.** `packages/server/src/lib/ianaTimezone.ts`
`parseCanonicalBrowserTimezone`, `routes/auth.ts:1406-1413`, and the ICU-backed
`Intl` canonicalization (Node `process.versions.icu` = 78.2 on this host).
**Re-evaluate.** When Foundation exposes a canonical time-zone id API (or this
project takes an explicit ICU/tzdata dependency); then replace
`AccountNaming.timezoneAliases` and the special cases with that lookup and add
the alias cases above to `TimezoneObservationTests`.

### D34. App-backend, scoped-OAuth and marketplace-reviewer routes are partial

**What.** The owner-Web app-management subset is implemented; the App-backend,
scoped-OAuth and marketplace-reviewer subset is not, and one retired
compatibility route is deliberately omitted. These 13 routes are not registered
and answer the fallback 404 (`{"error":"Not found","code":"not_found","path":...}`):

```text
PUT  /api/oauth/installations/:installationId/subscriptions
POST /oidc/:server/api/oauth/agent-events
POST /oidc/:server/api/oauth/authorize/human
GET  /oidc/:server/api/oauth/clients/lookup
POST /oidc/:server/api/oauth/installation-token
PUT  /oidc/:server/api/oauth/installations/:installationId/setup
PUT  /oidc/:server/api/oauth/installations/:installationId/subscriptions
POST /oidc/:server/api/oauth/installations/lookup
POST /oidc/:server/api/oauth/requests/agent
GET  /api/app-installation/computers
GET  /api/integrations/built-in
POST /api/integrations/clients/:clientId/review-publish
GET  /api/connections/callback/:serverId/:agentId
```

`PUT /api/oauth/installations/:installationId/subscriptions` is the
App-backend update of `subscribed_events`: 200
`{installation_id, subscribed_events, subscription_revision}`, 400
`AppOutboundPermissionError`, 404 unknown active installation
(`packages/server/src/routes/oauth.ts:565-596`). Swift models the
`subscribedEvents`/`subscriptionRevision` fields but has no update route.

The eight `/oidc/:server/api/oauth/*` rows are the server-scoped mount of the
whole `oauthRouter` (`packages/server/src/app.ts:380-385`); each therefore has
the same handler and contract as its unscoped counterpart. The mount guard
answers 400 for an invalid server segment and 404 for a path outside
`OIDC_SCOPED_ROUTES` (`packages/server/src/routes/oauth.ts:300-313`). Swift
registers only discovery, agents, jwks, userinfo, serverinfo, authorize and
token under that mount (`Sources/RaftHTTPServer/Features/OAuth/OAuthFeature.swift:158-254`);
the missing eight are the remaining router verbs. The unscoped setup, lookup,
requests/agent, agent-events, authorize/human and clients/lookup routes are
registered and matched; only the unscoped subscriptions route is missing.

`GET /api/app-installation/computers` is the installation-credential computer
projection: 200 `{installation_id, computers}`, 401 otherwise
(`packages/server/src/routes/appInstallations.ts:123-129`). Swift registers only
the `server` and `channels` projections
(`Sources/RaftHTTPServer/Features/Integrations/InstallationCredentialRoutes.swift:26-40`).
`GET /api/integrations/built-in` is a compatibility-only `200 []`; upstream says
the retired class is never queried and new clients do not call it
(`packages/server/src/routes/integrations.ts:144-150`). Swift omits it
deliberately as an unused retired compatibility route; see the exception in
**Why** below.
`POST /api/integrations/clients/:clientId/review-publish` is
marketplace-reviewer-only: 403 for everyone else, 400 for an invalid review,
404 for a missing publish request, 200 for a reviewer
(`packages/server/src/routes/integrations.ts:625-650`).

`GET /api/connections/callback/:serverId/:agentId` is the unauthenticated
hosted-provider OAuth browser return: 302 to the Web landing page or 404
`{"error":"Unknown connection callback"}` (`packages/server/src/app.ts:783`;
`packages/server/src/routes/agentConnectionCallback.ts:1-25`). Swift still
builds that `returnUrl` (`Sources/RaftHTTP/Services/MachinesAndHostedRuntimeService.swift:680`)
but the provider relay is `.unavailable` (D5), so the start call fails before a
browser can follow it. Add the callback route before enabling a hosted provider.

The App-side bot routes (`POST /api/app-bot/token`,
`POST /api/integrations/clients/:id/install/bot`) are already covered by D5 and
`docs/PARITY.tsv` `integrations.api`; they are not part of this 13-route count.

**Why.** Twelve of these routes need an installed App, a marketplace reviewer or
a hosted runtime provider. None is configured in this deployment; the owner-Web
routes that manage Apps are implemented. Returning an App installation, a review
decision or a provider redirect without the external identity would fabricate
state. The thirteenth, `GET /api/integrations/built-in`, is the explicit
exception: upstream answers an unconditional `200 []` for a retired
compatibility class, and no current client queries it. Swift omits it
intentionally as an unused retired compatibility route, not because returning
`[]` would fabricate state. This is the existing `integrations.api`/`oauth.api`
scope, not a new capability decision.
**Upstream.** `docs/PARITY.tsv` `integrations.api` and `oauth.api`; D5;
`packages/server/src/routes/oauth.ts:300-313,565-596`,
`packages/server/src/app.ts:380-385`,
`packages/server/src/routes/appInstallations.ts:123-129`,
`packages/server/src/routes/integrations.ts:144-150,625-650`,
`packages/server/src/routes/agentConnectionCallback.ts:1-25`.
**Re-evaluate.** When an installed App, a marketplace reviewer or a hosted
provider is configured; or when a pinned consumer starts using the retired
built-in compatibility route. Add the real route with its own acceptance rail;
add the callback route before enabling the hosted provider. Do not add
fabricated App/reviewer responses to satisfy a route-name check.

### D35. Agent-SDK-only operations are not registered

**What.** These seven credential-surface operations are not registered:

```text
GET    /internal/agent-api/labs
PUT    /internal/agent-api/labs/:labKey
PATCH  /internal/agent-api/labs/access
GET    /internal/agent-api/mentions/:messageId/delivery
GET    /internal/agent-api/push-webhook
DELETE /internal/agent-api/push-webhook
POST   /internal/agent-api/app-sources/ack
```

They match the `/internal/agent-api/**` five-method catch-all. A live agent
credential gets 401
`{"error":"This internal surface is not registered","code":"auth_policy_unregistered_path"}`;
another credential gets `invalid_principal`; no bearer gets `auth_required`
(`Sources/RaftHTTPServer/FallbackApplication.swift:348-363`;
`Sources/RaftHTTP/Services/AgentsLifecycleError.swift:29,39,83,96`).

Upstream contracts: Labs are `GET /labs`, `PATCH /labs/access` and
`PUT /labs/:labKey` (`packages/shared/src/agentApiContract.ts:2611-2641`), backed
by the same transactional service and owner/admin policy as the human Settings
routes (`packages/server/src/routes/serverLabs.ts:167-193`); they answer 200 with
the server Labs projection, 400 for invalid body/version and 403 for insufficient
authority. Push registration status is 200
`{registered, url, enabled, disabledReason, disabledAt, lastAttemptAt,
lastDeliveryAt, lastError, consecutiveFailures, nextAttemptAt}`; delete is 204;
403 `AGENT_NOT_EXTERNAL` and 503 `PUSH_UNAVAILABLE` are the typed failures
(`packages/shared/src/agentApiContract.ts:3125-3152`;
`packages/server/src/services/agentInboxPushService.ts:203-218,283-290`).
Receiver-bound mention delivery is 200 or 404 `{"status":"NOT_JOINABLE"}`
(`packages/server/src/routes/internalAgentApi.ts:3243-3275`). App-source ack is
200 for the built-in `system.reminder` source and 404
`app_source_authority_not_registered` for anything else
(`packages/server/src/routes/internalAgentApi.ts:9388-9405`;
`packages/server/src/apps/reminder/sourceAck.ts:1-80`).

The sibling `PUT /internal/agent-api/push-webhook` is registered
(`Sources/RaftHTTPServer/Features/InternalAgentApi/InternalAgentApiFeature.swift:881`),
and the author-bound `GET /internal/agent-api/messages/:messageId/mention-deliveries`
is registered and matched. The missing receiver-bound route is a different view.

**Why.** The pinned CLI surface client does not expose `labs`, `pushWebhook` or
receiver-bound mention delivery (`packages/cli/src/agentApiPath.ts:393` onward);
the `raft-sdk` does (`packages/raft-sdk/src/raft.ts:430,739`), and no pinned CLI
command calls them. The surface client does expose `appSources.ack`
(`agentApiPath.ts:464`), but no pinned CLI command calls it. The push chain is
the unported durable inbox (D8); the app-source ack needs the unported built-in
`system.reminder` app runtime/source chain (D12). These are real contract
routes, not false positives, but they are not reachable from the pinned
owner/Computer/Codex command surface.
**Upstream.** `docs/PARITY.tsv` `internalAgentApi.inboxPush`,
`internalAgentApi.senderMentionDeliveries`,
`internalAgentApi.registryParity`; D8; D12.
**Re-evaluate.** When an SDK-only client, the built-in App source chain or a
durable inbox push backend is deployed. Add the real route and lock its public
contract; do not answer a fabricated labs/push/ack success from the catch-all.

### D36. Resumable streamed migration chunks are not implemented

**What.** `POST /internal/computer/agent-migrations/by-id/:migrationId/resumable/stream-chunks/:chunkIndex`
is not registered, so it matches the `/internal/computer/**` five-method
catch-all and a live Computer credential gets 401
`{"error":"This internal surface is not registered","code":"auth_policy_unregistered_path"}`
(`Sources/RaftHTTPServer/FallbackApplication.swift:337-345`).

Upstream is a presigned-PUT planning call: the source asks for one upload URL as
soon as a chunk is packed, before the control manifest exists. It answers 200
`{"ok":true, "uploaded": <bool>, "url": <string|null>}`; the chunk's size and
SHA-256 must match, an already-received chunk returns `uploaded:true,url:null`,
and typed 400/401/409 errors cover invalid chunks, generation/lease staleness,
quiescence and receipt mismatch (`packages/server/src/routes/internalComputer.ts:495-523`;
`packages/server/src/services/agentMigrationService.ts:773-860`). The port
implements the control manifest, chunk receipts and upload-complete
(`Sources/RaftHTTPServer/Features/InternalAdmin/InternalAdminFeature.swift:493-536`)
but not the streamed chunk planning route.

**Why.** No production migration lease dispatches a resumable upload today.
`machineMigrationLeaseDispatch` is installed only by
`Tests/TestSupport/AgentRuntimeRelaySeams.swift:54-62`, never by `Sources/`; the
pinned daemon calls this route only for a `transferKind === "upload"` lease
(`packages/daemon/src/core.ts:2715,2790`). A 401 here is therefore latent, not a
current user-path defect.
**Upstream.** `docs/PARITY.tsv` `internalComputer.agentMigration` (case 2 /
pre-existing simplified resumable contract); `routes/internalComputer.ts:495-523`;
`services/agentMigrationService.ts:773-860`.
**Re-evaluate.** When a production `transferKind:"upload"` lease can be
dispatched. Implement the route with the presigned PUT and receipt
reconciliation, and add a controlled-Computer acceptance rail.

### D37. Resend newsletter webhook is not registered

**What.** `POST /api/webhooks/resend` is not registered, so it answers the
fallback 404 (`{"error":"Not found","code":"not_found","path":...}`). Upstream
registers it with a raw body and checks the three Svix headers: missing headers
answer 400 `{"error":"Missing Resend webhook signature headers"}`; a failed
verification answers 400 `{"error":"Resend webhook verification failed"}`; a
verified newsletter event answers 200 `{"received":true,...}`
(`packages/server/src/app.ts:238`;
`packages/server/src/routes/newsletterWebhooks.ts:1-30`).

This is the newsletter/Svix receiver, not the transactional email sender.
Cloudflare Email Sending is configured for transactional email (D5;
`docs/DEPLOYMENT.md`), and a Resend API key used for sending is separate from
this webhook's Svix signing secret. Do not cite this entry to claim email
sending is absent.

**Why.** This deployment does not configure the newsletter webhook/Svix
receiver. Registering the route without a signing secret would either accept
unverified newsletter events or reject every request with an invented status;
the fallback 404 is the truthful unmounted result.
**Upstream.** `packages/server/src/app.ts:238`;
`packages/server/src/routes/newsletterWebhooks.ts:1-30`; D5.
**Re-evaluate.** When the newsletter Resend webhook and its Svix secret are
configured. Register the raw-body route before the JSON parser, verify the Svix
signature, and add the delivery/verification acceptance rail.

## Maintaining this list

1. Add an entry only after the excluded assertion is understood and the
   remaining public path is locked.
2. Put the module name in `docs/PARITY.tsv` notes and reference the entry id
   here (`see docs/DEVIATIONS.md#d15`).
3. When a trigger fires, re-open the module, implement the real path and update
   both this file and the parity ledger in the same commit.
4. Never delete an entry silently; mark it superseded with the commit and the
   reason.

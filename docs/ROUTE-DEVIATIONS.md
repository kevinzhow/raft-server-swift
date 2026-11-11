# Route-inventory adjudication (raw router table)

Companion to [DEVIATIONS.md](DEVIATIONS.md) and
[route-inventory.md](route-inventory.md). It adjudicates the raw upstream/Swift
router-table diff at `2bca8de` on `process-refactor` against the pinned upstream
tag `v1.21.23-source.1`. It is a documentation/tooling record, not a route,
API, `Sources/`, test or `PARITY.tsv` change.

## Raw counts versus effective paths

| Metric | Count |
| --- | ---: |
| Upstream route registrations | 644 |
| Swift route registrations | 611 |
| Exact matches | 583 |
| Parameter-variant matches | 1 |
| Raw missing in Swift | 57 |
| Raw extra in Swift | 27 |

These are **router-registration** counts, not effective published-path counts.
A path served by `FallbackMiddleware` or `PublicSearchMiddleware` is a published
path but is not in the Vapor router table. Fifteen of the 611 Swift registrations
are fail-closed `/**` wildcards, not published endpoints. Do not quote `611` as
"the number of published paths" or `57` as "57 missing user paths".

The three upstream routes served by `FallbackMiddleware`
(`GET /robots.txt`, `GET /health`, `GET /livez`) are removed from the raw
missing set before it is reported. That is why
`583 exact + 1 parameter variant + 57 missing = 641`, and `641 + 3 = 644`
upstream registrations.

## Classification and count proof

The 57 raw missing rows split:

| Class | Count | Meaning |
| --- | ---: | --- |
| A | 5 | Served outside the Vapor router table or normalized from a regex; not missing in practice, not a new port |
| B | 15 | Deliberate exclusion with an exact `DEVIATIONS.md` entry |
| B* | 37 | Deliberate/legacy/external exclusion now named by D31, D34, D35, D36 or D37 |
| C | 0 | Reachable missing requirement on the audited baseline |

Count proof:

- `A 5 + B 15 + B* 37 + C 0 = 57`.
- Intentional exclusions are `B 15 + B* 37 = 52`; `52 + A 5 = 57`.
- Before the three `FallbackMiddleware` rows are removed, the parser reports
  60 raw missing; `60 - 3 = 57`.
- B* breakdown: `legacy agent 11 + legacy machine 4 + SDK-only 7 +
  App/OAuth 13 + remaining 2 = 37`.
- Extra breakdown: `catch-all 15 + upstream parser miss 5 + Swift compat 7 = 27`.
- `583 exact + 1 parameter variant + 27 extra = 611` Swift registrations.
- `583 exact + 1 parameter variant + 57 missing + 3 fallback-served = 644`
  upstream registrations.

The 27 extras are also raw registrations. They are not 27 parity wins: 15 are
the fail-closed policy wildcards, 5 are real upstream routes the parser missed,
and 7 are Swift-only compatibility/refusal endpoints.

## Scope and baseline conclusion

**The audited baseline has 0 reachable missing normal owner Web / Computer /
Codex / attachment / restart paths.** The normal baseline is matched: the
channel family is 64/64 with one parameter variant; DM, mention, task,
attachment, thread, history, event, send and restart routes are matched.

This conclusion is **not** based on the inventory's `0` Web/CLI source-hit
columns. Those columns only scan literal path text and are not proof that no
consumer exists. The audit checked the pinned call sites dynamically:

- The only pinned-Web family that calls a missing route is Slack Bridge
  provisioning. Its loader is gated by the server feature flag and then by the
  family `GET`'s deliberate 503, so the six missing mutations are not reachable
  from the Web today (D5).
- Provider-connection launch and probe materialization are behind
  `provider_connections_disabled` / `probe_disabled`, and the port has no
  provider/probe daemon carrier (D5, D27).
- App-source ack needs the built-in `system.reminder` app runtime, which is not
  ported (D12).
- Streamed migration chunks need a `transferKind:"upload"` lease that
  production never dispatches; the lease seam is installed only by tests
  (D36).
- The CLI commands use the id-less `/internal/agent-api/*` credential surface;
  the legacy `/internal/agent/:id/*` helper is unused. The SDK-only operations
  are not exposed by the pinned CLI surface client (D35).
- The missing OAuth/App-installation routes are App-backend, reviewer or
  hosted-provider routes with no configured App, reviewer or provider (D34).

This is the existing capability scope, not a new feature decision. The audit
did not turn a missing upstream feature into a parity exception by static `0`
alone; each exclusion uses the pinned source trigger and the actual port gate.

### External-service scope (do not overclaim)

The audit's "no credentialed external service" limit applies only to the
excluded backend services: Slack bridge, hosted runtime providers, App/OAuth
backend, Resend newsletter webhook and Stripe billing. It does **not** mean the
deployment has no external services. Cloudflare Email Sending is configured for
transactional email, and the encrypted private R2/S3 object bucket is configured
for attachments and profile assets (D5, D24, `docs/DEPLOYMENT.md`). Never cite
this table to claim email sending or object storage is absent.

## Class A — 5 served outside the raw router table

These are false positives of the raw diff. They are not deviations and not new
ports; the published path already exists.

| # | Method path | Served by | Evidence |
| ---: | --- | --- | --- |
| A1 | `POST /^\/api\/message-translations:param` | Literal `POST /api/message-translations:batch` registration; the parser renders upstream's regex as `:param` and always puts regex routes in `missing` | Upstream `packages/server/src/app.ts:643`; Swift `Sources/RaftHTTPServer/Features/Translations/TranslationFeature.swift:31` |
| A2 | `GET /api/public/search/index` | `PublicSearchMiddleware` before the Vapor router | `FallbackApplication.swift:393-400`; `Sources/RaftHTTP/PublicSearch.swift:178-184`; `PublicSearchTests.swift:161,253,265` |
| A3 | `GET /api/public/search/servers/:param` | Same middleware, server dispatch | `Sources/RaftHTTP/PublicSearch.swift:187-193`; `PublicSearchTests.swift:158,252` |
| A4 | `GET /api/public/search/servers/:param/channels/:param` | Same middleware, channel dispatch | `Sources/RaftHTTP/PublicSearch.swift:194-204`; `PublicSearchTests.swift:159,210-232` |
| A5 | `GET /api/public/search/servers/:param/threads/:param` | Same middleware, thread dispatch | `Sources/RaftHTTP/PublicSearch.swift:205-215`; `PublicSearchTests.swift:160,210-232` |

The upstream public-search routes exist in
`packages/server/src/routes/publicSearch.ts:276,320,396,610` but are matched by
the middleware-held Swift implementation. The `FallbackMiddleware` routes
(`/robots.txt`, `/health`, `/livez`) are also served and locked
(`Sources/RaftHTTP/Fallback.swift:45-125`;
`FallbackApplication.swift:557-581`); they are already excluded from the 57.

## Class B — 15 with an exact DEVIATIONS entry

"Swift actual" is the reply a caller gets today. All fallback 404 bodies are
`{"error":"Not found","code":"not_found","path":...}`; all catch-all 401 bodies
are `{"error":"This internal surface is not registered","code":"auth_policy_unregistered_path"}`.

| # | Method path | Swift actual | Pinned upstream expected | Adjudication |
| ---: | --- | --- | --- | --- |
| B1 | `POST /api/webhooks/stripe` | 404 fallback | 503 `{"error":"Billing is not configured"}` before signature handling (`app.ts:236`; `routes/billing.ts:316-330`) | **D12**, `PARITY.tsv` `billing.api`; D5 records the 404-vs-503 difference |
| B2 | `POST /internal/trace-ingest/otlp/v1/traces` | 404 fallback | Authenticated OTLP pass-through to an external collector (`app.ts:249-257`); no collector here | **D5**, `PARITY.tsv` `otlpRelay` |
| B3 | `POST /api/slack-bridge/provisioning/connect` | 404 fallback; family `GET` is 503 | Slack control-plane mutation behind auth/verified/server (`app.ts:403-410`) | **D5**, `PARITY.tsv` `slackBridge.api` |
| B4 | `PUT /api/slack-bridge/provisioning/channel-pairs` | 404 fallback; family `GET` is 503 | Control-plane channel-pair save (`app.ts:411-418`) | **D5**, `slackBridge.api` |
| B5 | `DELETE /api/slack-bridge/provisioning/channel-pairs` | 404 fallback; family `GET` is 503 | Control-plane channel-pair removal (`app.ts:419-426`) | **D5**, `slackBridge.api` |
| B6 | `POST /api/slack-bridge/provisioning/disconnect` | 404 fallback; family `GET` is 503 | Control-plane disconnect (`app.ts:427-434`) | **D5**, `slackBridge.api` |
| B7 | `POST /api/slack-bridge/provisioning/preflight` | 404 fallback; family `GET` is 503 | Control-plane preflight (`app.ts:435-442`) | **D5**, `slackBridge.api` |
| B8 | `POST /api/slack-bridge/provisioning/enable` | 404 fallback; family `GET` is 503 | Control-plane enable (`app.ts:443-450`) | **D5**, `slackBridge.api` |
| B9 | `POST /api/app-bot/token` | 404 fallback | App OAuth-access-token exchange for a managed bot (`app.ts:825-833`; `routes/integrations.ts:894-990`) | **D5** (names the App-side bot routes), `PARITY.tsv` `integrations.api` |
| B10 | `POST /api/integrations/clients/:param/install/bot` | 404 fallback | Managed-bot grant/revoke for an active install (`routes/integrations.ts:813-885`) | **D5** (names the App-side bot routes), `PARITY.tsv` `integrations.api` |
| B11 | `GET /api/provider-connections/:param/probes/:param` | 404 fallback | Single probe read, 200 or 404/410/429/503 typed (`routes/providerConnections.ts:369-388`) | **D27** (single probe read is not registered) |
| B12 | `POST /internal/computer/runners/:param/provider-connection` | 401 catch-all | 404 `provider_connections_disabled` when the feature is off; 200 launch otherwise (`routes/internalComputer.ts:1045-1098`) | **D5** + **D27** |
| B13 | `POST /internal/computer/probes/:param/materialize` | 401 catch-all | 404 `probe_disabled` when the feature is off; 200 materialization otherwise (`routes/internalComputer.ts:1103-1155`) | **D27** |
| B14 | `GET /internal/agent-api/raftbench/context` | 401 catch-all | Staging-only synthetic-analysis context (`routes/internalAgentApi.ts:9626-9632`) | **D19**, `PARITY.tsv` `internalAgentApi.raftbench` |
| B15 | `POST /internal/agent-api/raftbench/submit` | 401 catch-all | Staging-only benchmark submission (`routes/internalAgentApi.ts:9634-9641`) | **D19**, `internalAgentApi.raftbench` |

## Class B* — 37 now covered by D31, D34, D35, D36 and D37

All 37 fail closed: 19 answer the 401 catch-all (11 legacy agent, 7 SDK-only
and 1 migration route; live agent principal for `/internal/agent-api/*`, live
Computer principal for `/internal/computer/*`), and 18 answer the fallback 404
(4 machine routes, 13 App/OAuth routes and 1 newsletter webhook). None is
implemented. The 37 are grouped by source family below; the family counts are
`11 + 4 + 7 + 13 + 2 = 37`.

### Legacy machine-on-behalf agent surface (11) — D31

Upstream itself marks this router legacy: "DO NOT ADD OR EXPAND ROUTES HERE ...
kept only for compatibility until it can be deleted"
(`packages/server/src/routes/internal.ts:6-19`). The pinned CLI rewrites the
legacy prefix to `/internal/agent-api/*` (`packages/cli/src/client.ts:117-180`);
`createAgentApiClient` is exported but unused by commands
(`packages/cli/src/agentApiPath.ts:343`). Credential-surface equivalents are
registered for profile, integrations, knowledge/search, resolve-channel,
prepare-action and tasks/unclaim. There is no credential-surface scopes route
(upstream has none; the human `GET/PUT /api/agents/:id/scopes` routes are
matched), so the legacy scopes read is not represented on
`/internal/agent-api/*`. Each row's Swift actual is the 401 catch-all, not the
machine gate.

| # | Method path | Swift actual | Pinned upstream expected | Adjudication |
| ---: | --- | --- | --- | --- |
| B\*1 | `GET /internal/agent/:param/integrations` | 401 catch-all | 200 integration list for the machine-owned agent (`internal.ts:1512`) | **D31** |
| B\*2 | `POST /internal/agent/:param/integrations/login` | 401 catch-all | Machine-on-behalf integration login (`internal.ts:1560`) | **D31** |
| B\*3 | `POST /internal/agent/:param/integrations/app/prepare` | 401 catch-all | Machine-on-behalf app prepare (`internal.ts:1754`) | **D31** |
| B\*4 | `POST /internal/agent/:param/resolve-channel` | 401 catch-all | Machine-on-behalf channel resolution (`internal.ts:2230`) | **D31** |
| B\*5 | `GET /internal/agent/:param/knowledge/search` | 401 catch-all | Knowledge search under `knowledge:read` (`internal.ts:4118`) | **D31** |
| B\*6 | `GET /internal/agent/:param/profile` | 401 catch-all | Agent profile show (`internal.ts:4128`) | **D31** |
| B\*7 | `POST /internal/agent/:param/profile` | 401 catch-all | Agent profile update (`internal.ts:4219`) | **D31** |
| B\*8 | `POST /internal/agent/:param/profile/avatar` | 401 catch-all | Agent avatar upload (`internal.ts:4158`) | **D31** |
| B\*9 | `POST /internal/agent/:param/tasks/unclaim` | 401 catch-all | Task unclaim under `task:write` (`internal.ts:4680`) | **D31** |
| B\*10 | `POST /internal/agent/:param/prepare-action` | 401 catch-all | Action-card prepare under `action:prepare` (`internal.ts:5267`) | **D31** |
| B\*11 | `GET /internal/agent/:param/scopes` | 401 catch-all | Agent scope set (`internal.ts:5356`) | **D31** |

### Legacy machine routes (4) — D31

The current pinned daemon does not call these: there are 0 hits for
`/internal/machine/` in `packages/daemon/src`, `packages/computer/src` and
`packages/cli/src`. Swift has no `/internal/machine/**` catch-all, so these four
fall to the fallback 404, not the 401 policy envelope.

| # | Method path | Swift actual | Pinned upstream expected | Adjudication |
| ---: | --- | --- | --- | --- |
| B\*12 | `GET /internal/machine/self` | 404 fallback | 200 machine read model (`internal.ts:1400`) | **D31** |
| B\*13 | `GET /internal/machine/agents` | 404 fallback | 200 machine-assigned agent list (`internal.ts:1431`) | **D31** |
| B\*14 | `POST /internal/machine/agents/:param/start` | 404 fallback | 200 `{"ok":true}` for an owned agent (`internal.ts:1473`) | **D31** |
| B\*15 | `POST /internal/machine/agents/:param/stop` | 404 fallback | 200 `{"ok":true}` for an owned agent (`internal.ts:1491`) | **D31** |

### Agent-SDK-only operations (7) — D35

The pinned CLI surface client does not expose `labs`, `pushWebhook` or
receiver-bound mention delivery; the `raft-sdk` does
(`packages/raft-sdk/src/raft.ts:430,739`), and no pinned CLI command calls them.

| # | Method path | Swift actual | Pinned upstream expected | Adjudication |
| ---: | --- | --- | --- | --- |
| B\*16 | `GET /internal/agent-api/labs` | 401 catch-all | 200 server Labs projection (`agentApiContract.ts:2611-2631`; `serverLabs.ts:167-173`) | **D35** |
| B\*17 | `PUT /internal/agent-api/labs/:param` | 401 catch-all | 200 enrollment with version CAS; 400 invalid key (`agentApiContract.ts:2631-2641`; `serverLabs.ts:190`) | **D35** |
| B\*18 | `PATCH /internal/agent-api/labs/access` | 401 catch-all | 200 owner-only access toggle; 403 otherwise (`agentApiContract.ts:2621-2631`; `serverLabs.ts:175-185`) | **D35** |
| B\*19 | `GET /internal/agent-api/mentions/:param/delivery` | 401 catch-all | 200 or 404 `{"status":"NOT_JOINABLE"}` receiver-bound diagnostic (`internalAgentApi.ts:3243-3275`) | **D35** |
| B\*20 | `GET /internal/agent-api/push-webhook` | 401 catch-all | 200 push-registration status; 403/503 typed (`agentApiContract.ts:3125-3134`; `agentInboxPushService.ts:203-218`) | **D35** |
| B\*21 | `DELETE /internal/agent-api/push-webhook` | 401 catch-all | 204 and remove the registration (`agentApiContract.ts:3145-3152`; `agentInboxPushService.ts:283-290`) | **D35** |
| B\*22 | `POST /internal/agent-api/app-sources/ack` | 401 catch-all | 200 for `system.reminder`; 404 `app_source_authority_not_registered` otherwise (`internalAgentApi.ts:9388-9405`; `apps/reminder/sourceAck.ts:1-80`) | **D35** |

The sibling `PUT /internal/agent-api/push-webhook` is registered
(`InternalAgentApiFeature.swift:881`), and the author-bound
`GET /internal/agent-api/messages/:id/mention-deliveries` is registered and
matched; those are not missing.

### App-backend, scoped-OAuth and hosted-callback routes (13) — D34

These are not owner-Web routes. The owner-Web app-management routes are
registered; the App-backend, marketplace-reviewer and hosted-provider routes
are not.

| # | Method path | Swift actual | Pinned upstream expected | Adjudication |
| ---: | --- | --- | --- | --- |
| B\*23 | `PUT /api/oauth/installations/:param/subscriptions` | 404 fallback | 200 `{installation_id, subscribed_events, subscription_revision}`; 400/404 (`oauth.ts:565-596`) | **D34** |
| B\*24 | `POST /oidc/:param/api/oauth/agent-events` | 404 fallback | Same handler as unscoped `/api/oauth/agent-events`; whole router mounted under `/oidc/:server/api/oauth` (`app.ts:380-385`; `oauth.ts:1257`) | **D34** |
| B\*25 | `POST /oidc/:param/api/oauth/authorize/human` | 404 fallback | Same handler as unscoped human authorize (`oauth.ts:794`) | **D34** |
| B\*26 | `GET /oidc/:param/api/oauth/clients/lookup` | 404 fallback | Same handler as unscoped client lookup (`oauth.ts:597`) | **D34** |
| B\*27 | `POST /oidc/:param/api/oauth/installation-token` | 404 fallback | Same handler as unscoped installation-credential mint (`oauth.ts:451`) | **D34** |
| B\*28 | `PUT /oidc/:param/api/oauth/installations/:param/setup` | 404 fallback | Same handler as unscoped installation setup (`oauth.ts:544`) | **D34** |
| B\*29 | `PUT /oidc/:param/api/oauth/installations/:param/subscriptions` | 404 fallback | Same handler as unscoped installation subscriptions (`oauth.ts:565`) | **D34** |
| B\*30 | `POST /oidc/:param/api/oauth/installations/lookup` | 404 fallback | Same handler as unscoped installation lookup (`oauth.ts:501`) | **D34** |
| B\*31 | `POST /oidc/:param/api/oauth/requests/agent` | 404 fallback | Same handler as unscoped agent request (`oauth.ts:697`) | **D34** |
| B\*32 | `GET /api/app-installation/computers` | 404 fallback | 200 `{installation_id, computers}`; 401 otherwise (`appInstallations.ts:123-129`) | **D34** |
| B\*33 | `GET /api/integrations/built-in` | 404 fallback | 200 `[]` compatibility route (`integrations.ts:144-150`) | **D34** |
| B\*34 | `POST /api/integrations/clients/:param/review-publish` | 404 fallback | 403 non-reviewer; 400 invalid review; 404 missing; 200 reviewer (`integrations.ts:625-650`) | **D34** |
| B\*35 | `GET /api/connections/callback/:param/:param` | 404 fallback | Unauthenticated 302 to the Web landing page, or 404 unknown (`agentConnectionCallback.ts:1-25`; `app.ts:783`) | **D34**; D5 records the absent provider relay |

The Swift scoped mount registers only discovery, agents, jwks, userinfo,
serverinfo, authorize and token
(`Sources/RaftHTTPServer/Features/OAuth/OAuthFeature.swift:158-254`). Swift still
builds the callback `returnUrl`
(`Sources/RaftHTTP/Services/MachinesAndHostedRuntimeService.swift:680`) but the
provider relay is `.unavailable`, so the callback is latent until a provider is
configured.

### Remaining two (2) — D36, D37

| # | Method path | Swift actual | Pinned upstream expected | Adjudication |
| ---: | --- | --- | --- | --- |
| B\*36 | `POST /internal/computer/agent-migrations/by-id/:param/resumable/stream-chunks/:param` | 401 catch-all | 200 `{ok:true, uploaded, url}` presigned-PUT planning; 400/401/409 typed (`internalComputer.ts:495-523`; `agentMigrationService.ts:773-860`) | **D36** |
| B\*37 | `POST /api/webhooks/resend` | 404 fallback | 400 missing Svix headers; 400 verification failure; 200 verified newsletter event (`app.ts:238`; `newsletterWebhooks.ts:1-30`) | **D37**; this is the newsletter webhook, not the configured email sender |

B\*36 is the strongest latent defect candidate: if a production release starts
dispatching a resumable upload lease, the pinned daemon will call it and the 401
becomes a real migration failure. It is not reachable today because
`machineMigrationLeaseDispatch` is installed only by
`Tests/TestSupport/AgentRuntimeRelaySeams.swift:54-62`.

B\*37 is the Resend/Svix **newsletter** webhook. It does not describe the
transactional email transport: Cloudflare Email Sending is configured and is not
this route.

## Extra Swift routes (27) — classification

These are raw Swift registrations absent from the upstream router table. They are
not parity wins.

| Class | Count | Members |
| --- | ---: | --- |
| Fail-closed policy wildcards | 15 | 5 methods × 3 claimed prefixes |
| Upstream routes the parser missed | 5 | 3 server-Labs routes, `POST /api/product-feedback`, regex-normalized translation |
| Swift-only compatibility/refusal | 7 | activity, creator, agent grants read, users/info, two task aliases, attachment-revoke stub |
| **Total** | **27** | `15 + 5 + 7` |

### Fail-closed policy wildcards (15)

Five methods (`GET`, `POST`, `PUT`, `PATCH`, `DELETE`) for each claimed prefix:

```text
GET/POST/PUT/PATCH/DELETE /internal/agent-api/**
GET/POST/PUT/PATCH/DELETE /internal/agent/**
GET/POST/PUT/PATCH/DELETE /internal/computer/**
```

These are deliberate: a live credential for the prefix gets 401
`auth_policy_unregistered_path`; another principal gets `invalid_principal`; no
bearer gets `auth_required`. They are registered in
`Sources/RaftHTTPServer/FallbackApplication.swift:337-363` and locked by
`Tests/RaftHTTPServerTests/InternalAgentSurfacePolicyTests.swift`.

### Upstream routes the parser missed (5)

These are real upstream contracts, not extras:

| Method path | Why the parser missed it | Upstream evidence |
| --- | --- | --- |
| `GET /api/servers/:param/labs` | Router mounted under a parameter prefix (`serverRouter.use("/:id/labs", serverLabsRouter)`) | `routes/servers.ts:993`; `routes/serverLabs.ts:120` |
| `PUT /api/servers/:param/labs/:param` | Same mount | `routes/serverLabs.ts:129` |
| `PATCH /api/servers/:param/labs/access` | Same mount | `routes/serverLabs.ts:145` |
| `POST /api/product-feedback` | Root route `productFeedbackRouter.post("/")` | `routes/productFeedback.ts:465` |
| `POST /api/message-translations:param` | Swift's literal `POST /api/message-translations:batch`, normalized to `:param` by the tool; the A1 row is upstream's regex form | `app.ts:643`; Swift literal `TranslationFeature.swift:31` |

### Swift-only compatibility/refusal endpoints (7)

These have no upstream route. They are covered by Swift registration tests but
are **not** upstream parity evidence.

| Method path | Purpose and source |
| --- | --- |
| `GET /api/agents/:param/activity` | Swift-only agent activity projection; upstream has activity-log/activity-summaries (`AgentsFeature.swift:81`) |
| `PATCH /api/agents/:param/creator` | Swift-only creator update; no upstream route (`AgentsFeature.swift:262`) |
| `GET /api/integrations/agents/:param/grants` | Swift-only read; upstream has the POST grant route only (`IntegrationsFeature.swift:219`) |
| `GET /internal/agent-api/users/info` | Swift-only credential-surface user directory lookup (`InternalAgentApiFeature.swift:106`) |
| `POST /internal/agent/:param/tasks/convert` | Swift-only legacy alias; the credential-surface variant is matched (`InternalAdminFeature.swift:361`) |
| `POST /internal/agent/:param/tasks/delete` | Swift-only legacy alias; the credential-surface variant is matched (`InternalAdminFeature.swift:351`) |
| `POST /internal/computer/attachment/revoke` | Explicit 401 `auth_policy_unregistered_path` refusal stub (`InternalAdminFeature.swift:447`) |

## Maintenance

- `docs/route-inventory.md` is regenerated by `scripts/route_inventory.py`.
  The raw counts `644 / 611 / 583 / 1 / 57 / 27` are parser metrics; this file
  is the effective-path adjudication.
- When a `DEVIATIONS.md` entry changes, update the matching class row here and
  keep the count proof in sync. Do not silently move a row between A, B and B*.
- When a trigger in D31/D34/D35/D36/D37 fires, implement the real capability and
  remove the row in the same change; do not reclassify a live route as an
  exception.

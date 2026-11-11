# Deliberate deviations from upstream

This branch does not yet carry the full deviation ledger (it lives on the
integration branch). This file records only the deviations introduced by the
developer-platform route slice. D5 (external provider and integration services
are not ported) and D12 (billing, joint channels, built-in app conversations)
are the governing entries.

Rules: an unsupported capability fails explicitly (4xx/5xx), never with a
fabricated success; a locked parity case never implies the deviation is absent.

## Developer-platform route slice

### P1. App logo upload without an image pipeline or object storage

**What.** `POST /api/integrations/clients/:clientId/logo` validates authority,
the multipart shape, the image media type and the 5 MB bound, then answers the
upstream no-storage 500 (`{error:"Failed to upload OAuth client logo",
correlationId}` + `X-Slock-Error-Id`). `DELETE .../logo` still clears the stored
`logoUrl` and returns the client row.
**Why.** This deployment has no `sharp`-equivalent resizer and no CDN/object
storage (D5), so a successful upload cannot produce the upstream
`/api/integration-logos/<id>/<hash>.webp` artifact. The public logo GET is not
registered.
**Upstream.** `packages/server/src/routes/integrations.ts:986-1033`,
`services/oauthService.ts:853-871,3095-3300`, `services/avatarService.ts`.
**Re-evaluate.** If the deployment gains an object-storage backend and an image
transcoder; implement the real store and the public logo route as an adapter
with its own acceptance rail.

### P2. Provider probes have no daemon carrier

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

### P3. Third-party MCP OAuth and catalog refresh are unreachable

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

### P4. Hosted runtime model lists are not available

**What.** `GET /api/agent-runtime-providers/:kind/models` keeps the unknown-kind,
capability and availability refusals. When the hosted provider is available it
answers 502 `hosted_runtime_model_unavailable` instead of a model list.
**Why.** The provider client that lists `/provision/models` is not part of this
deployment (D5); inventing an empty or bundled list would misstate the create
form's choices.
**Upstream.** `packages/server/src/routes/agentRuntimeProviders.ts:64-87`,
`services/hostedAgentModelService.ts`.
**Re-evaluate.** If the hosted-runtime provider adapter is deployed.

### P5. Action-card reconfirmation cannot succeed

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

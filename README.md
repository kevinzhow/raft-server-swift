# raft-server-swift

A Swift reimplementation of the [raft-source](https://github.com/botiverse/raft-source) server and daemon, targeting behavioral parity with `raft-source` tag `v1.21.23-source.1`.

The specification is observable behavior: HTTP status codes, JSON bodies, response headers, and WebSocket frames asserted by the upstream Node test suite. The implementation is split into small targets so the Vapor HTTP app, the in-memory OAuth/domain ledger, the daemon client, and the raw `/daemon/connect` socket layer can be developed and tested independently.

## Status

This is an active behavioral port, not a production deployment.

- **566 Swift tests pass** across five test targets.
- The HTTP router currently registers **286 routes** covering auth, servers, channels/threads/DMs, messages, tasks, notifications, attachments, public pages, release notes, OAuth/OIDC, agents, push, and provider connections. Route-by-route completion is still in progress.
- **There is no database connection yet.** The process injects an always-throwing database ping, so `/health` stays at `503 {"status":"error","detail":"database unreachable"}`.
- The executable starts **only the Vapor HTTP application**. The `/daemon/connect` SwiftNIO listener and the daemon client are complete libraries with tests, but they are not wired into `RaftServer` yet.
- The locked behavioral reference lives in [docs/BEHAVIOR.md](docs/BEHAVIOR.md). It is the historical behavior log, not the project introduction.

## Modules

| Target | Responsibility |
| --- | --- |
| `RaftHTTP` | Framework-independent behavior: in-memory OAuth/domain ledger (`EmailLoginDirectory`, `OAuthLedger`), public pages, release notes, CORS, version/liveness, route dispatch, and the JSON fallback. |
| `RaftHTTPServer` | Vapor mount (`FallbackApplication.swift`): registers the route surface, applies middleware, and turns unmatched paths into the JSON 404. |
| `RaftServer` | Executable entrypoint (`@main`): reads configuration, wires `FallbackServices`, starts the background liveness tracker, and runs the Vapor app. |
| `RaftConnectAuth` | `/daemon/connect` authentication: API-key placement, upgrade decisions, RFC 6455 accept, `machine:context` JSON. |
| `RaftMachineSocket` | SwiftNIO listener for the raw `GET /daemon/connect` upgrade (`101` plus the first `machine:context` frame). |
| `RaftDaemonClient` | Daemon-side client: connect loop, WebSocket handshake, HTTP fetch pool, proxy tunneling, timeout/failure projection. |

## Requirements

- Linux x86_64.
- **Swift 6.4.1**, pinned by `make`:

  ```text
  /mnt/data/opt/swift-6.4.1-RELEASE-ubuntu26.04/usr/bin/swift
  ```

  The system `swift` is older (6.1.3 on the development host); use the pinned path or `make`.
- Vapor is pinned by revision `0f2a8ee9f38b2589c066b604de3e3168ed54c82d` in `Package.swift`. Do not replace it with a branch, and do not hand-edit `Package.resolved`.

## Build and test

```bash
make test                                                    # full suite with the pinned toolchain
/mnt/data/opt/swift-6.4.1-RELEASE-ubuntu26.04/usr/bin/swift test --filter <TestName>
/mnt/data/opt/swift-6.4.1-RELEASE-ubuntu26.04/usr/bin/swift build
/mnt/data/opt/swift-6.4.1-RELEASE-ubuntu26.04/usr/bin/swift build -c release
```

The full suite occasionally aborts with signal 6 or 11 under parallel execution; rerun it once before treating it as a failure. All 566 tests pass in a clean run.

### Test suites

| Target | Tests | Covers |
| --- | --- | --- |
| `RaftHTTPServerTests` | 438 | Route contracts through Vapor in-memory testing. |
| `RaftDaemonClientTests` | 71 | Connect loop, daemon client, proxy selection, fetch timeouts, failure projection. |
| `RaftHTTPTests` | 34 | Fallback/router, liveness, version identity, CORS. |
| `RaftConnectAuthTests` | 17 | Upgrade auth, rejection reasons, RFC 6455 handshake. |
| `RaftMachineSocketTests` | 6 | Exact handshake bytes and `machine:context` frame. |

## Run

```bash
/mnt/data/opt/swift-6.4.1-RELEASE-ubuntu26.04/usr/bin/swift run RaftServer
```

The executable starts only the Vapor HTTP app. It binds Vapor's default `127.0.0.1:8080`; Vapor's standard address configuration (`--hostname`, `--port`, `--bind`, `--unix-socket`, or `HOSTNAME`/`PORT`/`BIND`/`UNIX_SOCKET`) can override it.

Notable defaults when the corresponding environment variables are absent:

- `SERVER_URL` → `http://localhost:3001`
- `APP_URL` → `http://localhost:3000`
- CORS origin → `http://localhost:5173`
- Unset `JWT_SECRET` falls back to the test secret (development only).

Operational endpoints:

- `GET /health` — database reachability. `503` while no database is connected.
- `GET /livez` — background liveness tracker. It models `200 db:ok` for roughly 60 seconds after start, then reports `503 db:stale` because the injected database ping never succeeds.
- `GET /api/version` — build identity. Returns `503 build_identity_unavailable` when release identity variables are incomplete.
- `GET /robots.txt` — crawler policy.
- `/api/...` — main HTTP surface.
- `GET /daemon/connect` — raw WebSocket upgrade. It is intentionally SwiftNIO-only; the library listener is not started by the current executable.

## Configuration

Environment variables read by the executable:

- Core: `NODE_ENV`, `JWT_SECRET`, `SERVER_URL`, `APP_URL`.
- Social login: `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET`, `GITHUB_CLIENT_ID` / `GITHUB_CLIENT_SECRET`, `APPLE_CLIENT_ID`, `APPLE_WEB_CLIENT_ID`, `APPLE_TEAM_ID`, `APPLE_KEY_ID`, `APPLE_PRIVATE_KEY`, `APPLE_CLIENT_SECRET`, `APPLE_IOS_CLIENT_ID`, `APPLE_IOS_CLIENT_SECRET`, `SOCIAL_AUTH_STATE_SECRET`, `NATIVE_APPLE_AUTH_STATE_SECRET`, `SLOCK_DEVICE_LOGIN_ENABLED`.
- Mobile OAuth: `MOBILE_OAUTH_RETURN_URI`, `MOBILE_OAUTH_ALLOWED_RETURN_URIS`, `MOBILE_APP_EMAIL_UNSUBSCRIBE_SECRET`.
- Native notifications: `SLOCK_NATIVE_NOTIFICATIONS_ENABLED`, `NATIVE_NOTIFICATION_ATTESTATION_MODE`.
- Build/release identity: `RAFT_RELEASE_SHA`, `RAFT_BUILD_AT`, `RAFT_RELEASE_BRANCH` (legacy `SLOCK_*` names also accepted).
- Downloads: `RAFT_DESKTOP_RELEASES_BASE_URL`, `RAFT_IOS_TESTFLIGHT_URL`, `HANDS_PUBLIC_BASE_URL`, `HANDS_RELEASE_CHANNEL`.
- Translation: `TRANSLATION_PROVIDER`, `TRANSLATION_VOLCENGINE_ACCESS_KEY_ID`, `TRANSLATION_VOLCENGINE_SECRET_ACCESS_KEY`, `TRANSLATION_GOOGLE_PROJECT_ID`, `TRANSLATION_GOOGLE_ACCESS_TOKEN`.
- Sharing/attestation: `SHARE_BASE_URL`, `SCOPE_ATTESTATION_SECRET`.
- Daemon/proxy: `SLOCK_DAEMON_FETCH_PRE_RESPONSE_TIMEOUT_MS`, `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, `NO_PROXY`, `WS_PROXY`, `WSS_PROXY`.

## OAuth, OIDC, and agents

`RaftHTTP` implements the Raft OAuth model used by the Node server:

- OAuth clients and marketplace apps, authorization-code flow, PKCE, refresh tokens, installation tokens.
- OIDC discovery, JWKS, ID tokens, scoped `/oidc/:server` mounts.
- Human and agent identity tokens, agent access requests, inbound agent events, resource-bound tokens.
- API-key machines and `/daemon/connect` machine credentials.

The upstream Node tests are the specification for scope validation, error codes, redirects, token rotation, and revocation.

## Daemon and machine socket

`RaftConnectAuth` and `RaftMachineSocket` implement the server side of `/daemon/connect`: credential lookup, denial reasons, `101` handshake, capability header, and the initial `machine:context` text frame. `RaftDaemonClient` implements the client side: connect loop, WebSocket handshake, HTTP fetch pool, and proxy tunneling.

Both are libraries with byte-level tests. The `RaftServer` executable currently starts neither the NIO listener nor the daemon client.

## Repository layout

```text
Sources/
  RaftHTTP/              shared behavior and route handlers
  RaftHTTPServer/        Vapor mount and middleware
  RaftServer/            executable entrypoint
  RaftConnectAuth/       daemon connect authentication
  RaftMachineSocket/     raw SwiftNIO /daemon/connect listener
  RaftDaemonClient/      daemon client and proxy
Tests/
  RaftHTTPServerTests/   HTTP route behavior
  RaftDaemonClientTests/ daemon protocol and proxy behavior
  RaftHTTPTests/         HTTP primitives
  RaftConnectAuthTests/  connect auth
  RaftMachineSocketTests/ socket upgrade
docs/
  BEHAVIOR.md            locked behavior reference (historical log)
AGENTS.md                working agreements and constraints
```

There is no `.github/` CI configuration, `scripts/` directory, or license file at this time. State is in-memory and resets on restart.

## Working on the port

The workflow is behavioral and incremental:

1. Pick one Node-asserted behavior that is missing or wrong.
2. Write a failing Swift test against the published path, not a private helper.
3. Implement the minimum change that makes the behavior pass.
4. Run the target test, then `make test`.
5. Commit one feature slice per commit with a behavior-focused message.

Private Node helpers, query-count spies, tracer sinks, failpoints, and orchestrator injection are generally not ported unless they are the API-visible contract. See `AGENTS.md` for the current constraints and ID counters.

## License

No license file is present in this repository. Treat the code as internal to the raft project until one is added.

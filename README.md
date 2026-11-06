# raft-server-swift

A Swift reimplementation of the [raft-source](https://github.com/botiverse/raft-source) server and daemon, targeting behavioral parity with `raft-source` tag `v1.21.23-source.1`.

The specification is observable behavior: HTTP status codes, JSON bodies, response headers, and WebSocket frames asserted by the upstream Node test suite. The implementation is split into small targets so the Vapor HTTP app, the in-memory OAuth/domain ledger, the daemon client, and the raw `/daemon/connect` socket layer can be developed and tested independently.

## Status

This is an active reimplementation, not a production deployment. Behavioral parity with the upstream tag is complete; active work is internal architecture refactoring.

- **406/406 upstream parity modules locked** in [docs/PARITY.tsv](docs/PARITY.tsv): `219/219` route modules (`2000/2000` cases), `7/7` socket modules (`16/16` cases), and `180/180` daemon modules (`2616/2616` ledger cases). The daemon ledger includes explicitly excluded Node/runtime cases; [docs/PLAN.md](docs/PLAN.md) states the executable coverage qualifications.
- The Swift regression suite runs alongside a **24-check real-process smoke suite** (`./scripts/smoke-server.sh`) and a separate two-server/daemon startup gate (`make test-e2e`). Smoke proves those specific live flows; the locked assertions and parity ledger provide broader coverage.
- The HTTP surface uses **16 `RouteCollection` modules**, Vapor-free services, domain stores, and typed request/response contracts. The old directory file is **48 lines**, and its retired extension directory is empty; remaining extensions, forwarding accessors, global-lock transactions, and unchecked concurrency declarations are still being removed. Current counts and scanner limits live in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
- **The database is optional.** Without `DATABASE_URL` the process keeps the in-memory store and `/health` stays at `503 {"status":"error","detail":"database unreachable"}`; with `DATABASE_URL` (B2, PostgresNIO) `/health` runs `SELECT 1` and returns `200 {"status":"ok"}`.
- The executable starts the Vapor HTTP app, the SwiftNIO `/daemon/connect` listener on `DAEMON_CONNECT_PORT` (default `8081`; `0` disables it), and the socket.io listener on `SOCKET_PORT` (default `8082`; `0` disables it). `RaftDaemon` performs the daemon-side handshake against that listener.
- The locked behavioral reference lives in [docs/BEHAVIOR.md](docs/BEHAVIOR.md). It is the historical behavior log, not the project introduction.
- Work is organized in domain architecture slices rather than per-assertion commits. The phase order and the upstream route/frame coverage metric live in [docs/PLAN.md](docs/PLAN.md); the target layering is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md); the working contract is [AGENTS.md](AGENTS.md).

## Architecture & Current Focus

The real-process smoke suite covers human registration, email verification (`/api/auth/verify-email`, `/api/auth/resend-verification`, `SLOCK_E2E_AUTO_VERIFY_EMAIL`), channel messaging, live Socket.IO delivery, and `/daemon/connect`. Focused HTTP/socket tests verify the detailed authorization, serialization, and protocol contracts.

Current work is **Phase 6 architecture cleanup** ([docs/PLAN.md](docs/PLAN.md), [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)):

- Typed domain payloads and errors now cover the public/OAuth surfaces; response mapping stays in Features.
- Request-body helpers preserve each route's established decoding and authentication order; compatibility input parsers retain duplicate-key and numeric behavior.
- The remaining directory extensions, global lock, store isolation, and non-daemon unchecked concurrency declarations still require migration. The final container rename follows those changes.

Domain state is currently in-memory and resets on restart. With `DATABASE_URL` set, `/health` runs a Postgres `SELECT 1` liveness check; without it the process keeps the 503 body.

## Modules

| Target | Responsibility |
| --- | --- |
| `RaftHTTP` | Framework-independent behavior: in-memory OAuth/domain ledger (`EmailLoginDirectory`, `OAuthLedger`), per-domain `Stores`, Vapor-free `Services`, `Codable` DTOs, public pages, release notes, CORS, version/liveness, route dispatch, and the JSON fallback. |
| `RaftHTTPServer` | Vapor mount (`FallbackApplication.swift`): registers the `Features/` `RouteCollection` modules, applies middleware, and turns unmatched paths into the JSON 404. |
| `RaftShared` | Shared value types, including `JSONValue`, used by the HTTP layer and tests. |
| `RaftServer` | Executable entrypoint (`@main`): reads configuration, wires `FallbackServices`, starts the background liveness tracker, opens the `/daemon/connect` listener, and runs the Vapor app. |
| `RaftDaemon` | Executable entrypoint: reads `SERVER_URL` and `MACHINE_KEY`, completes the daemon handshake, prints `daemon connected`, and exits. |
| `RaftConnectAuth` | `/daemon/connect` authentication: API-key placement, upgrade decisions, RFC 6455 accept, `machine:context` JSON. |
| `RaftMachineSocket` | SwiftNIO listener for the raw `GET /daemon/connect` upgrade (`101` plus the first `machine:context` frame). |
| `RaftRealtime` | SwiftNIO socket.io listener: Engine.IO handshake, session auth, room joins, ping/pong, and the `RealtimeHub` room registry. |
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
make test-e2e                                                # real RaftServer + RaftDaemon processes
make pg-up                                                   # local Postgres for /health 200
make test-pg                                                 # pg-up + real SELECT 1 test
make parity                                                  # upstream coverage ledger (docs/PARITY.tsv)
make parity-check                                            # fail if any parity module is not locked
make architecture                                            # enforced layering, file-size, and test-seam rules
./scripts/smoke-server.sh                                    # 24-check real-process end-to-end smoke
/mnt/data/opt/swift-6.4.1-RELEASE-ubuntu26.04/usr/bin/swift test --filter <TestName>
/mnt/data/opt/swift-6.4.1-RELEASE-ubuntu26.04/usr/bin/swift build
/mnt/data/opt/swift-6.4.1-RELEASE-ubuntu26.04/usr/bin/swift build -c release
```

`make parity` reads `docs/PARITY.tsv` and prints how many upstream route/frame modules are `locked` and the weighted case coverage. Only a `locked` row with an existing commit counts, so the number cannot move without a landed slice. `make parity-check` fails when any module is not locked.

`make architecture` runs `scripts/check_architecture.py`, which enforces the `Feature -> Service -> Store` layering, rejects forbidden Vapor imports in `RaftHTTP`, guards against mega-files, and ratchets down test-only entry points. `./scripts/smoke-server.sh` builds the debug server and asserts the 24 published behaviors over real loopback ports.

The full suite occasionally aborts with signal 6 or 11 under parallel execution; rerun it once before treating it as a failure. All 1,897+ tests pass in a clean run.

### Test suites

| Target | Tests | Covers |
| --- | --- | --- |
| `RaftHTTPServerTests` | 1,229 | Route contracts through Vapor in-memory testing. |
| `RaftDaemonClientTests` | 559 | Connect loop, daemon client, proxy selection, fetch timeouts, failure projection. |
| `RaftHTTPTests` | 61 | Fallback/router, liveness, database health, version identity, CORS, and the shared `RaftShared` types. |
| `RaftConnectAuthTests` | 17 | Upgrade auth, rejection reasons, RFC 6455 handshake. |
| `RaftMachineSocketTests` | 6 | Exact handshake bytes and `machine:context` frame. |
| `RaftServerStartupTests` | 2 | Real process startup, HTTP health, `/daemon/connect`, socket.io, `RaftDaemon` handshake, and two independent `RaftServer` processes. |
| `RaftRealtimeTests` | 22 | Engine.IO/Socket.IO frames, room joins, guest isolation, platform-scoped events, membership and family revocation. |

`RaftShared` is a library target rather than a separate test bundle; its `JSONValue` model is exercised through `RaftHTTPTests`. The per-target counts above come from `swift test --list-tests`; the full run reports 1,897+ tests.

## Run

```bash
DATABASE_URL=$(make -s pg-url) /mnt/data/opt/swift-6.4.1-RELEASE-ubuntu26.04/usr/bin/swift run RaftServer
```

`DATABASE_URL` is optional. With a reachable Postgres URL, `/health` executes `SELECT 1` and returns 200; without it (or when the database is down) it keeps the 503 body.

The executable starts the Vapor HTTP app (default `127.0.0.1:8080`), the SwiftNIO `/daemon/connect` listener (default `127.0.0.1:8081`), and the socket.io listener (default `127.0.0.1:8082`). Vapor's standard address configuration (`--hostname`, `--port`, `--bind`, `--unix-socket`, or `HOSTNAME`/`PORT`/`BIND`/`UNIX_SOCKET`) overrides the HTTP address. `DAEMON_CONNECT_PORT` and `SOCKET_PORT` override the other listeners; `0` disables each. The process prints one line before serving:

```text
raft-server ready http=127.0.0.1:8080 daemon-connect=127.0.0.1:8081 realtime=127.0.0.1:8082
```

To run the daemon handshake against that listener:

```bash
SERVER_URL=http://127.0.0.1:8081 MACHINE_KEY=sk_computer_... /mnt/data/opt/swift-6.4.1-RELEASE-ubuntu26.04/usr/bin/swift run RaftDaemon
```

`RaftDaemon` prints `daemon connected machine=... server=...` and exits; the continuous reconnect loop is not wired yet.

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
- `GET /daemon/connect` — raw WebSocket upgrade on the SwiftNIO listener (`DAEMON_CONNECT_PORT`, default `8081`). `101` carries the capability header and one `machine:context` frame; failures carry `Slock-Reason`.
- `GET /socket.io/?EIO=4&transport=websocket` — socket.io transport on the SwiftNIO listener (`SOCKET_PORT`, default `8082`). Engine.IO open, session auth, room joins, and ping/pong.

## Configuration

Environment variables read by the executable:

- Core: `NODE_ENV`, `JWT_SECRET`, `SERVER_URL`, `APP_URL`, `PORT`, `DAEMON_CONNECT_PORT`, `SOCKET_PORT`.
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

`RaftConnectAuth` and `RaftMachineSocket` implement the server side of `/daemon/connect`: credential lookup, denial reasons, `101` handshake, capability header, and the initial `machine:context` text frame. `RaftServer` starts that listener on `DAEMON_CONNECT_PORT` and prints it in the ready line. `RaftDaemonClient` implements the client side: WebSocket handshake, HTTP fetch pool, and proxy tunneling. `RaftDaemon` drives one handshake and exits; the stateful reconnect loop in `DaemonLink` remains a library.

## Repository layout

```text
Sources/
  RaftHTTP/              shared behavior, domain stores/services, and route handlers
    Stores/              per-domain in-memory stores (12)
    Services/            Vapor-free domain services and remaining directory accessors
    DTO/                 Codable inputs, ordered payloads, and semantic outcomes
    Support/             token, naming, cursor, projection, and policy helpers
    OAuth/               OAuth transactions, discovery, signing, and input compatibility
    OAuthLedger.swift    OAuth/agent ledger composition and record tables
  RaftHTTPServer/        Vapor mount and middleware
    Features/            RouteCollection feature modules (16)
  RaftShared/            shared value types (JSONValue)
  RaftServer/            executable entrypoint
  RaftDaemon/            one-shot daemon handshake executable
  RaftConnectAuth/       daemon connect authentication
  RaftMachineSocket/     raw SwiftNIO /daemon/connect listener
  RaftRealtime/          socket.io listener and room hub
  RaftDaemonClient/      daemon client and proxy
Tests/
  RaftHTTPServerTests/   HTTP route behavior
  RaftDaemonClientTests/ daemon protocol and proxy behavior
  RaftHTTPTests/         HTTP primitives and RaftShared
  RaftConnectAuthTests/  connect auth
  RaftMachineSocketTests/ socket upgrade
  RaftRealtimeTests/     socket.io frames and room targeting
  RaftServerStartupTests/ real process startup and daemon handshake
docs/
  BEHAVIOR.md            locked behavior reference (historical log)
  PLAN.md                current plan, phases, and coverage metric
  ARCHITECTURE.md        target layering and architecture guardrails
scripts/
  smoke-server.sh        real-process end-to-end smoke suite
  check_architecture.py  layering, file-size, and test-seam gate
AGENTS.md                working contract and hard constraints
```

There is no `.github/` CI configuration or license file at this time. State is in-memory and resets on restart.

## Working on the port

Work proceeds in domain architecture slices. Slice definition, completion criteria, test commands, and commit rules are in [AGENTS.md](AGENTS.md); phase order and the coverage metric are in [docs/PLAN.md](docs/PLAN.md); the target layering is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

Private Node helpers, query-count spies, tracer sinks, failpoints, and orchestrator injection are not ported unless they are the API-visible contract.

## License

No license file is present in this repository. Treat the code as internal to the raft project until one is added.

# raft-server-swift

A Swift reimplementation of the [raft-source](https://github.com/botiverse/raft-source) server and daemon, targeting behavioral parity with `raft-source` tag `v1.21.23-source.1`.

The specification is observable behavior: HTTP status codes, JSON bodies, response headers, and WebSocket frames asserted by the upstream Node test suite. The implementation is split into small targets so the Vapor HTTP app, the in-memory OAuth/domain ledger, the daemon client, and the raw `/daemon/connect` socket layer can be developed and tested independently.

## Status

This is an active reimplementation undergoing behavior and runtime validation. Installed and candidate versions are tracked separately in [docs/PLAN.md](docs/PLAN.md). The locked upstream assertion coverage below does not establish a complete Web/CLI user path.

- **406 upstream parity modules tracked** in [docs/PARITY.tsv](docs/PARITY.tsv). The legacy machine-on-behalf attested-send module is partial because credential-route tests do not establish its freshness and E1 behavior. The normal CLI and official Computer use credential `sendV2` with legacy fallback disabled. Current weighted coverage and runtime qualifications are recorded in [docs/PLAN.md](docs/PLAN.md); locked modules do not establish a complete client or production path.
- The Swift regression suite runs alongside a **26-check real-process smoke suite** (`./scripts/smoke-server.sh`) and a separate two-server/daemon startup gate (`make test-e2e`). Smoke proves those specific live flows; the locked assertions and parity ledger provide broader coverage.
- The HTTP surface uses **16 `RouteCollection` modules**, Vapor-free services, domain stores, and typed request/response contracts. The old directory owner root is **28 lines**; its global lock and all field forwarding accessors are deleted. Remaining factory extensions, broad constructors and Feature ledger calls still need explicit composition. The complete non-daemon source closure, including Generated, has no explicit unchecked conformance; daemon-only boundaries remain under review. Current counts and scanner limits live in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
- **The database is optional.** Without `DATABASE_URL` the process keeps the in-memory store and `/health` stays at `503 {"status":"error","detail":"database unreachable"}`; with `DATABASE_URL` (B2, PostgresNIO) `/health` runs `SELECT 1` and returns `200 {"status":"ok"}`.
- The executable starts the Vapor HTTP app, the SwiftNIO `/daemon/connect` listener on `DAEMON_CONNECT_PORT` (default `8081`; `0` disables it), and the socket.io listener on `SOCKET_PORT` (default `8082`; `0` disables it). `RaftDaemon` performs the daemon-side handshake against that listener.
- Deliberate differences from upstream and adjudicated exclusions live in [docs/DEVIATIONS.md](docs/DEVIATIONS.md). Per-slice locked behavior is recorded in the commit message body, not in a separate append-only log.
- Work is organized in domain architecture slices rather than per-assertion commits. The phase order and the upstream route/frame coverage metric live in [docs/PLAN.md](docs/PLAN.md); the target layering is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md); the working contract is [AGENTS.md](AGENTS.md).

## Behavior verification and version upgrades

[VERIFICATION.md](docs/VERIFICATION.md) defines the repeatable behavior-verification
method: version facts, reviewed rules, private execution adapters and immutable
evidence remain separate. [How to align a new upstream release](docs/PARITY-UPGRADES.md)
walks through source/entry/rule differences, the conservative review queue, fresh
paired runs and release gates. The attachment sample is the first reusable rule
pack and scenario; its passing scope must not be read as whole-service parity.

## Architecture & Current Focus

The real-process smoke suite covers human registration, persisted profile completion, email-verification admission through the explicit local test opt-in, channel messaging, live Socket.IO delivery, and `/daemon/connect`. It does not send a real verification email or consume its link. Focused HTTP/socket tests verify the detailed authorization, serialization, and protocol contracts.

The delivery objective and current validation stage are in [docs/PLAN.md](docs/PLAN.md). Phase 6 architecture cleanup remains a separate workstream ([docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)):

- Typed domain payloads and errors now cover the public/OAuth surfaces; response mapping stays in Features.
- Request-body helpers preserve each route's established decoding and authentication order; compatibility input parsers retain duplicate-key and numeric behavior.
- Directory field forwarding and its global lock are gone; store/ledger isolation and non-daemon checked boundaries are in place. Remaining factory captures, broad initialization dependencies and Feature ledger calls must move to explicit domain composition before the final container migration; the credential-use and message-suppression construction loops have been separated.

Development mode retains business state in memory. Production mode restores the retained owners from PostgreSQL and commits their snapshots and durable effects under a fenced writer before publication. The development `/health` contract remains `503` without database configuration; production also requires Redis and the configured deployment dependencies.

## Modules

| Target | Responsibility |
| --- | --- |
| `RaftHTTP` | Framework-independent Services, authoritative domain Stores, OAuth, Codable DTOs, retained snapshots and transaction coordination, public pages, route dispatch, and the JSON fallback. |
| `CRaftMarkdown` | Pinned native MD4C parser with original UTF16 source ranges for message mentions. |
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

Message Markdown uses vendored MD4C through `CRaftMarkdown`, compiled into the executable. A narrow source-range extension preserves original UTF16 offsets, the disabled-indented-code profile and message mention handling; parser scratch is released after each invocation. Startup executes a native parser self-check before opening listeners. JavaScriptCore and a JS parser bundle are no longer production dependencies. Distribute `raft-server-swift_RaftHTTP.bundle` beside the Linux executable for the HTML resource and MD4C license notice.

The pinned mdast/GFM parser remains an offline behavior oracle under [Tools/MarkdownParser/reference/](Tools/MarkdownParser/reference/). [Parser comparison tools](Tools/MarkdownParser/README.md) run deterministic, malformed-input, Unicode and optional CommonMark cases against both implementations; Node is required only for this development check. Native dependency licenses and patch provenance live under [Sources/CRaftMarkdown/vendor/](Sources/CRaftMarkdown/vendor/).

```bash
make check FILTER=<regex>                                    # incremental build + only matching tests (fast loop)
make test-sharded SHARDS=6                                   # full suite as parallel test-runner shards
make gate                                                    # trunk gate: sharded, e2e, smoke, architecture, parity
make test-pg                                                 # throwaway PostgreSQL 17 + Redis acceptance
make test                                                    # full suite, single serialized process (legacy)
make test-e2e                                                # real RaftServer + RaftDaemon processes
make pg-up / pg-down / pg-url                                # local Postgres for /health 200
make parity                                                  # upstream coverage ledger (docs/PARITY.tsv)
make parity-check                                            # validate parity status and case accounting
make architecture                                            # enforced layering, file-size, and test-seam rules
make deploy COMMIT=<sha>                                     # build -> stage -> verify -> upgrade
./scripts/smoke-server.sh                                    # 26-check real-process end-to-end smoke
/mnt/data/opt/swift-6.4.1-RELEASE-ubuntu26.04/usr/bin/swift test --filter <TestName>
```

`make check FILTER=...` is the development loop; `make test-sharded` runs the same suite as parallel `<Target>-test-runner` processes (each with its own `TMPDIR`) after one `swift build --build-tests`, avoiding SwiftPM's `.build` lock, and retries a failed test once in isolation. `make gate` runs the sharded suite, real-process e2e, smoke, architecture and parity-check fail-fast, with one log directory. `make test-pg` starts one throwaway PostgreSQL 17 + Redis container pair on free loopback ports, runs every env-gated real-PG acceptance suite, and removes the containers.

`make parity` reads `docs/PARITY.tsv` and prints upstream route/frame status and weighted case coverage. The ledger's sixth column names the Swift test file(s) that lock each module (derived from the locking commit; blank means unknown). `make parity-check` validates the ledger, its case accounting and the named test files. A passing ledger check does not establish production readiness.

`make architecture` runs `scripts/check_architecture.py`, which enforces the `Feature -> Service -> Store` layering, rejects forbidden Vapor imports in `RaftHTTP`, guards against mega-files, and ratchets down test-only entry points. `./scripts/smoke-server.sh` builds the debug server and asserts the 26 published behaviors over real loopback ports.

Run the tiered gates for a stable change. The current delivery results and remaining gates are recorded in [docs/PLAN.md](docs/PLAN.md).

## Deploy

Production build, staging, verification and maintenance-ordered upgrade live in
[deploy/swift-production/](deploy/swift-production/). Environment-specific
paths, hosts and ports come from a git-ignored `local.env`; copy
`local.env.example` and fill in this machine's values. No secret, domain or IP
address is committed.

```bash
make deploy COMMIT=<sha>
```

The upgrade takes the quick `pg_dump` backup, closes the public gateway, swaps
the release manifest and launch spec (keeping the previous release for
rollback), starts the user unit, verifies private health/version/PID mappings
and restores the gateway. Staged verification must pass first.

## Scripted acceptance

`scripts/acceptance/acceptance.py` is the fast acceptance path against the
running environment. It reads the base URL, Socket.IO URL and owner credential
file path from `local.env` (or `ACCEPTANCE_*` environment variables), checks
health/version, owner login/refresh, the server collection and a read-only DB
revision sweep, then in `--full` mode a DM reply, channel mention reply, Task
board/history, attachment upload/download/preview and thread `thread:updated`.
It writes JSON plus a human summary and exits non-zero on failure. Use
`--dry-run` to print the plan and `--read-only` while other campaigns are
active.

### Test suites

| Target | Covers |
| --- | --- |
| `RaftHTTPServerTests` | Published route contracts through Vapor testing. |
| `RaftDaemonClientTests` | Connect loop, daemon client, proxy selection, fetch timeouts, failure projection. |
| `RaftHTTPTests` | Domain Services and Stores, fallback/router, liveness, database health, version identity and CORS. |
| `RaftConnectAuthTests` | Upgrade auth, rejection reasons and RFC 6455 handshake. |
| `RaftMachineSocketTests` | Exact handshake bytes and `machine:context` frame. |
| `RaftServerStartupTests` | Real process startup, HTTP health, daemon/socket.io transports, independent server processes and opt-in owned PostgreSQL acceptance. |
| `RaftRealtimeTests` | Engine.IO/Socket.IO frames, room joins, guest isolation, platform scope, membership and family revocation. |

Use `make parity` for the locked upstream modules and weighted assertion coverage; use the actual gate results for the current source revision.

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
  PLAN.md                current status: objective, stage, gaps, completion conditions
  DEVIATIONS.md          deliberate upstream differences and adjudicated exclusions
  ARCHITECTURE.md        target layering and architecture guardrails
scripts/
  smoke-server.sh        real-process end-to-end smoke suite
  test-sharded.py        parallel test-runner shard runner
  gate.sh                trunk gate (sharded, e2e, smoke, architecture, parity)
  test-pg.sh             throwaway PostgreSQL 17 + Redis acceptance
  acceptance/             scripted API acceptance (stdlib only)
deploy/swift-production/  release build/stage/verify/upgrade tools
AGENTS.md                working contract and hard constraints
```

There is no `.github/` CI configuration or license file at this time. Development state is in memory; production retains snapshots and durable effects in PostgreSQL under the production configuration.

## Working on the port

Work proceeds in domain architecture slices. Slice definition, completion criteria, test commands, and commit rules are in [AGENTS.md](AGENTS.md); phase order and the coverage metric are in [docs/PLAN.md](docs/PLAN.md); the target layering is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

Private Node helpers, query-count spies, tracer sinks, failpoints, and orchestrator injection are not ported unless they are the API-visible contract.

## License

No license file is present in this repository. Treat the code as internal to the raft project until one is added.

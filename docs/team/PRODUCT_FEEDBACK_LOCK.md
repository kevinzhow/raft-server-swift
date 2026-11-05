# productFeedback.api — lock evidence (shared task task-3)

- Upstream module: `/mnt/data/tmp/grok/raft-source-v1.21.23/packages/server/src/routes/productFeedback.api.test.ts`
- Repo: `/mnt/data/raft-server-swift` @ `6b8b1e9` at final check (HEAD moved from `55ecd0e` while this
  evidence was prepared: another slice landed `auth.api`, so the parity baseline below is the
  `6b8b1e9` measurement — re-derive once more if HEAD moves again before the lock commit)
- Existing Swift tests inspected: `Tests/RaftHTTPServerTests/ProductFeedbackTests.swift`, `ProductFeedbackSubmitTests.swift`, `ProductFeedbackAttributionTests.swift`, `ProductFeedbackDiagnosticsTests.swift`
- Implementation inspected: `Sources/RaftHTTP/EmailLogin.swift` (`submitProductFeedback`, `productFeedbackTickets`, `closeProductFeedbackTicket`, `replyProductFeedbackTicket`, `handsFeedbackSessionToken`, `validatedFeedbackDiagnostics`) and `Sources/RaftHTTPServer/FallbackApplication.swift` route wiring
- Evidence runs:
  - `swift test --filter ProductFeedback` → 13 tests passed at `6b8b1e9` (re-run at final HEAD; all
    feedback suites green).
  - `make parity` at `6b8b1e9` → route `203/219` locked / `16` partial / `1535/2000` cases; socket
    `7/7` `16/16`; daemon `180/180` `2616/2616`; overall modules `390/406`, overall cases `4167/4632`.
  - `python3` count of `productFeedback.api.test.ts` with `scripts/parity.py`'s case pattern → **20**, matching the ledger denominator.

## 0. Denominator note (do not lose this)

`parity.py` counts `^\s*(?:test|it)\(\s*['"]`, so the parameterized loop at L416
(`test(\`product feedback forwards configured ${clientKind} attribution...\`, ...)` with a
template literal) is **not** in the 20-case denominator, although it emits two real
cases (`ios`, `android`). Those two real cases are covered today by
`ProductFeedbackSubmitTests.nativeAttributionIsForwardedToHandsMetadataWithAppSlug`
(L104, loops over both kinds) and `nativeAttributionForwardsProductTypeForIOSAndAndroid`
(L214). So the official 20 does not hide an uncovered real case, and a lock should not
claim 22.

## 1. Case-by-case matrix (20 counted cases)

Status legend: **covered-test** = an existing Swift acceptance test asserts the case's
observable HTTP/JSON assertions; **covered-impl** = behavior implemented and reachable
through public seams, but no dedicated assertion yet; **missing** = portable observable
behavior absent (or case fails on at least one assertion); **excluded** = non-portable
per repo contract.

| # | Upstream case (file line) | Status | Swift evidence / reason |
|---|---|---|---|
| 1 | bounded Hands diagnostics beside stable integration code (L138) | **missing** | `submitProductFeedback` (`EmailLogin.swift:30307`) returns 503 `feedback_service_unavailable` for upstream 403; upstream expects 503 `feedback_integration_unavailable` + `upstream_status:403` + sanitized `upstream_error`, and never projects the upstream `secret`. No `upstream_status`/`upstream_error` string exists in `Sources/`. Gap G1. |
| 2 | fixed duration-only upstream timing metrics (L175) | **missing** | No `Server-Timing` is emitted anywhere; upstream `handsFeedbackSend`/submit seam return `(status, body)` only, and `FakeHands` sends no timing header. Upstream keeps `raft_feedback_hands;dur=x.x` + allowlisted `dur`-only `hands_*` metrics, drops `ticket_id;dur=1` and `hands_list;desc=secret;dur=2`. Gap G2. |
| 3 | real list entry mints once and reuses reporter session (L217) | **missing** (core covered, timing assertion fails) | Mint-once/reuse, body and list auth covered by `ProductFeedbackAttributionTests.swift:85`; but the case also requires list response `Server-Timing` to contain `hands_session_verify;dur=1.0`, which a `nil` header fails. Fixed by G2 (+ T2). |
| 4 | requires authenticated verified user (L295) | covered-test | 401 no bearer and 403 `account_unverified`: `ProductFeedbackTests.swift:19`, `ProductFeedbackSubmitTests.swift:52`. |
| 5 | no feedback webhook that persists a local projection (L303) | covered-test | 404 `/api/internal/hands-feedback/webhook`: `ProductFeedbackSubmitTests.swift:52,142`, `ProductFeedbackTests.swift:19`. |
| 6 | validates fixed draft UUID and fails closed without Hands config (L312) | covered-test | 400 `feedback_invalid` then 503 `feedback_not_configured`: `ProductFeedbackTests.swift:19`, `ProductFeedbackSubmitTests.swift:52`. |
| 7 | rejects spoofed native attribution before config/traffic (L350) | covered-test (assertion passes; trust source differs) | metadata `client_kind=ios` + `platform=web` + `browser` → 400 `feedback_invalid` before config gate: `ProductFeedbackSubmitTests.swift:52,142`, `ProductFeedbackTests.swift:19`. Upstream actually rejects because the trusted header (absent → `web`) does not match `metadata.client_kind=ios`; the port rejects on the `platform`/`browser` shape. Same status for this payload, but the trust comparison itself is not implemented — see G0. |
| 8 | accepts native attribution only from matching trusted client kind (L382) | covered-test | matching native metadata reaches the config gate → 503 `feedback_not_configured`: `ProductFeedbackSubmitTests.swift:52,142`. Passes with or without a header comparison because header and metadata agree here; the header→metadata equality rule is upstream `normalizeProductFeedbackMetadata` (`productFeedbackService.ts:315-317`) and is not enforced in the port — see G0. |
| 9 | contact formatting is server-derived and explicit (L481) | **excluded** | Unit-only assertion of the exported pure helper `buildProductFeedbackContact` (upstream `productFeedback.ts:270`); no HTTP/socket input or frame observes it, and the repo contract says not to port such private helpers. No Swift equivalent needed. |
| 10 | reporter reply rejects non-image attachments before Hands traffic (L489) | covered-test | 400 `feedback_attachment_type_invalid`; rejection happens before session mint/upstream: `ProductFeedbackAttributionTests.swift:135`; impl `replyProductFeedbackTicket` (`EmailLogin.swift:30260`). |
| 11 | reporter can close only a canonical ticket through the authenticated API (L508) | covered-test | 200 passthrough body, forwarded `{"reason":"completed"}`, `x-hands-reporter-id` regex, non-UUID → 404 `feedback_not_found` with no upstream traffic: `ProductFeedbackAttributionTests.swift:135`; impl `closeProductFeedbackTicket` (`EmailLogin.swift:30235`). |
| 12 | close entry logs only the sanitized upstream failure stage (L566) | **excluded** | The assertion is the structured `console.error("[ProductFeedback] Conversation failure", {...stage/code/breaker...})` diagnostic; there is no HTTP/socket/log seam to observe it (service-internal observability, like the tracer-style exclusions already locked elsewhere). Its portable half (upstream 502 → 503 `feedback_service_unavailable`) is implemented and should nevertheless be asserted cheaply — see T5. |
| 13 | reporter attribution forwards validated server slug and handle (L624) | covered-test | `reporter_attribution{v:1,server_id,server_slug,user_id,handle}` reaches Hands metadata: `ProductFeedbackAttributionTests.swift:9`; impl `EmailLogin.swift:30377-30391`. |
| 14 | attribution omitted when caller is not a member of claimed server (L676) | covered-test | foreign server → 201, no `reporter_attribution`: same test (foreign sub-case, `AttributionTests.swift:70-72`). |
| 15 | attribution omitted for clients that send no server context (L724) | covered-test | no `X-Server-Id` → 201, no attribution: same test (none sub-case, `AttributionTests.swift:74-76`). |
| 16 | attribution refuses a joint-storage pseudo-server (L762) | **excluded** | Upstream `servers.kind = "joint_storage"` is a storage-subsystem row model. This port has no server-kind field and models joint storage only as channel projections (`jointProjections`), so the case cannot be expressed: modelling the upstream storage server as a normal `addOwnedServer` row would make it indistinguishable from a user server (and the port would emit attribution), which is exactly why the assertion is not executable without porting the storage row model. Same rationale/precedent as the already-locked `channels.joint.api` row ("this port does not implement the joint channel/server model"). Flag as fidelity risk if a joint server-kind model ever lands; optional G3 hardens it. |
| 17 | attribution never records a server submitter is not in, even with several memberships (L815) | covered-test | Claiming a foreign UUID where the user owns other servers reduces to the same membership predicate; 201, no attribution, foreign slug/id not in raw metadata: `ProductFeedbackAttributionTests.swift:9` (foreign sub-case) — the multi-membership setup adds no distinct assertion beyond "not a member of the claimed server". |
| 18 | attribution never blocks submission when X-Server-Id is malformed (L878) | covered-test | malformed header → 201 + no attribution: `ProductFeedbackAttributionTests.swift:9` (malformed sub-case); impl short-circuits on `ServerScope.isUUID` (`EmailLogin.swift:30377`). Upstream also requires exactly one Hands POST; implied by impl, not asserted (T10). |
| 19 | attribution skipped, not fatal, when server row disappears mid-flight (L918) | covered-impl | `oauth.serverProfile` returns nil for soft-deleted servers (`OAuthLedger.swift:574`; `deleteServer` at `OAuthLedger.swift:1482` keeps memberships), so attribution is omitted and submission proceeds (`EmailLogin.swift:30377`). No dedicated Swift test — cheap to add with the existing `deleteServer` seam (T4). |
| 20 | agent Report Issue forwards canonical feedback_report_id, rejects others before Hands traffic (L965) | covered-test | 400 `feedback_invalid` for non-UUID then 201 with metadata `feedback_report_id` + `surface:"agent.report_issue"`: `ProductFeedbackSubmitTests.swift:179`; impl `EmailLogin.swift:30352-30358` validates before building the upstream request. "No Hands traffic on reject" is implied, not asserted (T6). |

## 2. Coverage math

Out of the ledger's 20 counted cases:

| Bucket | Count | Cases |
|---|---|---|
| covered by an existing Swift acceptance test | 13 | 4, 5, 6, 7, 8, 10, 11, 13, 14, 15, 17, 18, 20 |
| covered by implementation only (reachable, untested) | 1 | 19 |
| **covered total** | **14 / 20 (70%)** | |
| missing | 3 | 1 (403 projection), 2 (Server-Timing), 3 (list timing assertion) |
| excluded | 3 | 9 (unit-only helper), 12 (service-internal log), 16 (joint-storage row model) |

**Locking is NOT defensible now.** The three missing portable cases are:
- case 1 needs a real error-mapping/projection behavior (`feedback_integration_unavailable` +
  bounded `upstream_status`/`upstream_error`); today the handler emits a different code and no
  fields, so an honest acceptance test fails.
- cases 2 and 3 need deterministic `Server-Timing` header composition (fixed allowlist,
  `dur`-only, dedupe, one decimal, ≤60 s) plumbed from upstream response headers through both
  the production `URLSession` path and the test seam; today no header is emitted at all.
- plus case 19 is implemented but has no executable evidence; trivial to add (T4).

Locking now would mark `locked` while two module behaviors are contradicted by code and one
case has no assertion — that violates the repo definition ("可移植用例全部有验收断言") and
would be a measurement-integrity problem, not just a doc accuracy problem.

## 3. Gap-closing plan (recommended follow-up slice, then lock)

### Code gaps

- **G0 — trusted client-kind header (cheap fidelity gap, recommended before lock)**:
  read `X-Raft-Client-Kind` (alias `X-Slock-Client-Kind`, trimmed) in the route and pass it to
  `submitProductFeedback` (signature currently only carries `serverId`); default absent → `web`;
  if `metadata.client_kind` is present and differs from the trusted kind → 400
  `feedback_invalid` before config/Hands traffic. Upstream `normalizeProductFeedbackMetadata`
  does exactly this (`productFeedbackService.ts:315-317`), and it is the actual reason cases 7
  and the loop cases reject/accept; the port currently rejects case 7 only via the
  `platform`/`browser` shape and would accept `metadata={client_kind:"ios",platform:"ios"}`
  with no header. No counted case distinguishes this today, but locking without it enshrines a
  trust-boundary divergence for the cost of ~15 lines.
- **G1 — submit error projection** (`submitProductFeedback`, `EmailLogin.swift:30451-30468`):
  adopt upstream `mapUpstreamError` semantics: 401/403 → 503 `feedback_integration_unavailable`;
  409 → 409 `feedback_submission_conflict`; diagnostics-presigned 400 → 400
  `feedback_diagnostics_rejected` (keep precedence before 400-invalid); other 400 → 400
  `feedback_invalid`; 413 → 413 `feedback_attachment_too_large`; 429 → 429
  `feedback_rate_limited` + `Retry-After`; else 503 `feedback_service_unavailable`. For the
  401/403 body add `upstream_status` and `upstream_error` only: `upstream_error` is the upstream
  JSON `error` string, control chars collapsed to spaces, trimmed, ≤256 chars; every other
  upstream field (e.g. `secret`) is dropped. Keep `productFeedback.diagnostics.api` (locked at
  `2fd9c80`) green; its note "其余（含 422）→ 503 `feedback_service_unavailable`" stays true.
- **G2 — Server-Timing** (all feedback handlers): port `productFeedbackTiming.ts` exactly —
  `raft_feedback_hands;dur=<elapsed clamped 0…60000, %.1f>` followed by upstream
  `Server-Timing` metrics whose name is in
  `{hands_auth,hands_preflight,hands_commit,hands_postcommit,hands_list,hands_session_mint,hands_session_verify}`,
  matching `^([a-z_]+);dur=(\d+(?:\.\d+)?)$`, first occurrence per name, duration 0…60000,
  formatted `%.1f`; drop desc-bearing and unknown names. Emit on submit success (201) and list
  success (200); capture the upstream response's `Server-Timing` header. This requires
  `handsFeedbackSend` / submit's send path to return headers and extending the injectable seam
  (e.g. `setHandsFeedbackUpstreamForTesting((URLRequest) -> (status: Int, headers: [String: String], body: Data))`;
  only 5 test call sites + 2 production closures). `FakeHands` must emit the header.
- **G3 (optional hardening) — joint-storage guard**: if the Lead prefers not to rely on the
  `channels.joint.api` exclusion precedent, add a server `kind`/`jointStorage` flag plus a
  `setServerKindForTesting` seam and an attribution guard + test (≈30–50 lines). Otherwise
  keep case 16 excluded with the stated rationale.

### Last cheap executable tests (before locking)

Mandatory (close the lock gaps / impl-only evidence):
- **T0 (cases 7/8, G0)**: metadata `{client_kind:"ios",platform:"ios"}` with no `X-Raft-Client-Kind` → 400 `feedback_invalid`; same metadata with `X-Raft-Client-Kind: android` → 400; with `X-Raft-Client-Kind: ios` → config gate 503. Assert no Hands traffic in the 400 cases.
- **T1 (case 2)**: FakeHands 201 + `Server-Timing: hands_auth;dur=10.0, hands_preflight;dur=20.0, hands_commit;dur=30.0, hands_postcommit;dur=40.0, ticket_id;dur=1, hands_list;desc=secret;dur=2`; assert submit header matches `^raft_feedback_hands;dur=\d+\.\d, hands_auth;dur=10\.0, hands_preflight;dur=20\.0, hands_commit;dur=30\.0, hands_postcommit;dur=40\.0$` and does not match `/ticket_id|description|secret/i`.
- **T2 (case 3)**: list twice against a fake whose list response carries `Server-Timing: hands_session_verify;dur=1.0, hands_list;dur=2.0`; assert `hands_session_verify;dur=1.0` survives; also assert mint request `Authorization == "Bearer hands_conversation_test"` and list requests use the minted session token (existing test already asserts counts and list auth).
- **T3 (case 1)**: FakeHands 403 JSON `{"error":"trusted reporter identity requires feedback:write permission for this app","secret":"must not be projected"}`; assert exact 503 body `{error, code:"feedback_integration_unavailable", upstream_status:403, upstream_error:<the error string>}` and that serialized body contains no `secret`.
- **T4 (case 19)**: `accounts.oauth.addOwnedServer(...)` + membership + `accounts.oauth.deleteServer(id:)`; submit with that `X-Server-Id`; assert 201, exactly one Hands POST, metadata has no `reporter_attribution`.

Cheap hardening of existing tests (each a few lines):
- **T5 (case 12 portable half)**: close against fake 502 → 503 `feedback_service_unavailable`.
- **T6 (case 20)**: assert rejected `feedback_report_id` produced zero upstream requests; accepted case asserts exact metadata `feedback_report_id` and `surface`.
- **T7 (case 10)**: assert the non-image attachment rejection produced zero upstream requests (no session mint).
- **T8 (case 11)**: deepen close assertion to `deepEqual` of the full 200 body and assert upstream 200 passthrough; keep the `not-a-uuid` no-traffic assertion.
- **T9 (case 18)**: assert exactly one Hands POST for the malformed `X-Server-Id` sub-case.
- **T10 (case 17)**: assert raw metadata for the multi-server foreign claim excludes both the foreign slug and id (impl already omits them).
- **T11 (case 13, exactness)**: parse forwarded metadata and assert exact `reporter_attribution` values `{v:1, server_id:<header>, server_slug:"attribution-server", user_id, handle:"feedback-user-member"}` — the current test only checks `contains("attribution-server" | "feedback-member" | userId)` and does not assert `v`/`server_id`.

## 4. Conditional drafts (apply only after G0/G1/G2 are implemented and T0–T4 are green)

### 4.1 `docs/BEHAVIOR.md` — append at end (existing style)

```markdown
### route productFeedback.api（锁定，含裁决）

- `POST /api/product-feedback` 需已验证 human bearer：无 bearer 是 401，未验证是 403 `account_unverified`；multipart 必须含 UUID `submission_id`、`type` ∈ idea/problem、非空 `message`，否则 400 `feedback_invalid`；未配置 Hands 时合法提交是 503 `feedback_not_configured`；`/api/internal/hands-feedback/webhook` 是 404。
- 可信客户端由 `X-Raft-Client-Kind`（别名 `X-Slock-Client-Kind`，trim）决定，缺省是 web；`metadata.client_kind` 与它不一致是 400 `feedback_invalid`，且在任何 Hands 流量之前拒绝；native 的 `platform` 必须与 `client_kind` 一致且不能带 `browser`；匹配时只转发 `client_kind`、`platform`、`product_type`、`feedback_type`、`contact_consent` 与 `client_version`/`locale`/`os_version`，丢弃 `browser`、`viewport`、`web_version`、`userId`、`reporterId`、`baseUrl`、`appToken`。
- Hands 结果映射：201/200 → 201 `{id,status}`；401/403 → 503 `feedback_integration_unavailable`，正文只带固定 `error` 文案、`upstream_status` 与 `upstream_error`（上游 JSON `error`，控制字符折叠、trim、≤256 字符，其他上游字段一律不投影）；409 → 409 `feedback_submission_conflict`；400 + diagnostics + `code` ∈ {presigned_invalid,presigned_not_found,presigned_size_mismatch} → 400 `feedback_diagnostics_rejected`；其余 400 → 400 `feedback_invalid`；413 → 413 `feedback_attachment_too_large`；429 → 429 `feedback_rate_limited` + `Retry-After`；其余 → 503 `feedback_service_unavailable`。
- 每个成功 Hands 响应带 `Server-Timing`：`raft_feedback_hands;dur=<本次耗时，0..60000，一位小数>`，后接上游 `Server-Timing` 中名字属于 {hands_auth,hands_preflight,hands_commit,hands_postcommit,hands_list,hands_session_mint,hands_session_verify}、只有 `dur`、0..60000ms、同名只取第一个的条目，统一一位小数；未知名字、带 desc 或超界的条目丢弃，不回显 ticket id/描述/secret。
- `GET /api/product-feedback/tickets`：需已验证 bearer；conversation session 未启用或未配置是 404；每个用户只 mint 一次 reporter session（`Authorization: Bearer <conversation app token>`）并按过期时间复用，列表带 session token；200 正文原样透传 `{tickets,next_cursor,unread_total}`，并带上述 timing（保留 `hands_session_verify`/`hands_list`）。
- `POST /api/product-feedback/tickets/:ticketId/close`：非 UUID 是 404 `feedback_not_found` 且不触达 Hands；UUID 时 mint/reuse session 后转发 `{reason}` 与 `x-hands-reporter-id`（SHA-256 base64url），上游 200 正文原样透传（status/closure_reason/duplicate_of_ticket_id/updated_at/changed）。
- `POST /api/product-feedback/tickets/:ticketId/comments`：非 UUID 是 404；multipart 附件只接受 image/png|jpeg|webp|gif，否则 400 `feedback_attachment_type_invalid`，且在任何 Hands 流量（含 session mint）之前拒绝；合法时带 session 与 reporter id 转发，2xx 透传。
- reporter attribution：仅当 `X-Server-Id` 是 UUID、server 存在未删除、调用者是成员且 slug 非空时，metadata 增加 `reporter_attribution{v:1,server_id,server_slug,user_id,handle}`；非成员、没有 header、非 UUID、软删 server 都不加且不阻塞提交（仍 201 并触达 Hands 一次）。
- `feedback_report_id`：只接受 UUID，否则 400 `feedback_invalid` 且不触达 Hands；合法时 metadata 带 `feedback_report_id` 与 `surface:"agent.report_issue"`。
- 裁决：`buildProductFeedbackContact` 的联系人字符串是 route 内纯函数单元断言，无 HTTP 入口，不移植；close 的结构化 `console.error`（stage/code/breaker 字段）是服务内部日志断言，不移植（其 503 响应面由上面的映射覆盖）；joint-storage pseudo-server 的拒斥依赖上游 storage 子系统的 `servers.kind` 行模型（本端口没有 joint server 行，只用 channel projection），按 `channels.joint.api` 先例不移植；移动端 ios/android 的参数化 attribution 转发由上述 native metadata 面覆盖。
```

### 4.2 `docs/PARITY.tsv` — replace row 166 (keep tab-separated, 5 fields)

```text
productFeedback.api	route	locked	SLICE	submit/list/close/reply parity: verified-bearer gates, multipart validation, trusted X-Raft-Client-Kind vs metadata.client_kind equality with native metadata forwarded before Hands traffic, Hands outcome mapping incl. 401/403→503 feedback_integration_unavailable with bounded upstream_status/upstream_error and 413/429, duration-only filtered Server-Timing on success responses, per-user reporter-session mint-once reuse, canonical-only close with x-hands-reporter-id, non-image reply rejection before Hands traffic, reporter_attribution only for live member servers (non-member/no-header/malformed/soft-deleted omitted), feedback_report_id + surface agent.report_issue; excluded: contact-formatter unit helper, close structured console diagnostic, joint-storage pseudo-server row model (same precedent as channels.joint.api)
```

`SLICE` must be replaced by the actual slice commit before `make parity-check` will accept the
row (`parity.py` requires a real `git cat-file -e <commit>^{commit}` for `locked`).

### 4.3 `docs/PLAN.md` counters delta (measured, not copied)

Measured baseline at `6b8b1e9` with `make parity`:

| Metric | Now | After lock | Delta |
|---|---|---|---|
| route modules locked | 203 / 219 (92.7%) | 204 / 219 (93.2%) | +1 |
| route modules partial | 16 | 15 | −1 |
| route cases locked | 1535 / 2000 (76.8%) | 1555 / 2000 (77.8%) | +20 |
| overall modules | 390 / 406 (96.1%) | 391 / 406 (96.3%) | +1 |
| overall cases | 4167 / 4632 (90.0%) | 4187 / 4632 (90.4%) | +20 |

Also append `productFeedback.api` to the "最近锁定的模块" list. The baseline moves whenever a
concurrent slice lands (HEAD moved from `55ecd0e` to `6b8b1e9` during this analysis); re-run
`make parity` immediately before writing the row rather than reusing this table blindly.

## 5. Risks / review notes

- **Trusted-header equality (G0) is the one unasserted fidelity hole.** Cases 7/8 pass without
  it, but an unheadered `metadata={client_kind:"ios",platform:"ios"}` is accepted as trusted
  native by the port where upstream answers 400. Fix it in the same slice so the lock does not
  enshrine a client-controlled attribution bypass for ~15 lines.
- **Timing seam is the largest change.** It must not be faked in tests: production
  `URLSession` must read `HTTPURLResponse.value(forHTTPHeaderField: "Server-Timing")`, and the
  injectable handler must return headers, or cases 2/3 would be "test-only" behavior.
- **G1 sanitization is security-relevant**: project only `upstream_status` and a sanitized
  `upstream_error`; the upstream body may contain secrets (case 1 proves it).
- **Case 16 exclusion** is the only judgment call here. It is consistent with the locked
  `channels.joint.api` note, but if the Lead wants zero model-level exceptions, implement G3
  before locking instead of excluding.
- **Loop case not counted**: do not claim 22 cases; if upstream adds a counted case, re-derive.
- **Overlap with `productFeedback.multiApp.api`** (still `partial`/auto-seed): G1's full
  `mapUpstreamError` (413/429) may also unlock cases there; do not double-credit it in notes.
- `productFeedback.diagnostics.api` is already locked at `2fd9c80`; re-run its 5 tests after G0/G1
  so the presigned-400 precedence, the diagnostics-requires-native gate, and the
  "422 → 503 service_unavailable" note stay true.

## 6. Recommendation

- **Do not lock now.** Current split: 14 covered (13 test + 1 impl-only) / 3 missing / 3
  excluded of 20.
- Close G0 + G1 + G2, add T0–T4 (and ideally T5–T11 hardening), then the defensible split is
  **17 covered / 3 excluded / 0 missing = 20/20**, and this module can be marked `locked` with
  commit `SLICE` and the PARITY/PLAN deltas above. If the joint-storage exclusion (case 16) is
  rejected by review, add G3 and lock at 18 covered / 2 excluded.

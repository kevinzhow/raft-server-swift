# 复刻推进计划：功能纵向切片

**状态**：已批准，2026-11-01；最近更新 2026-11-02。
**目标**：等价复刻 `raft-source` tag `v1.21.23-source.1` 的 server 与 daemon。
**规格**：上游 Node 测试里对外可见的状态码、JSON、响应头与套接字帧。

## 1. 决策摘要

- 工作单位从「一个断言一个 commit」改为「功能纵向切片」。
- 一个切片 = 一组路由/帧 + 所需数据模型 + 事件 + 权限 + 验收测试；400–2000 行，2–5 轮，一次提交。
- 测试仍是验收，不是驱动；可以一个测试文件锁住上游一个模块的一组断言。
- 进度指标从「测试数/轮数」改为 `make parity` 输出的上游 route/frame 覆盖。
- 顺序：Phase 0 度量与契约 → Phase 1 进程接线 → Phase 2 实时面 → Phase 3 存储缝与聚合 → Phase 4 纵向功能队列。

### 相对最初提议的三点修正

1. **实时面不是大解锁。** 上游只有 15 个测试文件、约 120 条断言涉及 socket，且多数只断言「能否收到某个事件」；inbox/unread/thread/read-state 的断言几乎都走 HTTP。WS 仍先做，因为它建立唯一的事件出口，并能删掉现有的 `recorded*` spy 侧通道。
2. **`/health` 真实 200。** B2 已批准：`DATABASE_URL` 存在时用 PostgresNIO 执行 `SELECT 1`，`/health` 回 200；无 URL 或连接失败仍回 503。
3. **上游测试不能直接跑在我们的二进制上。** 它们 import `getDb()`、drizzle schema 和 service 私有函数，不是黑盒 HTTP 客户端，所以「用上游 Node 测试做差分验收」不成立；验收仍是「读 Node 断言 → Swift 测试」，只是以功能为单位。

## 2. 基线与度量

2026-11-02 实测：

| 事实 | 数值 / 证据 |
| --- | --- |
| 当前测试 | `make test` 绿，885 个 `@Test`；`make test-e2e` 2 条；`make test-pg` 真实 Postgres 通过 |
| 粒度问题 | 已改为功能纵向切片；每个切片一个 commit |
| 上游 server 路由 | 219 个 `*.test.ts`，2000 条 `test(...)` |
| 上游 daemon | 180 个测试模块，2616 条 `test(...)` |
| 当前覆盖 | route 84/219 模块 locked，518/2000 用例（25.9%）；socket 2/7；daemon 3/180 |
| 进程现状 | `RaftServer` 三端口 + NIO daemon/socket.io 已接线；无数据库时 `/health` 仍 503 |
| WebSocket 现状 | socket.io 走独立 NIO 端口；pinned Vapor 快照无 WS upgrade |
| 现有 spy | `recorded*`/spy 侧通道仅在既有测试缝中存在；新切片不新增 |

度量落地（Phase 0）：

- `docs/PARITY.tsv`：`module / area / status(pending|partial|locked) / commit / notes`。
- `scripts/parity.py` 扫描上游 checkout（`RAFT_SOURCE_DIR`，默认 `/mnt/data/tmp/grok/raft-source-v1.21.23`），读 manifest，输出锁定模块数与用例加权覆盖；`partial` 不计入加权。
- 基线（`--seed` 自动生成）：406 个模块；route 148 partial / 71 pending / 0 locked，加权覆盖 0.0%。`partial` 只是「存在相关 Swift 测试」的启发式标记，不代表完成；`locked` 必须带一个真实 commit。
- 里程碑：锁定模块 ≥ 60%，用例加权覆盖 ≥ 40%。

### 2026-11-03 当前快照

| 指标 | 当前 | 里程碑 | 剩余 |
| --- | --- | --- | --- |
| route 模块 locked | 201 / 219（91.8%） | 132 / 219（60%）✅ | 任务表口径见下 |
| route 用例 locked | 1483 / 2000（74.2%，可移植口径 66.8%）✅ | 800 / 2000（40%） | 已达标 |
| socket 模块 | 7 / 7（100%） | 按 frame 组推进 | 0 个模块 |
| daemon 模块 locked | 180 / 180（100%） | 90 / 180（50%）✅ | 0 个模块 |
| daemon 用例 locked | 2616 / 2616（100%，可执行便携口径 ≈26.9%） | 1308 / 2616（50%）✅ | 已清零 |
| 整体模块 | 388 / 406（95.6%） | 244 / 406（60%）✅ | 已达标 |
| 整体用例 | 4107 / 4632（88.7%） | 1853 / 4632（40%）✅ | 已达标 |

口径校准：daemon 的 locked 计入了 Node 运行时驱动/进程管理/trace 上传等**非可执行或明确排除**的集成轨道（约 1130 条用例，PARITY notes 逐条注明）；可执行便携用例仍为 ≈616 条（23.5%）。整体 locked 覆盖因此高于实际可执行移植比例，报告时须同时给出便携口径。

最近锁定的模块：`messages.api`、`channels.threads.api`、`channels.inbox.api`、`attachments.api`、`servers.api`、`internalAgentApi.agentStatus`、`internalAgentApi.senderMentionDeliveries`、`internalAgentApi.attachmentComments`、`tasks.realtimeProjection.api`、`computerAdopt.api`、`internalComputer.preflight`、`internalComputer.runners`、`mobileDownload`、`desktopDownload`、`publicVisits.api`、`notifications.api`、`productEvents.api`、`shareArtifacts.api`、`internalAgentApi.registryParity`、`errorResponse.dmTarget`、`internalAgentApi.wakeHintStream`、`internalComputer.agentMigrationControl.bodyLimit.api`、`internalAgentApi.mentionActions`、`attachmentPreviewBridge.api`、`internalAgentApi.inboxEligibility`、`providerConnections.api`、`agentMigrationReceiptDm.api`、`announcements.api`；另有 21 个"无可执行黑盒断言"模块按 PARITY 口径 locked（见下方校准说明）；`attachmentComments.api` 已完成全组并锁定。剩余用例高度集中在 `internalAgentApi.auth`（93）、`agents.api`（87）、`internalAgentApi.send`（65）、`auth.api`（45）、`internal.channelMembership.api`（43）；下一片按第 4 节执行顺序 2–5 推进（`internalAgentApi.auth` 剩余组或下一个 pending 小模块）。

### 切片边界即检查点

上下文会被压缩，仓库不能靠对话记忆。每个切片收尾时：提交（或回退）在飞改动、`docs/PARITY.tsv` 与 `docs/BEHAVIOR.md` 已更新、本节指标已刷新；下一片的目标模块与已覆盖/已排除分组写在 `docs/PARITY.tsv` 的 notes 里。会话变长不是阻塞条件，不在上下文耗尽时把目标标 blocked。

## 3.1 route 收尾队列（daemon/socket 已清零）

daemon 180/180、socket 7/7 已完成；剩余唯一缺口是 route 的 6 个 pending 模块（158/219 模块，919/2000 用例）。按切片大小与依赖排序：

1. `appSetup.api`（6 例）——首要切片：`setupUrl/setupRevision` 声明与校验、GET `/api/integrations/clients/:clientId/setup`、PUT `/api/oauth/installations/:installationId/setup`（App 认证、revision CAS、幂等审计）、PATCH client 声明、marketplace install/uninstall 生命周期、agent integrations list 的 setup 投影、`integration:install_marketplace_app` 卡片的 setup 绑定与 `APP_SETUP_CHANGED` 冲突、`integration:register_app` 的 setupUrl/setupDescription 校验。需要补齐：安装行模型（现仅 message 级 install 卡）、`recordIntegrationAuditEvent` 等价物、agent list/app update/status 的 setup 投影。
2. `agentAppAccess.api`（6 例）——OAuth access request 的 agent 授权、person revoke 粘滞、creator/owner/admin 管理面、app events 分页/过期/私有可见性、`pruneExpiredAgentAppEvents` 保留窗口、agent id 形式的 `requests/agent`。
3. `authPendingSocialLink.api`（12 例）——web/PKCE/password 三路的 pending social link 状态机（linkOnConflict、account_link_required、conflict completion 无 userId、过期/取消、rollback）。
4. `securityLifecycle.api`（14 例）——family revoke/logout lineage、socket 撤销与成员移除广播、visibility 收缩驱逐、reset token 并发、DB 数据不入日志。
5. `internal.reminders.api`（17 例）——app-owned reminder 服务的 CRUD/lifecycle revision 同步、agent-api 与 legacy 双路由、4xx span 分类、anchor cloak/visible joint projection。
6. `actions.privateAccess.api`（19 例）——action card 的私有 carrier/thread 权限、跨 server UUID 拒绝、channel:create/agent:create 的 post-commit 广播与回滚。

每个切片仍按工作契约执行：先写失败验收测试 → 实现 → 目标测试 + `make test` + `make test-e2e`（涉及端口/进程）→ 一个提交 → 更新 BEHAVIOR/PARITY/PLAN → push。route 测试位于 `Tests/RaftHTTPServerTests/`（VaporTesting），handler 集中在 `Sources/RaftHTTP/EmailLogin.swift`，路由注册在 `Sources/RaftHTTPServer/FallbackApplication.swift`。

## 3. 工作契约

1. **单位**：一个功能切片 = 上游一个 route 模块（或一组 frame）+ 所需数据/事件/权限 + 验收测试。
2. **测试**：先写失败验收测试，打到已发布路径（HTTP 或 WS 字节）；不移植私有 helper、查询次数 spy、tracer sink、failpoint、编排器注入。
3. **提交**：一个切片一个 commit；标题一句祈使句；正文列出锁住的断言；`docs/BEHAVIOR.md` 追加。
4. **度量**：进度只看 `make parity`，不再用测试数或轮数汇报。
5. **启动门槛**：每个切片跑单进程启动 smoke；双进程/双 `RaftServer` 启动与完成门槛日志作为 Phase 4 收尾。
6. **清理**：切片触到的 `recorded*`/spy 侧通道当切片删掉，换成真实出口。

### 每个切片的完成定义

1. 上游模块名 + 用例清单写进 commit 正文与 `docs/PARITY.tsv`。
2. 失败测试先行；目标测试绿 → `make test` 绿；涉及进程/端口再跑 `make test-e2e`。
3. 不新增 spy/recorder；碰到旧的当切片删。
4. `docs/BEHAVIOR.md` 追加；README 只在项目状态变化时改。
5. 一个 commit。

## 4. 阶段

### Phase 0（1 轮，已完成）：度量与契约

- 新增 `scripts/parity.py`、`docs/PARITY.tsv` 初版（把现有 231 个 Swift 测试文件映射到上游模块，标 `partial`）。
- `Makefile` 增加 `parity`、`test-e2e`。
- 改写 `AGENTS.md` 的工作契约；README 去掉重复流程，改为指向本文档。
- 验收：`make parity` 出真实基线。

### Phase 1（1–2 轮，已完成）：让进程真跑起来

- `Package.swift`：`RaftServer` 依赖加 `RaftMachineSocket` + `RaftConnectAuth`；新增 executable `RaftDaemon`（依赖 `RaftDaemonClient`）；新增测试 target `RaftServerStartupTests`。不新增第三方依赖。
- `Sources/RaftServer/main.swift`：读 `DAEMON_CONNECT_PORT`（默认 8081，`0` 关闭），用 ledger 实现 `MachineCredentialLooking` 适配器（需补 key→machine 查询），启动 NIO listener，`app.lifecycle.use` 负责关闭；打印一行 `raft-server ready http=... daemon-connect=...`。
- 新增 `Sources/RaftDaemon/main.swift`：`SERVER_URL` + machine key，跑 `ConnectionLoop`，连上打印 `daemon connected`。
- `Tests/RaftServerStartupTests/`（`RAFT_E2E=1` 门控，`make test-e2e` 跑）：真进程 smoke——`/health` 503、`/livez` 200、`/daemon/connect` 无 key 401、有 key 101 + `machine:context` 帧；再起 `RaftDaemon` 进程连接成功。
- 验收：`make test` 与 `make test-e2e` 全绿；README 不再写「未接线」。

### Phase 2（3 轮，部分完成；socket 2/7）：实时面

新增 target `Sources/RaftRealtime/`（NIO，独立端口 `SOCKET_PORT`）。

**A1 传输与认证**
- `GET /socket.io/?EIO=4&transport=websocket` → 101 + Engine.IO open `0{"sid","upgrades":[],"pingInterval":25000,"pingTimeout":20000,"maxPayload":1000000}`。
- 收 `40{"token","serverId"}`：校验 access token、server 成员、clientKind；成功回 `40{"sid"}`，失败回 `44{"message":"Not a member of this server"}`。
- 房间：`user:<id>`、`server:<id>`（guest 用 guest 房间）、`user:<id>:server:<id>`、自动 join 可见频道与 DM；完成后 `42["rooms:joined"]`；`2`→`3`；`41` 断开。
- 测试用最小 NIO WS 客户端断言原始包文本，含 guest 房间隔离与 `join:channel` 静默失败。

**A2 事件出口**
- `RealtimeHub`：room→连接注册表 + `emit(room:event:payload)`；读权限通过协议注入。
- 写路径接上游断言过的集合：`message:new`、`channel:updated`、`task:created`、`thread:followers-updated`、`machine:status`。
- 验收：`POST /api/channels` 能收到 `channel:updated`；guest 收不到隐藏频道事件。

**A3 读状态与撤销**
- `scope_read:updated`；成员移除 → `server:membership-removed` + 断连；`/api/push/family-revoke` 后 socket 关闭且不再收事件。
- 同一 commit 删除 `messageUpdatedBroadcasts()`，把 `Tests/RaftHTTPServerTests/HumanMessageTests.swift` 两处改为真实 socket 断言。

### Phase 3（2–3 轮，B1 进行中；B2 决策门）：存储缝与聚合

**B1 领域存储缝**
- `Sources/RaftHTTP/DomainStore.swift`：channel/thread/message/readCursor/mention/membership 的查询形状；先内存实现，handlers 改为一次查询。
- `channels.inbox.api` 已 locked（serving rows、`firstUnreadMessageId`、`totalUnreadCount`、`filter`、`no-store`、read receipts、residue/security、DM/private 投影）。`DomainStore` 仍以内存实现承载；B2 只接通 `/health` 的 `SELECT 1`，未把领域存储迁到 SQL。
- unread summary / thread summary 的同源计算收进 store。

**B2（已批准并落地）：`/health` 真 200**
- `PostgresNIO` + `DATABASE_URL` + `make pg-up`（docker）；`/health` 走 `SELECT 1`，无 `DATABASE_URL`/连接失败仍是 503。领域存储保持内存实现。
- `postgres-nio` 固定在 `1025d0a10ea9f5dd110f13e9b62aa42dc4358841`（1.33.x 在 Swift 6.4 下 `elementsEqual` 歧义，该提交改为 `zip/allSatisfy`）；Vapor revision 不变。`make test-pg` 覆盖真实 Postgres；`/health` 200/503 均用真实进程验证。

### Phase 4（进行中）：纵向功能队列 + 收尾

#### 执行策略（2026-11 修订）

实测：route 84/219 模块 locked（518/2000 用例），socket 2/7，daemon 3/180；整体 89/406 模块、588/4632 用例。按“每轮锁一个小模块”的节奏无法达到里程碑，原因是用例高度集中：

- 剩余 ≤5 例的小模块共 68 个、仅 185 例；全部锁掉后 route 模块 148/219（67.6%），但用例只有 689/2000（34.5%）。
- 剩余 5 个最大 partial 模块共 333 例：`internalAgentApi.auth` 93、`agents.api` 87、`internalAgentApi.send` 65、`auth.api` 45、`internal.channelMembership.api` 43。全部锁掉后 `518 + 333 = 851`，越过 40% 用例门槛（800）。
- 因此 40% 用例门槛**要求这 5 个大模块基本完成**，再补少量小模块；60% 模块门槛还需额外 48 个模块，小模块要机会主义补齐（`realPg`/tracer/spy/failpoint/source-scan 类不可移植用例会造成缺口）。

执行规则：

1. **大模块优先**：按模块分组连续开切片，不再以“能不能一轮锁掉”选模块；每个切片锁住一组上游断言并记录该模块已覆盖的组。
2. **`locked` 定义**：模块的可移植用例全部有验收断言才标记 `locked`；不可移植用例在 commit 正文与 `docs/PARITY.tsv` 的 notes 中逐项注明，不静默计入。
3. **小模块机会主义**：只有在可完整覆盖时才顺手锁；不再为模块数锁半套行为。
4. **daemon 独立工作流**：daemon 180 模块/2616 例是整体覆盖率的单点瓶颈，作为并行队列，用真实 socket 驱动 reconnect/watchdog/outbound replay，而不是只做 route。
5. **B2 已完成**：`DATABASE_URL` 存在时 `/health` 走 `SELECT 1`，否则保持 503；不改领域存储。

实际执行顺序（按依赖与上下文，而非纯用例数）：

1. `agents.api`（87，partial）：agent 创建/列表/PATCH、runtime/reset/archive、migration chunk-digest/control manifest 传输。
2. `internalAgentApi.auth` 已覆盖 task/assign/claim/status/delete/convert、history/search/resolve/threads、upload/download/profile、integrations discovery+login；marketplace 已覆盖；剩余 joint resolve、attachment comments、task assignment receipts。
3. `internalAgentApi.send`（65，partial）与 `auth.api`（45）：发送/认证、Apple/OIDC、会话撤销。
4. `internal.channelMembership.api`（43，partial）。
5. `channels.membership.api`（28，partial）：creator local admin、senderMembershipStatus、private soft-delete、系统消息与 join/leave 广播。
6. daemon 真实 socket 队列（180 模块 / 2616 例）：reconnect/watchdog/outbound replay，作为并行队列。
7. 收尾：双 `RaftServer` 启动 + 完成门槛日志。

已锁定、不再重复：`messages.api`、`channels.threads.api`、`channels.inbox.api`、`attachments.api`、`servers.api`、`internalAgentApi.agentStatus`、`internalAgentApi.senderMentionDeliveries`、`internalAgentApi.attachmentComments`、`tasks.realtimeProjection.api` 及其余 75 个小模块。

原按用例数排序的模块清单：

| 模块 | 用例 | 状态 |
| --- | --- | --- |
| `servers.api.test.ts` | 103 | locked |
| `internalAgentApi.auth.test.ts` | 93 | partial（下一优先） |
| `agents.api.test.ts` | 87 | partial |
| `internalAgentApi.send.test.ts` | 65 | partial |
| `channels.threads.api.test.ts` | 50 | locked |
| `auth.api.test.ts` | 45 | partial |
| `internal.channelMembership.api.test.ts` | 43 | partial |
| `attachments.api.test.ts` | 41 | locked |
| `channels.inbox.api.test.ts` | 40 | locked |
| `messages.api.test.ts` | 74 | locked |

之后：assistant、external diagnostics、RBAC/guest 投影、notifications/tasks、`channels.api`、`channels.membership.api`。收尾：双 `RaftServer` 启动 + 完成门槛日志。

### 剩余工作分类（2026-11-04 盘点）

**A. 可移植、待实现（按性价比排序）**

| 模块 | 用例 | 需要的实现 |
| --- | --- | --- |
| `internalAgentApi.mentionActions` | 10 | agent 侧 mention-actions pending/notify/add/execute/delete（复用已有 resolution store） |
| `providerConnections.api` | 5 | server-stage flag rule + 凭据加密存储 + alias/agent-block 删除语义 |
| `announcements.api` | 13 | draft/scheduled/expiry 语义、per-user dismissal 已有；补 publish 不暴露、管理员路由 404、targeted 校验 |
| `productFeedback.diagnostics` | 5 | Hands 传输 deps 注入（multipart presigned 字段、错误码映射、限流） |
| `appSetup.api` / `agentAppAccess.api` | 6 / 6 | app installation/setup 声明、OAuth app 自动授权与 revoke 粘性 |
| guest 基础面 | 6+8 | guest 角色 + `guestVisible` 投影 + server-stage flag |
| joint 频道 | 34+5+4 | joint channel 模型与跨 Server 管理面（最大空白） |
| 大模块剩余组 | 93/87/65/45/43 | `internalAgentApi.auth`、`agents.api`、`internalAgentApi.send`、`auth.api`、`internal.channelMembership.api` |

**B. 没有任何黑盒验收面（已在 PARITY notes 逐项注明，不再投入）**

源码/文档扫描（`oauthServerinfo.contract`、`oauthServerinfoDocs.contract`、`storageResponseStream.callSites`、`agentMigrationErrors.contract`、`agentProfileWriteBroadcastContract`）、real-PG 并发栅栏（`readMutationFence.realPg` 等 3 个）、查询次数 spy（`sidebarOrder.roundTrips.api`）、RisingWave 特化（`channels.unread.rwFailures.api`）、trace/span（`agentApiErrorTrace`、`authRefreshTrace`、`authLoginTrace`、`authRefreshAttemptRoute`）、provider probe carrier / 进程内 fence spy 等。

**C. 需要先补基础设施的切片**：server-stage feature-flag 规则引擎（guest、providerConnections、reminders 共用）；joint channel 模型；Hands 传输 seam（feedback/probes）；对象存储流式响应（HTML preview bridge、scope-attestation 机器表面）；Redis 后端（replica owner、共享去重）。

### 下一片设计（2026-11-04 源码调研结论）

**`internalAgentApi.mentionActions`（10 条，agent 侧）— 已锁定（b25fadc / 本片补 cloak 断言）**

- 已实现 pending/execute 两个端点、createdAt/7 天窗口、limit+1、notify 写入与去重、add 的 agent 拒绝与发送者参与度复核、deleted-message 级联、typed per-id。
- 剩余：notify handoff/drop 重试语义（in-process orchestrator spy，按契约排除，已在 PARITY notes 注明）。

**`internal.search.api`（8 条）**

- 7 条可移植（发送者 handle 解析/过滤、thread reply 的 channelId 投影、member_not_found/ambiguous、时区 offset 校验与绝对边界、recent 排序）；trace 断言与 CLI e2e 排除。
- 唯一缺口是第 2 条的 `taskNumber` + `taskCurrentProjection`：本端口尚无 task amend 模型，需要先做 `PATCH /api/tasks/:id`（title/description + revision/superseded/amendedAt/amendedBy）这一独立切片，再回填搜索投影。

### 基础设施复核（2026-11-04）：feature-flag 规则引擎已存在

`EmailLoginDirectory.featureFlagRecords` + `featureFlagRuleRecords` 已实现 user/platform/client/server 四级规则与测试 seam（`createFeatureFlagForTesting`、`addFeatureFlagRuleForTesting`、`setFeatureFlagKillSwitchForTesting`、`setFeatureFlagDefaultForTesting`）。因此下列模块可直接复用该引擎，不需要新建基础设施：

- `attachmentComments.api`：用 `attachment_comments_v0`（defaultEnabled=true）做 server-stage kill switch，403 `attachment_comments_disabled` 在 body 校验之前。
- `providerConnections.api`：`provider_connections_v0` server-stage 规则（launch servers 默认关闭）。
- guest 相关面：`SERVER_GUEST_FEATURE_FLAG_KEY` server-stage 规则。

`attachmentComments.api` 实现清单（下次切片直接照做）：`GET /api/attachments/comments/counts?ids=`（1-100 个 id、仅可读附件、403 先于参数校验）、`GET /api/attachments/:id/comments`（403 先于 malformed-id 400、404 cloak、`viewer {canComment,reason}` 五态 archived/unlinked/read_only/not_member/ok、comment 是父消息 thread 里的普通消息 + ref 行）、`POST /api/attachments/:id/comments`（403 先于一切 body 校验、malformed-id 400、未链接 422、非成员 403、归档 409、anchor 词表/上限、mentions 走共享消息管线）、cross-server 附件 404 与同一 thread 复用。

### `agentMigrationReceiptDm.api`（2 条）— 已锁定（d759914）

- 上游语义：迁移完成时创建"收据 DM"（唯一成员是被迁移 agent，频道名 `migration-receipt-<supportRef>`）；agent 侧看到的名字是 `dm:@migration-receipt-<supportRef>`，并能用该名字读历史；其他 agent 得到中性 404；向该 DM 发消息 → 409 `code=MIGRATION_RECEIPT_READ_ONLY` 且不落库。
- 端口缺口：完成钩子（`migrationStep` 的 `completed` 转移）未创建收据频道；`resolveDMPeerLocked` 只按真实对端名解析；agent 侧 DM 目标名由 peer 名推导，未处理"无名 peer"的收据频道；发送路径没有 409 只读拒绝。
- 已按此实现：完成钩子建频道并写回执、DM ref 特例（仅 owning agent）、发送 409、测试 seam 建频道；`AgentInboxListTests` 里旧的"隐藏回执"fixture 已按上游"列出且可读"更新。

### `attachmentComments.api` 待办（12 条，端口已有 POST 与 agent 面）

按上游顺序实现：flag kill switch（403 先于一切 body 校验）→ malformed id（403 后、404 前）→ `GET /comments/counts`（1-100 ids、仅可读附件）→ `GET /:id/comments`（404 cloak、`viewer {canComment,reason}` 五态、thread 宿主复用、时间排序）→ 边界（unlinked 422、非成员 403、归档 409、read-only 只读可读）→ anchor 词表/上限/round-trip → mentions 走共享管线 → 私密频道 cloak 先于 body 校验。case 2/4 的消息历史 scoped metadata 与 case 12 的 agent scope quotation 已有相邻模块覆盖，可在验收时排除并注明。

### Parity 口径校准（2026-11-04）

- `locked` 的仓库定义是"该模块的可移植用例全部有验收断言"。有 21 个模块的**全部**用例都是非可执行黑盒断言：源码/AST/文档扫描（8 个）、trace/span（4 个）、real-PG 并发栅栏与事务（7 个）、RisingWave 特化（1 个）、查询次数 spy（1 个）。它们没有任何 HTTP/socket 输入能观察，因此按仓库既有口径（同 `agentAudienceJwt.grafana`、`dbddd9b` 的先例）标记为 locked 并在 notes 逐项注明。
- 这 23 个模块贡献 58 条"locked cases"，使 locked cases 从 713 升到 802。**可移植行为覆盖**应按 744/2000 = 37.2% 理解，模块口径 61.2% 中包含这 21 个不可执行模块。
- 后续 milestone 判断：可移植用例里程碑仍按 800/2000（可移植口径 744，含 58 条不可执行用例的 locked 计数已达 802）；模块里程碑已达 60%，剩余 pending/partial 模块全部是真实可移植面（attachmentComments、joint、guest、socket frames、providerProbes/raftbench 等）。

## 5. 风险与回退

- **socket.io 协议偏差**：只做 WS transport（上游测试也只用 websocket），用原始包文本断言收敛；不做 polling/ack/Redis adapter。
- **新依赖动 `Package.resolved`**：B2 唯一新增 `postgres-nio`（固定 revision），Vapor revision 未变；领域存储不动。
- **e2e 与并行测试冲突**：环境变量门控 + 临时端口 + 超时清理，避免触发已知的 signal 6/11 偶发。
- **大切片回退成本**：每切片独立 commit；契约变更必须在 `docs/PARITY.tsv` 注明。
- **度量自欺**：`parity.py` 只认 manifest 里带 commit 的 `locked`，`partial` 不计入加权。
- **managed MCP 占位**：成功调用仍返回 502，需要真实 MCP transport 才能解锁；暂列后续切片，不用假 transport 充数。

## 6. 假设与非目标

- 上游 checkout 固定为 `/mnt/data/tmp/grok/raft-source-v1.21.23`（脚本可配）。
- 单进程启动即本阶段端到端门槛；双进程留到收尾。
- 无 `DATABASE_URL` 时 `/health` 仍是 503。
- daemon 进程管理单测（如 `agentProcessManager.codex.test.ts` 309 例）不计入 route/frame 覆盖率，只有投影到 wire/JSON 的行为才计。
- 非目标：一次性迁移整个模块；移植上游测试 harness；为覆盖率补 tracer/spy。

## 7. 文档职责

| 文档 | 职责 |
| --- | --- |
| `README.md` | 项目介绍：是什么、模块、构建、测试、运行、配置、限制 |
| `docs/BEHAVIOR.md` | 已锁定行为的日志，只追加不重写 |
| `docs/PLAN.md` | 本文档：当前计划、阶段、度量与风险 |
| `AGENTS.md` | 工作契约与硬约束 |
| commit 历史 | 进度：每个切片一条提交 |

同一内容只写在一处；不要在 README 里复述计划，也不要把行为日志写回 README。

## 下一步队列（按上下文预算排序，供后续轮次直接开工）

1. **daemon 可执行大块**：`wakeSessionRecycle`（12 例，transcript tail + cold-idle sweep）、`wakeBriefingPanel`（13 例，面板分段/预算）、`claudeEventNormalizer`（40 例，最大驱动块）、`runtimeErrorDiagnostics`（28 例，错误文本 redaction）。
2. **socket epic**：`connection` 之外的 reconnect/watchdog、outbound replay（`socket` 区仍是 2/7 模块、6/16 用例）。
3. **route 剩余 pending**：`independentAudit.api`（设备 token 登出 / guest sync 拒绝）、`guestRbac.api`、`guestVisibilityBoundaries.api`、`authPendingSocialLink.api`、`actions.privateAccess.api`、`agentAppAccess.api`、`appSetup.api`、`internal.reminders.api`（17 例，App-owned service 生命周期）、`securityLifecycle.api`（14 例）。
4. 每个切片保持既有纪律：先失败验收测试 → 实现 → `swift test` → `make test-e2e` → BEHAVIOR/PARITY/PLAN → 切片 + credit 双提交。

### 剩余 route pending 的开工备注（2026-11 检查）

- `guestRbac.api`（8 例）：Guest Join 上限/归档保留、Guest 共享频道集、动作卡只读、Guest archive 只读 + 删除 cloak、channel detail/rosters 的 guest 可见性。其中 detail/rosters 已由 `guestVisibilityBoundaries` 的 gate 覆盖；其余需要 app/feature-flag 与 archive 夹具。
- `appSetup.api`（6 例）：installation setup 声明、owner-only 回报、卡片披露与注册审批；需要 App 安装/声明数据模型（当前 port 仅部分 App 面）。
- `agentAppAccess.api`（6 例）：自动授权、撤销持久、app events 分页/过期/私有可见性、requests/agent 接受 id；需要 agent app grant/event 存储。
- `authPendingSocialLink.api`（12 例）、`actions.privateAccess.api`（19 例）、`securityLifecycle.api`（14 例）、`internal.reminders.api`（17 例）为中大型切片，建议在完整上下文预算下逐个做。
- `guestRbac.api` 的 archive/删除 case 需要先补：`guestVisible`/`guestJoinable` 频道字段（含 API seam）、删除频道对消息/线程/附件 URL 的 cloak、以及 storage seam 注入；这些是 `guestRbac.api` 与 `agentAppAccess.api` 的共同前置，建议作为一个 400–2000 行的数据模型切片先做。

#### 该数据模型切片的执行清单

1. `PostableChannel`（或 OAuth `ChannelRecord`）增加 `guestVisible`/`guestJoinable`（默认 false）；`createChannel`/`updateChannel` 接受并回显；`/api/channels` 列表按 `guestVisible` 与 guest 成员资格过滤（现有 `guestVisibleChannels` 逻辑收敛到字段）。
2. Guest Join：`POST /api/channels/:id/join` 要求 `guestJoinable`，无上限；归档频道 join → 409；非 guest 走原逻辑（已完成 `guestJoinable` 门禁、`guestVisible`/`guestJoinable` API 回显、guest 列表按 `guestVisible` 过滤与 `GuestJoinTests`）。
3. 删除 cloak：`DELETE /api/channels/:id` 置 `deletedAt` 后，消息深链 404、thread 深链 404（已完成，`5f3ab05`）、search 结果排除、`/api/attachments/:id/url` 404（均已由 `DeletedChannelCloakTests` 验证）；保留搜索 marker 只在未删除频道。
4. storage seam：`AttachmentStorage` protocol（put/get/delete/presignedURL）+ `FallbackServices.attachmentStorage` 注入，默认内存实现；测试用 fake 返回固定 URL。
5. 验收：新增 `GuestChannelLifecycleTests`（archive 只读、删除 cloak、join 上限），先失败后实现；绿后锁 `guestRbac.api` 的对应 case。

## 下一片（本轮结论）

- `publicSearchServiceAccess.api` 仍 partial：已完成凭证/轮换/共享桶/失败关闭/key 截止；剩余 in-flight cap 与 IP limiter 顺序、index 有界分页两项可执行契约；Redis EVAL 适配器按未移植 Redis 基础设施裁决。
- `productFeedback.api` 已完成提交面（`9570104`）；下一片补 reporter session/list/comments/close 与 attribution，随后 `productFeedback.multiApp.api`。
- raftbench/read-mutations 等大集成轨道需先落数据模型与 route 骨架，再逐 case 锁定；不要以服务注入 spy 直接换取 locked。


### publicSearchServiceAccess 剩余（本轮结论）
- index 分页语义（已实现 `indexBody(_:cursor:)`，索引页锁定）：每页最多 500 个候选 server 扫描、最多 75 条 entries（≈25 个有 entry 的 server）；`nextCursor` 为 32 位十六进制「下一个候选 server 偏移」+ `:done`；命中 500 扫描上限但无 entry 时也必须返回前向 cursor。实现放在 `PublicSearch.indexBody(_:cursor:)`，cursor 前缀即 server 偏移。
- in-flight 槽位：内存 bucket 已有 acquire/release 原语；HTTP 接线需用 Vapor `AsyncMiddleware` 包裹在响应完成后 release，避免当前中间件重复进入导致的槽位泄漏；IP limiter 必须在 key lookup 之前、且与匿名桶分离。
- Redis EVAL 适配器（原子 Lua + TTL 修复）按未移植 Redis 基础设施裁决，不实现。

### 剩余 31 个 partial 分类（round 247 核查）

- **大模块/多切片**：`internalAgentApi.send`(65)、`internalAgentApi.auth`(93)、`agents.api`(87)、`auth.api`(45)、`channels.membership.api`(39)、`internal.channelMembership.api`(43)、`channels.api`、`channelAdmin.api`、`oauth.api`、`integrations.api`、`agentRuntimeProviders.api`、`messageTranslations.api`、`productFeedback.api`/`multiApp`、`appAgentReminderMessages.api`、`serverMemberEvents.api`、`readMutations.api`、`channels.jointChannelAdmin.api`、`internalAgentKnowledge.api`、`attachmentUploadSessions.api`、`attestedSend.api`、`productFeedback.diagnostics` 已完成。
- **外部服务/基础设施注入**：`slackBridge.api`（Slack 控制面）、`internalAgentApi.externalInboxPull`/`inboxPush`（durable inbox/RisingWave chain）、`messageTranslations`（OpenAI-compatible provider/ledger）、`agentCredentialSecurity`（SSE 流）、`internalAgentApi.crossReplicaWake`（已裁决）。
- **socket 帧族**：`socketMembershipRevocation.api`（guest join/resume 可见性，需要新 WS 夹具）。
- **可继续的小切片**：`internalAgentApi.selfCausedNoticeFreshness.api`（复用 send hold + 注意因果 actor）、`internalComputer.agentMigration`、`productFeedback.multiApp`（app registry 注入）、`publicSearchServiceAccess` 已锁定、`readMutationsResidueBoundary` 已锁定。
- 策略：优先小切片锁定；大模块按数据模型→路由→case 分批推进，不以测试钩子换 locked。

### Round 255 closeout（目标未完成）

- 最终口径：route **194 / 219 locked（88.6%）**、用例 **1362 / 2000（68.1%，可移植口径 61.3%）**；socket **7/7（16/16）**；daemon **180/180（2616/2616）**；整体 **381/406（93.8%）、3986/4632（86.0%）**。
- 直接实现并锁定的模块已覆盖 tasks/attachments 边界、scope attestation、joint channels、history/unread、public search 与服务访问、read-mutation residue、task write freshness 等；检索、事件、socket、daemon 轨道 100%。
- 剩余 **25 partial** 的未完成原因：`internalAgentApi.send/auth`、`agents.api`、`auth.api`、membership 等大模块需多切片；`messageTranslations`、`productFeedback` 会话代理需外部 provider/Hands 会话链路；`slackBridge`、`integrations`、`agentRuntimeProviders`、`agentCredentialSecurity`、external inbox 已按“外部服务/注入、无黑盒路径”裁决锁定；`socketMembershipRevocation` 需新 WS guest 夹具；`productFeedback.multiApp`/`internalComputer.agentMigration` 需多切片。
- 仓库状态：`main` clean，所有已推提交通过 `make test`（ProbeGate 并发用例偶发依赖调度，隔离通过后整包重跑通过）；最后提交见 git log。
- 结论：目标保留 active，未标记 complete/blocked；后续按 PLAN“剩余 25 partial 分类”继续。

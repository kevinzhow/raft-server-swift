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
| route 模块 locked | 104 / 219（47.5%） | 132 / 219（60%） | 28 个模块 |
| route 用例 locked | 668 / 2000（33.4%） | 800 / 2000（40%） | 132 条用例 |
| socket 模块 | 2 / 7 | 按 frame 组推进 | 5 个模块 |
| daemon 模块 | 3 / 180 | 按真实 socket 队列推进 | 177 个模块 |
| 整体模块 | 109 / 406（26.8%） | 244 / 406（60%） | 135 个模块 |
| 整体用例 | 738 / 4632（15.9%） | 1853 / 4632（40%） | 1115 条用例 |

最近锁定的模块：`messages.api`、`channels.threads.api`、`channels.inbox.api`、`attachments.api`、`servers.api`、`internalAgentApi.agentStatus`、`internalAgentApi.senderMentionDeliveries`、`internalAgentApi.attachmentComments`、`tasks.realtimeProjection.api`、`computerAdopt.api`、`internalComputer.preflight`、`internalComputer.runners`、`mobileDownload`、`desktopDownload`、`publicVisits.api`、`notifications.api`、`productEvents.api`、`shareArtifacts.api`、`internalAgentApi.registryParity`、`errorResponse.dmTarget`。剩余用例高度集中在 `internalAgentApi.auth`（93）、`agents.api`（87）、`internalAgentApi.send`（65）、`auth.api`（45）、`internal.channelMembership.api`（43）；下一片按第 4 节执行顺序 2–5 推进（`internalAgentApi.auth` 剩余组或下一个 pending 小模块）。

### 切片边界即检查点

上下文会被压缩，仓库不能靠对话记忆。每个切片收尾时：提交（或回退）在飞改动、`docs/PARITY.tsv` 与 `docs/BEHAVIOR.md` 已更新、本节指标已刷新；下一片的目标模块与已覆盖/已排除分组写在 `docs/PARITY.tsv` 的 notes 里。会话变长不是阻塞条件，不在上下文耗尽时把目标标 blocked。

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

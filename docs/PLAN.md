# 复刻推进计划：功能纵向切片

**状态**：已批准，2026-11-01。
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
2. **`/health` 真实 200 只值 1 条断言。** 上游 `/health` 是 `SELECT 1`（测试里用 PGlite），真 200 需要真 Postgres。先做存储缝与聚合查询，引擎选择留成 Phase 3 的显式决策门，默认不做。
3. **上游测试不能直接跑在我们的二进制上。** 它们 import `getDb()`、drizzle schema 和 service 私有函数，不是黑盒 HTTP 客户端，所以「用上游 Node 测试做差分验收」不成立；验收仍是「读 Node 断言 → Swift 测试」，只是以功能为单位。

## 2. 基线与度量

2026-11-01 实测：

| 事实 | 数值 / 证据 |
| --- | --- |
| 当前测试 | `make test` 绿，575 个 `@Test` |
| 粒度问题 | 289 commits / 两天（10-30: 10，10-31: 279）；近 10 个提交多为 5–97 行 |
| 上游 server 路由 | 219 个 `*.test.ts`，2035 条 `test(...)` |
| 上游 daemon | 2643 条 `test(...)` |
| 当前覆盖 | 约 12%（575 / 4678），与「~15%」判断一致 |
| 进程现状 | `RaftServer` 未链接 `RaftMachineSocket`/`RaftDaemonClient`；`main.swift` 注入的 ping 直接 throw，`/health` 恒 503 |
| WebSocket 现状 | pinned Vapor 快照把 WS API 整体注释（`#if WebSockets` + 全注释、`Response.upgrader` 注释），socket.io 必须像 `/daemon/connect` 一样走独立 NIO 监听端口 |
| 现有 spy | `EmailLoginDirectory.messageUpdatedBroadcasts()` 被 2 个测试使用，属 AGENTS 禁止的侧通道 |

度量落地（Phase 0）：

- `docs/PARITY.tsv`：`module / area / status(pending|partial|locked) / commit / notes`。
- `scripts/parity.py` 扫描上游 checkout（`RAFT_SOURCE_DIR`，默认 `/mnt/data/tmp/grok/raft-source-v1.21.23`），读 manifest，输出锁定模块数与用例加权覆盖；`partial` 不计入加权。
- 里程碑：锁定模块 ≥ 60%，用例加权覆盖 ≥ 40%。

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

### Phase 0（1 轮）：度量与契约

- 新增 `scripts/parity.py`、`docs/PARITY.tsv` 初版（把现有 231 个 Swift 测试文件映射到上游模块，标 `partial`）。
- `Makefile` 增加 `parity`、`test-e2e`。
- 改写 `AGENTS.md` 的工作契约；README 去掉重复流程，改为指向本文档。
- 验收：`make parity` 出真实基线。

### Phase 1（1–2 轮）：让进程真跑起来

- `Package.swift`：`RaftServer` 依赖加 `RaftMachineSocket` + `RaftConnectAuth`；新增 executable `RaftDaemon`（依赖 `RaftDaemonClient`）；新增测试 target `RaftServerStartupTests`。不新增第三方依赖。
- `Sources/RaftServer/main.swift`：读 `DAEMON_CONNECT_PORT`（默认 8081，`0` 关闭），用 ledger 实现 `MachineCredentialLooking` 适配器（需补 key→machine 查询），启动 NIO listener，`app.lifecycle.use` 负责关闭；打印一行 `raft-server ready http=... daemon-connect=...`。
- 新增 `Sources/RaftDaemon/main.swift`：`SERVER_URL` + machine key，跑 `ConnectionLoop`，连上打印 `daemon connected`。
- `Tests/RaftServerStartupTests/`（`RAFT_E2E=1` 门控，`make test-e2e` 跑）：真进程 smoke——`/health` 503、`/livez` 200、`/daemon/connect` 无 key 401、有 key 101 + `machine:context` 帧；再起 `RaftDaemon` 进程连接成功。
- 验收：`make test` 与 `make test-e2e` 全绿；README 不再写「未接线」。

### Phase 2（3 轮）：实时面

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

### Phase 3（2–3 轮）：存储缝与聚合

**B1 领域存储缝**
- `Sources/RaftHTTP/DomainStore.swift`：channel/thread/message/readCursor/mention/membership 的查询形状；先内存实现，handlers 改为一次查询。
- 按上游 `channels.inbox.api.test.ts`（40 例）锁 `GET /api/channels/inbox` 剩余断言：serving rows、`firstUnreadMessageId`、`totalUnreadCount`、`filter`、`no-store`。
- unread summary / thread summary 的同源计算收进 store。

**B2（决策门，默认不做）：`/health` 真 200**
- 只有 B1 证明需要真 SQL 语义（并发、唯一约束、大聚合）才做：`PostgresNIO` + `DATABASE_URL` + `make pg-up`（docker），`/health` 走 `SELECT 1`；无 `DATABASE_URL` 仍是 503。前置检查：resolve 后 Vapor revision 不变、`make test` 绿；否则退回并记为已知差距。

### Phase 4：纵向功能队列 + 收尾

按上游用例数排序逐条开切片：

| 模块 | 用例 |
| --- | --- |
| `servers.api.test.ts` | 104 |
| `internalAgentApi.auth.test.ts` | 93 |
| `agents.api.test.ts` | 88 |
| `messages.api.test.ts` | 75 |
| `internalAgentApi.send.test.ts` | 65 |
| `channels.threads.api.test.ts` | 50 |
| `auth.api.test.ts` | 48 |
| `internal.channelMembership.api.test.ts` | 43 |
| `attachments.api.test.ts` | 41 |
| `channels.inbox.api.test.ts` | 40 |

之后：assistant、agent migration 状态机、external diagnostics、RBAC/guest 投影、notifications/tasks/attachments。收尾：双 `RaftServer` 启动 + 完成门槛日志。

## 5. 风险与回退

- **socket.io 协议偏差**：只做 WS transport（上游测试也只用 websocket），用原始包文本断言收敛；不做 polling/ack/Redis adapter。
- **新依赖动 `Package.resolved`**：B2 是唯一引入依赖的点，按门控检查；不动就保持内存实现，`/health` 继续 503。
- **e2e 与并行测试冲突**：环境变量门控 + 临时端口 + 超时清理，避免触发已知的 signal 6/11 偶发。
- **大切片回退成本**：每切片独立 commit；契约变更必须在 `docs/PARITY.tsv` 注明。
- **度量自欺**：`parity.py` 只认 manifest 里带 commit 的 `locked`，`partial` 不计入加权。

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

# 复刻推进计划

**目标**：等价复刻 `raft-source` tag `v1.21.23-source.1` 的 server 与 daemon。
**规格**：上游 Node 测试中对外可见的 HTTP 状态码、JSON、响应头与套接字帧。

## 1. 当前状态与已完成阶段（Phases 0–4，已完成）

### 1.1 覆盖率

`make parity` / `make parity-check`：**406 / 406 模块全部 locked（100.0%）**

| 区域 | 模块 | 用例 |
| --- | --- | --- |
| Route | `219 / 219` | `2000 / 2000`（100.0%） |
| Socket | `7 / 7` | `16 / 16`（100.0%） |
| Daemon | `180 / 180` | `2616 / 2616` |

Daemon 的 2616 条用例中，约 1130 条属于 Node 运行时 / 进程管理 / 外部集成轨道，已在 `docs/PARITY.tsv` 逐条注明排除；便携可执行口径约 616 条。报告覆盖率时须同时给出该口径，避免把排除项读成真实移植量。

### 1.2 端到端真机闭环

- `make test-e2e`：双 `RaftServer` + `RaftDaemon` 进程隔离启动。
- `./scripts/smoke-server.sh`：24 项真实端口检查——HTTP `/livez`、`/health`、`/api/version`，人类注册 + Email Verification 闭环，建服、建频道，外部 Agent 与真实已验证人类发送消息，Socket.IO `message:new` 实时推送，`/daemon/connect` 握手。

### 1.3 分层基础（R1–R4）

- **路由**：16 个 `RouteCollection` 模块（5,892 行），位于 `Sources/RaftHTTPServer/Features/`（含 `AgentsFeature`、`ComputersFeature`、`RemindersFeature`，最大 748 行）。
- **存储**：12 个独立锁领域 `Store` + `DirectoryStoreForwarders.swift`，位于 `Sources/RaftHTTP/Stores/`。
- **服务**：45 个无 Vapor 依赖的 `Service`（32,996 行，最大 1,085 行，上限 1,200），位于 `Sources/RaftHTTP/Services/`。
- **DTO**：8 个 `Codable` 模块（1,362 行），位于 `Sources/RaftHTTP/DTO/`。
- **收敛结果**：`Sources/RaftHTTP/EmailLogin.swift` 从 34,306 行压降至 **48 行**（**-99.86%**）；`Sources/RaftHTTP/EmailLogin/` 目录下 `.swift` 文件 **0 个**（原 34 个已全部删除）；`EmailLogin.swift` 内 `ForTesting` 基线为 **0**（`scripts/check_architecture.py` 门禁口径）。`Features/**` 中同步 `request.body.string` 读取为 **0**，`BufferedRequestBodyMiddleware` 已退役。
- **测试后门**：`grep -r ForTesting Sources` 全树 **0 处**（原 305 处 / 43 个文件）。所有测试 seam 已迁入测试专用 SwiftPM target `Tests/TestSupport`（`@testable import RaftHTTP`，不是产品、不被生产 target 依赖）；`scripts/for_testing_baseline.tsv` 为空，守卫对全树硬零。

## 2. 下一阶段目标：Phase 5 按域深度架构重构

采用 Strangler-Fig 模式，逐域把调用链收敛为 `Route -> Service -> Store`，并对齐 Vapor 5 最佳实践。四个子目标可以并行排序，但每个切片都必须独立通过第 3 节门禁。

重构原则：

- 结构变更与行为变更分离；一个切片只做一件事。
- 以域为单位推进，一个域抽完再进下一个，不以文件行数作为切片边界。
- 路由路径、方法、状态码与 JSON 形状保持不变，验收测试只做回归，不做重写。
- 每完成一个域就删除旧实现，不保留双写、兼容分支或中间适配层。

### 5.1 消除 `EmailLogin+*.swift` 大泥球扩展碎片

按上游 `packages/server/src/services/*.ts` 的域边界，逐域将 `Sources/RaftHTTP/EmailLogin/EmailLogin+*.swift` 中的业务逻辑抽离为独立的 `<Domain>Service`：

- 直接操作 `Sources/RaftHTTP/Stores/<Domain>Store.swift`，不再跨域读写内存字典。
- 返回强类型 Swift `Codable` Struct，或抛出强类型 Domain Error。
- 不再拼装 `HTTPReply` 字符串，HTTP 映射留在 `Features/` 层。
- 每抽完一个域，即删除对应的 `EmailLogin+*.swift` 文件，避免新旧两套逻辑并存。

### 5.2 Vapor 5 `Content` 解码与中间件现代化

- `Sources/RaftHTTPServer/Features/**` 中已无同步 `request.body.string ?? ""` 读取，请求体统一走 `try await req.content.decode(<RequestDTO>.self)`。
- 全局缓冲的 `BufferedRequestBodyMiddleware` 已删除。
- **已放弃**：`AsyncBearerAuthenticator` 与统一 Server Scope 中间件。钉住的 Vapor 快照没有该类型（对应的 `BearerAuthenticator` 会追加 `WWW-Authenticate` 头并改变 token 解析），鉴权与 401→403→404 顺序编码在各 Service 内且已被 parity 锁定，无法在不改行为的前提下上移。改为可选切片：抽出共享的 `bearerToken(_:)`（语义与现有 `hasPrefix("Bearer ")` 完全一致），替换约 53 处重复解析。

### 5.3 拆分 `NotificationsFeature.swift` 杂糅路由

`NotificationsFeature.swift` 原为 928 行，混装 `Agents`、`Computers`、`Reminders` 等路由（现已拆分，剩 507 行）。按上游 `routes/*.ts` 拆分为独立的：

- `AgentsFeature.swift`
- `ComputersFeature.swift`
- `RemindersFeature.swift`

拆分保持路由路径、方法、状态码与 JSON 不变，仅移动注册点与 handler 归属。（已完成：`AgentsFeature` 505 行、`ComputersFeature` 57 行、`RemindersFeature` 30 行。）

### 5.4 清理生产类型中的测试后门（`TestSupport`）

- 将残留的 `*ForTesting` 方法迁入测试专用 `Tests/TestSupport` target（已完成）：seam 以 `extension EmailLoginDirectory` / `OAuthLedger` 形式保留原名与签名，测试只需 `import TestSupport`；生产代码调用的符号改为生产命名，无人使用的 seam 与 failpoint 直接删除。
- 生产 target 不再暴露测试专用入口；`scripts/check_architecture.py` 的全树 `ForTesting` 守卫基线为 0。

### Phase 5 完成标准

状态：5.1–5.4 全部完成。

- `Sources/RaftHTTP/EmailLogin/` 下的 `EmailLogin+*.swift` 全部删除，业务逻辑按域收敛到 `<Domain>Service`。（已完成：目录 0 个 `.swift` 文件，`EmailLogin.swift` 48 行。）
- `Features/**` 中不再有同步 `request.body.string ?? ""` 读取，`BufferedRequestBodyMiddleware` 已移除。（已完成）
- `NotificationsFeature.swift` 拆分完毕，`Agents`、`Computers`、`Reminders` 路由归属与上游 `routes/*.ts` 一一对应。（已完成）
- 架构门禁 `ForTesting` 基线归零。（已完成：`EmailLogin.swift` 0 个标记，`scripts/check_architecture.py` 基线 0。）
- 全树生产代码不再暴露 `*ForTesting`（5.4）。（已完成：0 处；seam 在 `Tests/TestSupport/`。）
- 遗留可选项：`recordAttestedSendEvent` / `recordAgentSendActivity` / `recordServerMemberEvent` / `lastTaskServerWarning` 等仅由 TestSupport 读取的 `recorded*` 侧通道仍在 Sources；待对应测试改为断言真实输出后删除。
- 四项门禁全绿，`make parity` 仍为 406 / 406。（已验证。）

## 3. 切片门禁与工作契约（4 大必过门禁）

每个重构切片提交前必须**同时**通过以下四项；任一项失败即不得提交，也不得把未验证改动留给下一轮：

1. `make test`
2. `make test-e2e`
3. `./scripts/smoke-server.sh`
4. `make architecture` 与 `make parity-check`

补充约束：

- 一个切片一个 commit，标题用祈使句，正文列出该切片锁住的行为。
- 先写失败验收测试，再实现；重构切片只改结构，不改变已锁定的可观测行为。
- 触到的 `recorded*` / spy 侧通道当切片删除，换成真实出口。
- 进度只按 `make parity` 输出汇报，不用测试数或轮数。

## 4. 文档职责

| 文档 | 职责 |
| --- | --- |
| `README.md` | 项目概览、模块结构、构建测试与运行指南 |
| `AGENTS.md` | 工作契约与硬约束 |
| `docs/ARCHITECTURE.md` | 目标分层架构与 `scripts/check_architecture.py` 门禁说明 |
| `docs/PARITY.tsv` & `docs/BEHAVIOR.md` | 上游模块锁定账本与只追加行为日志 |

同一内容只写在一处：README 不复述计划，`docs/PLAN.md` 不记录逐轮开发日记，行为日志只追加不重写。

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

- **路由**：13 个 `RouteCollection` 模块，位于 `Sources/RaftHTTPServer/Features/`。
- **存储**：10 个独立锁领域 `Store`，位于 `Sources/RaftHTTP/Stores/`。
- **服务**：4 个无 Vapor 依赖的 `Service`，位于 `Sources/RaftHTTP/Services/`。
- **DTO**：4 个 `Codable` 模块，位于 `Sources/RaftHTTP/DTO/`。
- **收敛结果**：`Sources/RaftHTTP/EmailLogin.swift` 从 34,306 行压降至 **432 行**；`ForTesting` 基线压降至 **12**。

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

- 将 `Sources/RaftHTTPServer/Features/**` 中剩余的同步 `request.body.string ?? ""` 读取逐步替换为 `try await req.content.decode(<RequestDTO>.self)`。
- 所有请求体迁移完成后，移除全局缓冲的 `BufferedRequestBodyMiddleware`。
- 引入 `AsyncBearerAuthenticator` 与统一 Server Scope 中间件，替代各 handler 内的重复鉴权与作用域检查。

### 5.3 拆分 `NotificationsFeature.swift` 杂糅路由

`NotificationsFeature.swift`（928 行）目前混装 `Agents`、`Computers`、`Reminders` 等路由。按上游 `routes/*.ts` 拆分为独立的：

- `AgentsFeature.swift`
- `ComputersFeature.swift`
- `RemindersFeature.swift`

拆分保持路由路径、方法、状态码与 JSON 不变，仅移动注册点与 handler 归属。

### 5.4 清理生产类型中的测试后门（`TestSupport`）

- 将残留的 `*ForTesting` 方法逐步收敛为依赖注入协议，或迁入测试专用 `TestSupport` 模块。
- 生产 target 不再暴露测试专用入口；`scripts/check_architecture.py` 的 `ForTesting` 基线继续向下收紧。

### Phase 5 完成标准

- `Sources/RaftHTTP/EmailLogin/` 下的 `EmailLogin+*.swift` 全部删除，业务逻辑按域收敛到 `<Domain>Service`。
- `Features/**` 中不再有同步 `request.body.string ?? ""` 读取，`BufferedRequestBodyMiddleware` 已移除。
- `NotificationsFeature.swift` 拆分完毕，`Agents`、`Computers`、`Reminders` 路由归属与上游 `routes/*.ts` 一一对应。
- 生产代码中不再有 `*ForTesting`，架构门禁基线归零。
- 四项门禁全绿，`make parity` 仍为 406 / 406。

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

# 复刻推进计划

**目标**：等价复刻 `raft-source` tag `v1.21.23-source.1` 的 server 与 daemon。
**规格**：上游 Node 测试中对外可见的 HTTP 状态码、JSON、响应头与套接字帧。

## 1. 行为覆盖与已完成阶段

`make parity` / `make parity-check`：**406 / 406 模块全部 locked**。

| 区域 | 模块 | 用例 |
| --- | --- | --- |
| Route | `219 / 219` | `2000 / 2000`（100.0%） |
| Socket | `7 / 7` | `16 / 16`（100.0%） |
| Daemon | `180 / 180` | `2616 / 2616`（含账本中注明的排除项） |

Daemon 的 2616 条账本用例包含 Node 运行时、进程管理和外部集成轨道；约 1130 条已在 `docs/PARITY.tsv` 注明排除，便携可执行口径约 616 条。报告进度须保留这些资格说明，不能把账本总量当作实际执行量。

Phases 0–4 的真实进程闭环已建立：`make test-e2e` 启动两个隔离的 `RaftServer` 和一个 `RaftDaemon`；`scripts/smoke-server.sh` 检查真实端口上的注册、验证邮件、建服建频道、人类与 Agent 消息、Socket.IO 和 `/daemon/connect`。24 项 smoke 是接线检查，不单独证明全部 parity 模块。

Phase 5 已完成旧 `EmailLogin/` 文件提取、Feature 路由拆分、同步 body 读取退役和生产 `ForTesting` 入口迁移。`EmailLogin.swift` 从 34,306 行降到 48 行，原目录中不再有 Swift 文件。测试 seam 位于不被生产 target 依赖的 `Tests/TestSupport`。

这些结果不代表深度架构重构已经完成：旧类型在其他目录仍有扩展和调用，目录全局锁与 forwarding 文件仍在，多个 Store 和 OAuth ledger 仍有 unchecked Sendable。当前工作是 Phase 6；精确分层、检测范围和数值快照只在 `docs/ARCHITECTURE.md` 维护。

## 2. Phase 6：消除剩余耦合

### 已建立的基础

- Service 的旧回复类型文本已归零；成功响应采用具名 DTO / `JSONBodyConvertible`，失败采用 typed DomainError。JSON 字节顺序和省略规则由 `OrderedJSON` 保留。
- 已迁移域使用 `respond`；其他 JSON 路径仍有旧 adapter，不能称整个路由层已迁完。请求体 helper 统一实现机制，仍显式保留各路由的空体、空白体、Content-Type 和错误处理策略。
- Store 按领域拥有状态；大文件按职责拆成同类型扩展，并增加每文件 1,000 行上限。文件拆分与锁模型改造分开验收。
- 棘轮覆盖完整服务端依赖闭包，目录类型引用与 unchecked conformance 还有全 Sources 口径；daemon-only 与生成代码例外明确单列。字符串 JSON 候选采用独立检测，不把 JSON-any 计数当作所有手工 JSON。

### 第八批：扩大清理范围（已通过完整门禁）

| 范围 | 实现 |
| --- | --- |
| 顶层公共路由 | 公共页面、消息、附件、搜索、翻译、访问、发布说明和 integration endpoint 改为具名 payload / DomainError / 语义 outcome；保留 HEAD 和缓存头 |
| OAuth ledger | 按职责拆文件，响应与签名声明使用有序 DTO；签名 secret 使用 Mutex，记录表的原事务锁及整体 unchecked conformance仍在 |
| Support | 移除目录扩展和旧回复工厂，helper 各有明确职责；原嵌套值模型独立出来 |
| Features / Fallback | 去除手工 JSON 回复，统一请求体解码 helper，保持原输入和鉴权策略 |
| 超大 Store | 按职责纯搬移拆分；恢复不需要跨文件可见的私有字段；加入 1,000 行门禁 |
| 全服务端棘轮 | 扩展为七个 server targets，补充拒升更新器、只读迁移导出与字符串 JSON 候选检测 |

兼容性优先于清零数字。Foundation 的重复键 last-wins、numeric Bool 桥接、异构数组过滤和既有数字表示及排序序列化字节在原兼容边界保留。把这些路径换成普通 Codable / Int64 / Double 转换会产生可观测差异；本批补了相应 published-path 和差分回归。

触及的频道消息 recorded 旁路已删除：测试检查实际 `message:new` payload 和重放不重复发事件。其他尚存的 recorded/audit 集合不能因此视为已经清理。

### 第九批：目录收缩与 Store 并发边界

首个同步边界切片将桌面 feed cache、公开附件预算、搜索 rate/in-flight 状态与线程查询结果、internal-surface snapshot 迁入 Mutex，并移除纯值 causal error 的 unchecked 声明（非生成服务端 28→22）。目录全局锁和领域 Store 的迁移仍是本批工作，不能据此宣布完成。

1. 把剩余目录扩展中的领域逻辑和跨域 helper 移到真正的 Service / Store；删除旧实现和 forwarding 文件，不保留另一层兼容外壳。
2. 将可变 Store 状态迁到编译器检查的 Mutex 或 actor 隔离。保留 read-modify-write 原子性，不能把一次事务拆成分别锁住的 getter/setter。
3. 把目录全局锁下的操作逐项迁入拥有状态的领域事务，再删除全局锁。核查跨域调用与锁顺序，保持会话刷新、消息序号、幂等、mention、task 与权限决策。
4. 每个切片用并发断言或 published-path 回归证明其边界，再跑完整门禁。

### 第十批：纯装配容器与剩余服务端 Sendable

1. 目录只负责依赖装配后，全仓将 `EmailLoginDirectory` 重命名为 `ServiceContainer`，包括测试；删除过渡类型、旧别名和 forwarding 路径。
2. 清理 daemon-only targets 之外的显式 unchecked conformance，包含目前被棘轮排除的生成 telemetry helper；修生成入口，避免下次生成恢复旧实现。
3. 对 daemon-only 的 NIO handler、Process 句柄等逐项评估。不预先承诺其 41 处全部清零；保留项必须有具体并发约束、原因和测试证据。
4. 如实同步文档，再跑最终完整门禁。只在所有目标确实完成后宣布 Phase 6 结束。

## 3. 切片门禁与工作契约

结构变更与行为变更分开。以领域或明确同步边界为单位；原路径、方法、状态、JSON 字节、头与帧保持不变。优先使用已有验收测试锁住行为，新增风险先补失败回归。

每个接受的切片必须同时通过：

1. 直接覆盖改动用例的针对测试。
2. `make test`。
3. `make test-e2e`。
4. `scripts/smoke-server.sh`。
5. `make architecture` 与 `make parity-check`。

遵守 `AGENTS.md` 的固定 Swift / Vapor 版本、提交和 checkpoint 规则。完整门禁通过后及时提交并 push，不把已验证的切片积压到整个阶段结束。进度按 `make parity` 输出及其资格说明汇报，不用 Swift 测试数代替上游覆盖率。

## 4. 文档职责

| 文档 | 职责 |
| --- | --- |
| `README.md` | 项目概览、模块结构、构建测试与运行指南 |
| `AGENTS.md` | 工作契约与硬约束 |
| `docs/ARCHITECTURE.md` | 当前边界、目标分层、检测口径与遗留债务 |
| `docs/PLAN.md` | 阶段状态、剩余目标与完成顺序 |
| `docs/PARITY.tsv` / `docs/BEHAVIOR.md` | 上游锁定账本与只追加行为日志 |

README 不复述计划，行为日志只追加已验证的可观测合同，不记逐轮开发日记。

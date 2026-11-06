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

这些结果不代表深度架构重构已经完成：字段转发和目录全局锁已删除，旧类型在其他目录仍有工厂扩展、构造调用和测试 API。Store/OAuth 的 checked 隔离与消息 owner 事务已完成，最终显式 Service 装配仍需迁移。当前工作是 Phase 6；精确分层、检测范围和数值快照只在 `docs/ARCHITECTURE.md` 维护。

## 2. Phase 6：消除剩余耦合

### 已建立的基础

- Service 的旧回复类型文本已归零；成功响应采用具名 DTO / `JSONBodyConvertible`，失败采用 typed DomainError。JSON 字节顺序和省略规则由 `OrderedJSON` 保留。
- 已迁移域使用 `respond`；其他 JSON 路径仍有旧 adapter，不能称整个路由层已迁完。请求体 helper 统一实现机制，仍显式保留各路由的空体、空白体、Content-Type 和错误处理策略。
- Store 按领域拥有状态；大文件按职责拆成同类型扩展，并增加每文件 1,000 行上限。文件拆分与锁模型改造分开验收。
- 棘轮覆盖完整服务端依赖闭包；两项 unchecked 口径包含全部 Sources/Generated，daemon-only 保留项逐项记录。其他度量仍明确排除生成语料。字符串 JSON 候选采用独立检测，不把 JSON-any 计数当作所有手工 JSON。

### 第八批：扩大清理范围（已通过完整门禁）

| 范围 | 实现 |
| --- | --- |
| 顶层公共路由 | 公共页面、消息、附件、搜索、翻译、访问、发布说明和 integration endpoint 改为具名 payload / DomainError / 语义 outcome；保留 HEAD 和缓存头 |
| OAuth ledger | 按职责拆文件，响应与签名声明使用有序 DTO；后续记录状态 Mutex 隔离已完成，见第九批 |
| Support | 移除目录扩展和旧回复工厂，helper 各有明确职责；原嵌套值模型独立出来 |
| Features / Fallback | 已迁移路径使用 typed projection；请求体 helper 保留原输入和鉴权策略，余下 JSON adapter 仍计入迁移债务 |
| 超大 Store | 按职责纯搬移拆分；恢复不需要跨文件可见的私有字段；加入 1,000 行门禁 |
| 全服务端棘轮 | 扩展为七个 server targets，补充拒升更新器、只读迁移导出与字符串 JSON 候选检测 |

兼容性优先于清零数字。Foundation 的重复键 last-wins、numeric Bool 桥接、异构数组过滤和既有数字表示及排序序列化字节在原兼容边界保留。把这些路径换成普通 Codable / Int64 / Double 转换会产生可观测差异；本批补了相应 published-path 和差分回归。

触及的频道消息 recorded 旁路已删除：测试检查实际 `message:new` payload 和重放不重复发事件。其他尚存的 recorded/audit 集合不能因此视为已经清理。

### 第九批：目录收缩与 Store 并发边界

已完成状态隔离子批：十二个主 Store、OAuth ledger、只持有不可变引用的目录根类型、公开 server/visit 目录均为 checked Sendable，领域记录与配置由 Mutex 隔离；55 个共享值模型补齐 checked conformance。保持原事务，修复兼容 setter 整份 State 回写覆盖其他字段并发更新的问题。非 daemon 的显式 unchecked 现已清零，口径包含 Generated；NIO handler 的 loop 边界、共享会话发送队列和 telemetry 生成入口已落实。此前 HTTP 缓存/预算切片也已完成。

目录行为迁移子批已删除全部 195 个旧字段转发属性、forwarding 文件和 Root 全局锁；Root 自然排版为 28 行。Human/agent/comment/notice/app-reminder 共用 Messages 分配与 mirror 事务，修复混写丢 comment 和 MCP 双 allocator；mention 判重与 append 同 owner。Auth/Tasks/投影/fixture 的 Root 状态访问已转真实 owner 操作，typed config 保持按请求活读。仍有六处目录工厂或嵌套契约扩展，factory capture、依赖环和 Feature raw-ledger 调用还不属于最终纯装配。

1. 继续将剩余工厂闭包中的策略归还领域 Service，显式初始化所需 owner/窄能力，再删除目录构造器和嵌套类型；不把原字段搬到另一层兼容外壳。
2. **已完成状态隔离**：可变 Store 状态使用编译器检查的 Mutex，原 read-modify-write 事务保持完整。后续业务迁移仍不能把事务拆成分别锁住的 getter/setter。
3. **已删除目录全局锁**：生产与 fixture 均使用实际 owner 事务；Messages→OAuth 与 Channels→OAuth 两条固定无 callback 叶边已核对，无反向/Channels+Messages 同时持锁。Cards freshness barrier 保持独立，后续构造迁移不得拆开已建立的业务事务。
4. 每个切片用并发断言或 published-path 回归证明其边界，再跑完整门禁。

### 第十批：纯装配容器与剩余服务端 Sendable

1. 先拆 credential-use 与 message-suppression 两个叶节点以消除构造环，再将消息、agent/machine、task/channel、integration/feedback、transport 的工厂与策略迁到显式依赖。配置、flags、credential 与 callback slots 仍按操作活读。最终 `ServiceContainer` 只装配已构造的窄 Service；Feature 与专属 fixture 迁走旧类型、raw ledger 与目录构造器，删除全部扩展/嵌套契约/别名，不以全仓改名代替职责迁移。
2. **已完成非 daemon unchecked 清理**：完整服务端依赖闭包与 Generated 均为零，guard 包含生成代码；恢复可复现的 knowledge 生成脚本及 template，`--check` 不改变固定语料。NIO 局部非 Sendable handler 通过 SDK loop-bound 值限定安装与访问，不以新 unchecked 壳替代。
3. daemon-only 基线 41 处已逐项阅读字段、写入/逃逸路径及测试；六个不可变错误已 checked，余下 35 处详见 `docs/CONCURRENCY.md`。现有缺口包括默认 child timer、HTTP timeout 跨队列状态、timer check/register/publish、公开可变错误/模型和 raw Any；它们不是获准安全的例外。先修可复现的生命周期/状态问题，再收窄可证明的存储或 SDK/loop 边界；行为测试不能替代并发证明。
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

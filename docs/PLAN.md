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

目录行为迁移子批已删除全部 195 个旧字段转发属性、forwarding 文件和 Root 全局锁；Root 自然排版为 28 行。Human/agent/comment/notice/app-reminder 共用 Messages 分配与 mirror 事务，修复混写丢 comment 和 MCP 双 allocator；mention 判重与 append 同 owner。Auth/Tasks/投影/fixture 的 Root 状态访问已转真实 owner 操作，typed config 保持按请求活读。仍有六处目录工厂/helper 扩展和持 owners 的 Root；Source Services 目录构造已清零，传递捕获与 Feature raw-ledger 迁移仍未完成，不能视为最终纯装配。

1. 继续以固定类型窄化持锁查询能力，逐条核对当前反向边；不提前 State 快照、拆分事务或把剩余 callback API 判为安全例外。领域 Service 只接实际 owner/窄能力，不重新引入目录构造器或兼容外壳。
2. **已完成状态隔离**：可变 Store 状态使用编译器检查的 Mutex，原 read-modify-write 事务保持完整。后续业务迁移仍不能把事务拆成分别锁住的 getter/setter。
3. **已删除目录全局锁**：生产与 fixture 均使用实际 owner 事务；Messages→OAuth、Channels→OAuth 与原位 TaskChannelDeletionQuery 的 Tasks→Channels 固定叶边已核对，当前无反向边，Channels+Messages 不同时持锁。server-order 两 API 已以固定 ServerMembershipQuery 保原活读双读/版本事务；三 admission API 已以固定 ServerAdmissionQuery 保原 cap→人数→独立agreement→audit/消费顺序，membership 仍后置，不声称跨owner seat reservation；两thread API也已固定ThreadChannelCommand并保normal/actioncard不同过滤/order/fallback/joint快照语义，原七个Channels callback签名全部闭合；这不批准任意未来callback。Cards freshness barrier 保持独立，后续构造迁移不得拆开已建立的业务事务。
4. 每个切片用并发断言或 published-path 回归证明其边界，再跑完整门禁。

### 第十批：纯装配容器与剩余服务端 Sendable

1. **显式领域构造已建立**：Source Services 的目录构造参数和 live 工厂为零。Credential/ownership、message/channel projections、Fleet、MCP/integration、feedback 与 migration 的业务判定和结果映射归命名领域能力；配置、凭据、权限、relay 和 dispatcher 仍按原操作时机活读，事务与 callback 锁外调用的具体边界须逐项保持。Root 仍持原 owners 与工厂/helper 扩展，尚未成为纯容器。
2. **共享纯装配首场景已建立**：17 行 ServiceContainer 只持九组 63 个具体 Service/Support 值；共享 composer 无参时分配十三个 actual owner，显式入口十三参数全必填，无 Store bag、Root-taking bridge、别名或缓存策略。AuthScene 的私有 Auth/Invite fixture 与实际七服务 AuthFeature 使用同一 composer/owner 图，注册后配置仍活读。完整 Fallback/main 与旧 fixtures 仍用原 Root；整体切换须等全部 Feature/raw-ledger/transport 依赖和 HTTP 场景同步，不能混接两个 graph。保留 fixed-user-Hub/live-general-relay 作用域、published/silent/custom publisher 明确变体，以及生产 Cards 真实幂等 port 与 fixture 特殊 port 的区别。
3. **Feature 与 fixture 迁移未完成**：Reminder delivery 两个 POST 已返回 typed completion，Feature 仅向固定可选 Hub 发原帧。G2 installation credential、G3 app-initiated agent request 与 G4 resource-bound agent event 已归 IntegrationsAndAppAccessService。OAuth owner 接 typed attempt、回领域 outcome/facts，保 mint/GET 锁边界、app request 单事务与 event principal验证/claim/append 同锁；旧 event payload/hash/expiry 与原兼容接受集保持。G7 metadata/shared resolver已归独立OAuthIssuerMetadataService：六metadata与八scope保原liveURL/key/row独立门槛和错误/cache/协议时点，旧owner JWKS与死scopehelper已删。G7当时新增第61字段的13locals同owner runtime proof已过，未冒称完整新Fallback。G5授权跳转、human authorize、consent及两grant协议已归独立OAuthAuthorizationService：specialized oauthSession仅raw Bearer/drop7/known account，保unverified与revokedfamily接受；begin在body前不throw，四typedowner事务保原RNG/Date/拒绝顺序，消费后才独立key/openid签名。新identity.authorization为当前第62字段并有实际13owner/P256验签/快照与live事实证明，旧HTTP owner API和旧session入口已删。G6 principal projection也已归OAuthPrincipalService：三publicmethod先读raw live URL再bearer，三个owner各保完整原事务/独立资格/flatfacts，旧U/S/A HTTP owner入口删除。第63字段通过13actual mandatory composer+同图G5mint/profiles配置与OAuth真实事实变化证明，覆盖U/S/A、disabled与request删除差异；不冒称完整Fallback或全63fields方法证明。G2–G7 raw-ledger Feature迁移闭合。InstallationScene 已将私有 Auth/InstallationFixture、同 owner shared composer 与三路由真实 production registrar 接通；原 Features 在原位置委托，另保完整旧 Fallback 接线回归。下一片OAuthScene先把OAuthFeature改为五个具体Service参数，在原Fallback注册点供同owner旧图服务；focused app则从十三actual owner的shared composer供值并组合private Auth/OAuth领域fixture，迁已有HTTP场景，不能在同app混Root+新图。随后收窄family-target/read-observer/publisher variants并完成其余领域scene与完整Fallback/main/transport切换。Fixture 使用实际 owner、shared composer 和专属领域操作，不能造改名 TestRoot/global facade。最终删除旧类型、Root 工厂/helper 扩展及所有兼容构造器/别名；只删名字或缩行不算完成。
4. **已完成非 daemon unchecked 清理**：完整服务端依赖闭包与 Generated 均为零，guard 包含生成代码；恢复可复现的 knowledge 生成脚本及 template，`--check` 不改变固定语料。NIO 局部非 Sendable handler 通过 SDK loop-bound 值限定安装与访问，不以新 unchecked 壳替代。
5. daemon-only 原 41 处已逐项评估。六个不可变错误、child guard lifecycle、HTTP completion/loop timer、四个可变模型及 notification/Janitor timer、immutable activity sink、progress clock、actor-owned probe results、immutable managed MCP tool 与 reminder/delivery关联集合及StandingPrompt锁外clock、两个private completion gate及完整turn-token fold/count及turn-summary归属及Kimi lock-handle状态及WalkBudget内部消费已迁移，余 12 处见 `docs/CONCURRENCY.md`。child timer、并发 Probe 快照、Data 释放、notification、Janitor及StandingPrompt clock均有各自红→绿证据。StandingPrompt mkdir与commit两IO段之间无锁采clock，保每次步骤/原文件格式和last-actual-commit，不新增重叠clock全局串行或timestamp单调；原4绿/新3文件断言红，v2五例全绿。Janitor 的公开 Timers seam 确定性交错证明 stop/register/rearm 与不重叠 pass，原磁盘策略、已准入 pass 保活与 pending 弱引用保持；notification 另有一次真实默认 timer。这些证据不是 stdin/socket 或 TSan；HTTP 跨队列问题的原证据是源码审查。剩余 reconnect/reporting lifecycle、walk budget、callback subscriber、raw Any 和 storage 能力仍需收窄，不能因 daemon-only 而判为安全。
6. 如实同步文档，再跑最终完整门禁。只在所有目标确实完成后宣布 Phase 6 结束。

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

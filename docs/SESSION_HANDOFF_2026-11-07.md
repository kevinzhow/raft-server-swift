# Phase 6 服务端架构清理：新会话交接

更新时间：2026-11-07（InstallationScene 接受后，上海时区 UTC+08）。本文件是交接入口，优先于更早的会话摘要。**共享 composer/AuthScene/guard v2 `93f1df4`、G2 三路由领域迁移 `46b9923`、notification timer `4b43a6f` 均已接受并 push；InstallationScene 已通过全部门禁，随本文件所在切片接受。完整 Fallback/main 与其余 Feature/fixtures 尚未切换，整个 Phase 6 未完成。**

## 1. 当前目标与恢复入口

继续完成第八至十批架构清理，保持上游 `v1.21.23-source.1` 的 HTTP status、JSON 原文字节/顺序、headers、认证/校验顺序和 socket frames。逐片通过全部门禁后提交并及时 push。最终须完成纯 ServiceContainer、剩余 Feature raw-ledger、领域 fixtures 与旧 Root 删除；不能因 Root 缩行或构造参数清零宣布完成。

用户已要求继续并完成整个移植任务。当前 active goal 为 `goal-cef925d4-db4a-4005-a69c-c3b6fe6b387d`；旧暂停 goal 已无绑定，不应恢复旧 id。会话恢复后先查询最新 goal，仍 active 时按运行时要求 resume；只有整个目标完成才能 complete。

- canonical checkout：`/mnt/data/raft-server-swift`，branch `main`；实际实现工作树仍为 `/mnt/data/raft-server-swift/.agents/worktrees/nine-http-state`，branch `nine-http-state`。
- 本轮从 `4d245ee` 恢复，原 18 个未提交路径逐一核对保存 manifest 的 SHA，全部一致；随后只应用 guard v1→v2 delta，未重放 D/C patch。
- 本轮已接受的目标：十三 actual owner 的共享 composer、九组六十具体值、同 owner 私有 Auth/Invite fixtures 与真实 AuthFeature HTTP 场景。运行证据限该 Auth 场景，不代表其余五十三字段或完整新图已运行。
- guard 两个 P2 已独立闭合：反引号 protected ID 与 protected typealias LHS；Lead 的 49 Python methods、architecture 22 checks、parity-check 全通过。独立 reviewer 另通过 20 methods 与 265 个隔离 CLI fixtures。检查仍是有限词法规则，不是 AST/owner identity/DAG 证明。
- 正常 Swift 6.4.1、共享 canonical scratch、`-j 4`：九项定向、原样 `make test`、双 Server/Daemon E2E、24 项 single-process smoke 全通过。allocator signal6 本轮未重现，未查明根因，未修改 Source/timeout/concurrency 或 skip 用例来消除它。
- 共享切片日志：`/tmp/raft-resume-guard-{python,architecture,parity}.log`，`/tmp/raft-resume-composer-{targeted,full-test,e2e,smoke}.log`；已持久保存于 `.git/agent-checkpoints/20261107-0905-shared-composer-accepted/verification.json` 及同目录日志。历史失败与补丁仍在下述旧 Git checkpoint 归档，不得当作本轮结果。
- **G2 已接受**：三个真实路由已归 IntegrationsAndAppAccessService，OAuth owner 只返回 typed atomic mint outcome / credential / server facts；旧 HTTP 方法与兼容 wrapper 均无残留。mint 同锁的资格/groups/revision/token append、GET 原两次锁边界、输入兼容与 route-specific cache/error 顺序保持。channels DTO 为 `{"installation_id":…,"channels":[]}`。原实现 characterization 三函数先绿，迁移后十四项定向、正常完整 `make test`、E2E、24 smoke、49 Python、architecture/parity-check 全绿；独立 review No findings。日志 `/tmp/g2-installation-{baseline,after,full-test,e2e,smoke,python,architecture,parity}.log`。该验收仍经完整旧 Fallback，不代表新 InstallationScene 已运行。
- **Notification timer 已接受**：原隔离工作树 `/mnt/data/raft-server-swift/.agents/worktrees/notification-lifecycle` 的两个冻结文件已按 SHA 集成。Source `2f4b46915de0dbddcdefdd30c7621bd697c01b5e7eb0f97ef26637a2d30bebc6`，Tests `70f28b2657ba5ab18aa2acde92f1bb3b5aa76f45be2349e018ab0cbf68b03783`。Lead 实测旧生产 + 新 tests：build173.20s成功，23 tests 中原15绿/新8红，25 issues，exit1；新实现23全绿，正常完整 `make test`、E2E、24 smoke、49 Python、architecture/parity-check 全绿，独立 review No findings。unchecked 28→26，唯一 ratchet 下降为 RuntimeNotificationState.swift 的两处。证据 `/tmp/raft-notification-lifecycle-{behavior-red,green,full-test,e2e,smoke,python,architecture,parity,baselines}.log`；红证据和原 patch 已持久归档 `.git/agent-checkpoints/20261107-notification-lifecycle-inflight/`。更早中断和宏编译失败日志不算行为红。取消不 join 已准入 callback；不声称真实 stdin/socket、线程压力或 TSan 验收，默认 scheduler cancel/claim/deinit 交错仍是源码审查证据。
- **InstallationScene 已接受**：base46b9923 的隔离树 `/mnt/data/raft-server-swift/.agents/worktrees/installation-scene` 产出8路径 patch `/tmp/task4-installation-scene-41t386y_/installation-scene.patch`，SHA `4caf688fde1c00b2d0c46ec4107bede16bbaaf12f8746d465093c38bbd16f3b5`，同目录 manifest。Lead 整合后只另补 InstallationSceneTestApp.swift 的 `import Testing`（首编译 `_sourceLocation` 宏不可见，非行为红；作者 manifest 对该文件的旧 hash 不再代表最终版本）。私有 fixture、十三同 owners 的 production composer、实际 registrar 与真实 AuthFeature 已通过九项定向，包含五种 live 失效与跨 scene token 隔离；完整旧 Fallback 另有三路径成功接线，未混图。正常完整 `make test`、E2E、24 smoke、49 Python、architecture/parity-check 全绿，独立 review No findings。日志 `/tmp/task4-installation-scene-{targeted,targeted-retry,full-test,e2e,smoke,python,architecture,parity}.log`；首 targeted 为编译失败，retry 才是通过证据。不宣称新六十字段全部运行或 focused middleware 等同完整 Fallback。
- **下一步 Janitor 测试先行**：隔离树 `/mnt/data/raft-server-swift/.agents/worktrees/janitor-lifecycle`，base4b43a6f；唯一准备修改是 RaftDiskJanitorTests.swift，生产仍基线，未运行 Swift。冻结 test-only patch `/tmp/raft-janitor-lifecycle-tests.patch`，最新 SHA `377abaf6ec776691be5ca3e11ed7212023602b785c267a306da80ac9bd8067e8`；tests SHA `bae9bd7d3eb334b67ba52658a321eae27ebe9aa81b81722c6859b43b2e79e4d4`，普通 @Suite 共14例、默认并发（旧版本含已撤回的 owner 生命周期策略测试和 serialized trait，不得误用）。只修 stop/register/rearm、重复/stale callback、不重叠 pass；已准入 pass 跨 await 保活沿用旧语义，pending callback 仍 weak，stop 不 join。Lead 应先集成仅 tests、完整 `--filter RaftDiskJanitorTests` 跑真实红，再允许作者改生产，不碰 WalkBudget/磁盘扫描删除策略。
- 服务端下一片是 G3 app request，随后 G4 event ingest，再做共享 scope resolver/G7 metadata 前置与 G5/G6。共享 task-5/6/8 保存 typed attempt/outcome、拒绝顺序和同锁事务方案；九组实际新增 metadata 字段时应如实60→61并更新 guard，不造 locator 或塞入错误领域。后续其余 fixtures/transport 与最终完整切换/删旧 Root/六扩展/兼容入口仍未完成。任务板仅作索引，源码/文档证据优先。
- 所有 Swift 构建现在由 Lead 从同一实际验收树集中启动/collect，串行使用共享 scratch，避免子会话 background job handle 丢失与跨树反复重编译。Teammates 可以在独立树准备代码，不自行编译。OAuthFeature 写操作串行。
- 用户授权：持续推进、独立 subagents、验证后提交/ff/push；不需要重复询问这些授权。

**下方第 2–8 节保留 08:10 保存时的历史证据和归档路径。其“当前未提交”“v2 未应用”“最新失败”“优先恢复步骤”均是历史状态，由本节明确取代，不得再 apply 已整合补丁或把已闭合发现当作现存阻塞。**

## 2. 已完成并 push

| 提交 | 内容 |
| --- | --- |
| `75d2e26` | Fleet/lifecycle typed capabilities 与 current-owner 读投影 |
| `f0f6948` | Delivery/migration 的 typed binding 与活读 dispatcher |
| `8d242ae` | MCP/integration/receipt/JWT 配置映射归领域 |
| `3a24b99` | Feedback flags/config/attribution/warning 归领域 |
| `962a1c5` | ChannelMessaging immutable fixed-user-Hub binding，general relay 仍活读 |
| `8d4d255` | Tasks 原锁位 concrete Channels deletion query；删 collector，改真实 Socket/FIFO 验收 |
| `450d804` | ExperimentalSurfaceGate 只持 live DirectoryRuntimePolicy |
| `4c97878` | AuthFeature 只接七个 Service + optional PublicDirectory，删除 FallbackServices 构造 |

上述各片已通过当时的正常定向、`make test`、E2E、smoke、architecture、parity-check 后 push。`4c97878` 的完整 38-route 顺序与 handler receiver-only 等价已核；invite 先 PublicDirectory，仅 DomainError 404 回 join-link Service；complete-profile 仍 ManagedLifecycle。最初新增测试错误要求 serverName，已只修测试为原完整 `ok/serverId` JSON，生产哈希不变。

提交 `4c97878` 前中间两轮 broad 出现通知 SSE 2 秒首帧等待失败，其中一轮又 allocator/signal6。isolated pair、精确 `450d804` 基线、仅诊断 skip 新 case 的旧用例集、最终**无 skip**正常集和完整门禁均通过；未改 timeout/concurrency/通知 Source。根因未证，不能写成已修复。日志保留，见下文 archive。

## 3. 当前未提交切片：共享 composer + AuthScene + guard

工作树目前 **18 个在途路径**：14 个 staged（D六文件、C六文件、guard v1两脚本），4 个 unstaged（client-events 测试时间修正及三份 docs 草稿）。不要 `reset/clean`，也不要把 staged 误认成已验证。

### D：纯 ServiceContainer 与共享构造（已整合，Source 冻结）

- `Sources/RaftHTTP/Composition/ServiceContainer.swift`：17 行；仅九组 immutable Service/Support。
- `ServiceGroups.swift`：90 行，60 个具体字段，不公开 Store/OAuthLedger/旧 Root/locator/flat alias。
- `ComposeServices.swift`：551 行；无参入口分别创建十三 principal owners 一次，委托十三参数**全部必填、无默认**的显式入口；全图绑定只一处。
- `ComposeChannelVariants.swift`：63 行；Threads/Assignments publisher 参数必填。公开 graph 存 published 变体，旧 silent/custom 消费者未迁移，未来必须显式传各自 publisher，不能盲替。
- `AgentMessageLookupService.swift`：typed dependencies enum adapter。
- `NotificationsStore.swift`：每次复制当前 read observer slot，释放 getter Mutex 后调用；last-write 和原 history gates 不变。

旧 Root 与六个 factory/helper 扩展没有被 D 改动。生产 marketplace 保真实 Cards 幂等 port；fixture disabled/custom 仍走明确 domain ctor。ordinary/token-only/OAuth 接受集、joint-aware/ignoring-joint、普通 append metadata=false / MCP OAuth=true、env/clock/id 延迟与 relay 当前 slot 均独立核对。

D patch：`/tmp/thirteen-service-composer.patch`，base `8d4d2556e6f2a93352567a3bf18ef9dffa4c3400`，SHA256：

```text
cc9f3a0357b9128a7156b743ebf932579b1ec8a6315d420d2a0632557172af1f
```

D 正常 RaftHTTP build 与397个**旧 graph**相关回归通过；独立 task97 审核实际63个节点/旧 factory，No findings。不能把旧图回归或编译当新60字段运行覆盖。说明见 `thirteen-service-composer-proof.md`、`-result.json`、`-manifest.json`、`thirteen-composer-static-proof.json`。

### C：同 owner 的 private Auth fixtures 与真实 HTTP scene（已整合，冻结）

六个新文件：TestSupport 的 `AuthScene`、`AuthFixture`、`AuthInviteFixture`；HTTP tests 的 `AuthSceneTestApp`、`AuthSceneTests`、`AuthScenePublicDirectoryTests`。

Scene 创建十三 actual locals，全参数调用同一 production composer，并把对应实际 owners 交私有领域 fixtures。公开只 services/auth/invites，没有 AllStores/Root bridge。账户 seed 与旧 helper 只换 owner 名，normalize/hash/passwordEstablished/profile日期/analytics UUID/同锁写入不变；seed 不经 HTTP。

focused app 只注册实际 AuthFeature，七个服务来自 scene.services；复用生产 JSON boundary，不声称与完整 Fallback 私有 decode middleware 等价。真实 HTTP 验证 login/me/count/password-established、timezone/profile、注册/complete-profile、注册后 verification/provider 配置变化、invite preview/accept 和 optional directory 三支；wrongEmail400 确认不消耗本地 invite、不创建 membership。

C patch：`/tmp/thirteen-auth-scene.patch`，SHA256：

```text
3bc6e54913b78d330c74a0963e14ee211bf5136bc6c751db9ebbe27a4b7cb4c5
```

仅六个 C-owned 文件，不含 A/D overlay。首编译仅 helper 漏 `import Testing`，没有执行测试，已一行修正并保 v1。v2正常 build146.09s、七函数全绿（5 C函数/7 case执行 +2 A函数）；独立 task99 No findings。运行证据只限七个 Auth 能力，其余53个字段、完整 Fallback/main 均未做新图运行验收。详见 `thirteen-auth-scene-{files,proof}.json`、`-handoff.md`、`-targeted-v2.log`。

### F：Composition guard（Parent仍是 v1；v2尚未应用/正式闭合）

**这是下一步首先处理的差异。** Parent目前脚本仍来自 v1：

```text
/tmp/thirteen-composition-guard.patch
7252fe452f2394037f2eec15559794d3e98e813988022336542cef9f743ee7d0
```

新增 Composition 文件1000行、Container28行/固定九 public-let 组、Groups仅具体 Service/Support、Vapor/HTTPReply/JSONSerialization/Any/AnyObject code-token hard zero，以及外部 protected declarations/direct aliases 检查。旧 Root28、Services扫描和全部ratchet预算不变。明确是有限词法检查，不是 Swift AST、类型/alias resolver、owner identity 或 DAG 证明。

独立 task98 在 v1 发现两个 P2，仍须正式闭合：

1. 外部反引号转义的裸/qualified protected type ID 可绕 extension/declaration 检查。
2. typealias 只检查 RHS，整个 Composition 移走后可用 protected LHS 重定义 Root 绕检查。

F 已实现并冻结 v2；先新增反例跑红（两 method /16 false-success），修后49个 Python methods全绿，D实际Source hashes与三个新checks亦通过。**Parent未应用 v2**。不要再整片应用 v2full；对 Parent只应用 delta：

```text
/tmp/thirteen-composition-guard-v1-v2.patch
469dfaed4cb352ce8247a98225e324a4664de48d91a5d17382b1a1a7e48c2946
```

全片供精确 base450d804另建树使用：

```text
/tmp/thirteen-composition-guard-v2.patch
58a47c4f67ca05016c6bc633db95d2161ad72d19cbc53e35517c166727479b0a
```

证明/日志：`thirteen-composition-guard-v2-{proof.json,handoff.md,red.log,green.log}`。F task96 in_progress rev6；B follow-up task101 in_progress rev2，已读 v2全文/delta/反例/日志，**尚未发布 closure/No findings**。不能把作者49绿记成独立审核已通过。

F实际工作树很深，不能猜路径：

```text
/mnt/data/raft-server-swift/.agents/worktrees/nine-http-state/.agents/worktrees/ten-transport-capabilities/.agents/worktrees/composition-structure-guard
```

## 4. 最新门禁：共享切片仍未全绿

| 证据 | 实际结果 |
| --- | --- |
| D正常 build +旧图相关回归 | 通过，仅编译/旧图，不是新全图运行 |
| C正常 AuthScene 定向 | 通过，七个 Auth 能力真实HTTP |
| Parent 首正常目标 | build137.15s，HTTP allocator `corrupted size vs. prev_size` /signal6，中断，无验收断言失败 |
| 隔离后原样正常目标 | 全部通过：Realtime32、HTTP单位471、HTTPServer1378（仅验证数字，不是parity覆盖） |
| 随后 make test | 失败：既有 client-events 固定“新鲜”日期跨七日 TTL，见下节 |
| 修测试日期后的正常定向 | build35.64s，Auth/新Scene/client-events/SSE九函数通过 |
| **最新 make test** | **失败，HTTPServer allocator `malloc(): unaligned tcache chunk detected` /signal6**；其它target继续，原Kimi known issue仍原样 |
| 新共享切片 E2E /smoke | 因前一命令 `&&` 中止，**尚未执行，不能拿上一Auth片的绿冒充** |
| Parent Python/architecture/parity | v1阶段47 Python +architecture/parity通过；v2未应用后未复跑，不能当最终验收 |

最新关键日志（原件在 `/tmp`，已持久备份）：

- `/tmp/raft-thirteen-composer-targeted.log`：首次 allocator6。
- `/tmp/raft-thirteen-composer-isolated.log`、`-targeted-retry.log`：隔离/无排除组合通过。
- `/tmp/raft-thirteen-composer-full-test.log`：固定日期过期导致15个级联断言。
- `/tmp/raft-thirteen-composer-clock-targeted.log`：日期修正后九函数通过。
- **`/tmp/raft-thirteen-composer-full-test-clock-fixed.log`：最新 allocator6；4432附近退出，4459附近 tcache。**
- `/tmp/raft-thirteen-composer-{python,architecture,parity,parity-summary,baselines}.log`：v1阶段证据。

最后 job `bash-3f4148f5e9054b5d` 已 collect exit2；之前相关 jobs也均collect，无仍运行的编译、server或background任务。所有 teammates已安全停止；不要复用旧job ID作为新运行证据。

### 日期修正（已在工作树，未提交）

`Tests/RaftHTTPServerTests/ProductClientEventsTests.swift` 把默认“新鲜”时间和duplicate写死 `2026-10-31T00:00:00.000Z`。Service 原本就按 `now - timestamp > 7days` 丢弃。2026-11-07 00:00UTC之后真实跨界，HTTP accepted0，随后 rows0 级联；不是新图业务回归。

现在仅测试本地 ISO8601DateFormatter（非static）取当前毫秒时间；duplicate完整字符串只生成一次再重发；显式2020过期样本、所有202/accepted/400及row断言不变，生产cutoff未改。patch `/tmp/thirteen-client-events-test-clock.patch`：

```text
ee608f7353e397e150b3a452a133e40c55740f5c54b49f33f24c3d7c8ece9ca8
```

独立 task100 No findings。`recordedClientEvents` 已审：它直接读取 ProductEventStore 真实 primary admitted rows，写入同 Mutex 下的 rows/seenIDs，并返回该实际admitted数为HTTP accepted；没有test producer collector/第二镜像数组。因此是领域ledger readback，不是豁免 tracer，也未靠改名规避要求。

## 5. 优先恢复步骤

1. 进入实际 Lead工作树；检查 HEAD/status与下面持久manifest，先核当前18路径。不要从main重复全量apply D/C，也不要清理/重置任何旧WT。
2. 应用 **guard v1→v2 delta**，核SHA；完成独立复核两个P2，保留原v1结果。task编号属于旧会话，新会话不应只依赖taskboard。
3. `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts -p 'test_*.py' -v`，再architecture/parity-check；v2作者49绿不是Lead已执行。
4. 对当前最新 allocator6，按AGENTS：先隔离通过，再一次原样完整测试。若仍失败，保日志并诊断；不改并发参数/timeout、不skip验收、不声称runtime根因已解决。固定日期问题已静态/定向证明修正，最新失败是另一 allocator中断。
5. 必须完成正常定向、`make test`、E2E、smoke、architecture、parity-check后才提交共享切片。三份未提交 docs是**候选草稿**，接受前须把表述与最后证据校准；不可当前直接commit全部 staged。
6. 完成一片即提交/ff/push；然后继续下节余项。新会话若有docs-only主分支提交，先核提交图再合流，不能强推或丢失交接。

固定工具链和命令：

```bash
/mnt/data/opt/swift-6.4.1-RELEASE-ubuntu26.04/usr/bin/swift test --scratch-path /mnt/data/raft-server-swift/.build -j 4 --filter 'authScene|authFeature|clientEventsRespectSharingAndDropUnregisteredRows|notificationStreamRejectsUserSessionsStartsAtLatestReplaysAndClosesOnLogout'
make test SWIFT=/tmp/raft-batch8-swift
make test-e2e SWIFT=/tmp/raft-batch8-swift
SWIFT=/tmp/raft-batch8-swift ./scripts/smoke-server.sh
make architecture
make parity-check
make parity
```

只能Swift6.4.1、`-j 4`；系统Swift6.1.3无效。wrapper与canonical scratch必须检查存在；当前Lead `.build`链接canonical `.build`。不要让两个任务同时用一个scratch，不修改Vapor pin或Package.resolved。上述命令是恢复步骤，保存交接时没有再运行它们。

## 6. 剩余整个目标，不要误判完成

- 完整 Fallback/main 仍旧 Root图；其余Features大多仍持宽 services。
- Source剩余 Feature ledger审计的G1 reminder已 `5d660c9` 完成，**G2–G7** installation credential、app request、agent event、consent/grant、principal projection、scoped discovery 未迁。按use-case Service做，不复制一层ledger facade；OAuthFeature共享文件需串行或明确不重叠。
- 新AuthScene只是首领域场景；大量旧fixtures、Root静态/嵌套类型/六factory扩展仍需移至private领域operators+shared composer；不造改名TestRoot/global facade，不混两图。
- 完整切换须等所有Feature/rawOAuth/OIDC/transport依赖与完整HTTP场景准备好，再原子切换并最终删 EmailLoginDirectory、六扩展及兼容init/alias。旧 `computerCredentialValid` Source/Tests查无调用，最终删前再核；空Bearer行为不能盲alias严格RuntimeForms谓词。
- 当前已接受三固定叶边：Messages→OAuth、Channels→OAuth、Tasks→Channels。Tasks query本身不取OAuth；七个Channels callback API仍债务，不能一般豁免；保持Channels先release再Messages/Tasks。Cards send-commit独立锁不合并。
- 非daemon unchecked为0，daemon仍28处，见 CONCURRENCY；不能因checked或daemon-only声称安全。timer publish/cancel、rawAny、subscriber等仍未完成。
- Fallback immutable fixed-user-Hub与live general relay不同scope；拒绝全局mutable room/user pair；read observer本来last-write（Main后被Fallback覆写），不是membershipObserver。Membership cleanup直接用各Fallback固定Hub。
- 每个credential表面接受集、Foundation数字/Bool/duplicate-key/排序bytes、missing/null、消息mirror事务、验证优先级均保持。

上游parity仍406 locked模块：routes219/2000cases、socket7/16cases、daemon180/2616cases；daemon执行/排除限定保留，coverage=n/a。报告此台账，不用Swift测试数量作parity覆盖。

## 7. 持久资料，不依赖聊天或 /tmp 生命周期

完整快照目录（Git内部本机资料，**没有把未绿代码推到main**）：

```text
/mnt/data/raft-server-swift/.git/agent-checkpoints/20261107-091001-service-container/
```

- `manifest.json`：保存时HEAD4c97878、18文件SHA、staged/unstaged状态、98份artifact原路径/备份路径/SHA。
- `integrated.patch`：相对4c97878的完整在途补丁，含已staged新文件及未staged docs/clockfix；当前树已经有这些内容，不要再apply。
- `index.patch`、`unstaged.patch`：可分步重建保存时index/worktree；仅新建精确base恢复树时使用，先check并核manifest，不能覆盖现有工作。
- `artifacts/`：已复制D/C/A/F v1/v2 full/delta/proofs、clockfix、R7全部相关测试日志、wrapper、旧Source recipe/rootJSON/fixture审计/ledger审计/transition delta/Hub lifetime/Task lock审计。

重要历史规划基准：`eleven-composition-recipe.md`与rootJSON是旧Src c5078fa；fixture审计855ctors/539files是旧Tests29f51f8，不是当前计数。`twelve-container-transition-delta.md`已按后续typed adapters修正、九组60、禁全局room-slot；其新API原本是proposal，当前D/C已部分实现，但全Fallback/fixture切换仍UNVERIFIED。归档内同名文件可恢复，不必重新全仓审计。

作者工作树仍保留：canonical `.agents/worktrees/thirteen-service-composer`、`thirteen-auth-scene`、`thirteen-auth-feature-construction`；F深路径见上。所有原patch与旧失败log未删除。不要删除旧WT/patch/cache来“恢复干净”。

## 8. 执行约束与已知失误

当前file policy danger-full-access、审批关闭；**工具调用不要设置 sandbox_permissions，不请求升级**。本会话Lead及部分reviewer仍错误带了该字段，已披露，未发生审批/升级重试；这是未遵守约束，不能在新会话报告成合规。read/grep/glob优先；现有文件先read再edit，任何move/delete前核绝对路径；所有bash exit非0必须调查。

用户任务是保存交接，不是接受未绿Source。当前没有执行新的修复、guard delta apply、测试或源码提交；仅保存状态、文档和证据。自动续跑已停止；保存收尾时 get_goal 返回 null，新会话从实际状态与用户继续授权重新建立目标。

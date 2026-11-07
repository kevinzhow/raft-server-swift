# Phase 6 服务端架构清理：新会话交接

更新时间：2026-11-07（G6 接受后，上海时区 UTC+08）。本文件是交接入口，优先于更早的会话摘要。**G2 `46b9923`、G3 `be64078`、G4 `9088d14`、G7 `8de8552`、composer/AuthScene/guard `93f1df4`、InstallationScene `87a0974`、notification `4b43a6f`、Janitor `3717c3f`、order `0b4419e`、admission `d76947a`、thread `850b276`、daemon helpers `973bc6d`/`c367d53`、StandingPrompt `74bbccd`、Once `9cd030c`、Token `497c068`、TurnSummary `5397f4f`、G5 `3f526ab`、Kimi `623bdc9`均接受并push；G6 typed principal/63字段实际同owner证明及全部门禁完成，随本文件切片接受。当前九组63field、G2–G7 Feature raw-ledger与七generic Channels闭合、unchecked余13；其余领域fixtures、完整Fallback/main/transport与旧Root删除仍未完成，整个Phase6未完成。**

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
- **Janitor 生命周期已接受**：隔离树 `/mnt/data/raft-server-swift/.agents/worktrees/janitor-lifecycle`（base4b43a6f）冻结 source-only patch `/tmp/raft-janitor-lifecycle-source.patch` SHA `3f8707a211dc999c8f99be7229460438652b9b4b948351a70f3bda86cf139dcd`；Source SHA `f98ac2ef47cf01d40bddf8916106b910020e618e8b669c48f5a1f0181f041e8a`。Tests SHA `bae9bd7d3eb334b67ba52658a321eae27ebe9aa81b81722c6859b43b2e79e4d4`，普通 @Suite 默认并发十四例；真实旧 Source 红为六新核心失败十四 issues、原六+二 guard 通过，新实现十四全绿。完整 `make test`、E2E、24 smoke、49 Python、22 architecture、parity-check 全绿，独立 review No findings。unchecked 26→25，RaftDiskJanitor.swift2→1，仅 WalkBudget 保留。日志 `/tmp/raft-janitor-lifecycle-{behavior-red,green,full-test,e2e,smoke,python,architecture,parity,baselines}.log`。原 pass 强 self/pending weak 保持，stop 不 join 注册或 pass，永久阻塞 timer 可占 drainer；未修改磁盘规则、不声称真实 timer/disk/daemon/TSan。
- **G3 已接受**：隔离树 `/mnt/data/raft-server-swift/.agents/worktrees/app-agent-access`（base87a0974）完整7路径 patch `/tmp/task5-g3-implementation-xc45p792/g3-app-agent-access.patch` SHA `7e71e4f0f3c0022072531319ad0ee8d108d0f7acc9d24563ffe1b9cf4f99420b`，同目录逐文件 manifest。baseline 四函数含 Bool 五case 全绿；集成后十八项定向含原 bytes、G4 邻接与真实32争用全绿，正常完整 `make test`、E2E、24 smoke、49 Python、22 architecture/parity-check 全绿，独立 review No findings。日志 `/tmp/task5-g3-{baseline,after,full-test,e2e,smoke,python,architecture,parity}.log`。Service591行真正持兼容 policy，owner typed attempt/outcome/flat receipt，同锁/拒绝顺序、legacy scopes、existing grant不扩scope、最多1grant/每次1request保留；旧 owner HTTP method/调用0。本片仍经完整旧Fallback，不声称新全图已运行。新IDs user643、server668/669已用，AGENTS next644/670。
- **Channels A片已接受**：隔离树 `/mnt/data/raft-server-swift/.agents/worktrees/channel-membership-query`（base3717c3f），完整五scope patch `/tmp/raft-channel-membership-query.patch` SHA `78d37d4de3a288fc5602e9c67bb6fa6594963b3402377933a05b90b95d4c9dd8`，固定 ServerMembershipQuery 代替两个 order callback，保原锁位、orderedList 双读/GET不写/PATCH版本，unit/HTTP复用原IDs验 live changes。定向四例与正常完整 `make test`、E2E、24 smoke、49 Python、22 architecture/parity 全绿，独立 review No findings；Channels 原7个 generic API 余5（3admission、2thread），同锁图 Channels→OAuth，未新增Container字段/owner。首次 targeted 是 swift-package 构建规划阶段 `_dispatch_event_loop_drain` signal11/exit139（未进入编译/项目测试），保 `/tmp/raft-channel-membership-query-targeted.log`；同源码/参数 retry build121.95s、unit2+HTTP2全绿，根因未知，未改并发/timeout/skip/cache。其余 `/tmp/raft-channel-membership-query-{targeted-retry,full-test,e2e,smoke,python,architecture,parity}.log` 为通过证据。
- **Daemon checked helpers 已接受**：Lead本树只改 LegacyActivitySink/RuntimeProgressState/ProbeGate 三Source与ProbeGateTests。immutable sink五callbacks checked，progress四值Mutex，probe actor共享Task<any Sendable,Error>代替unchecked Any盒；同key结果类型假设、FIFO/release/错误语义与各时钟操作保持。原14 helper tests baseline/after均绿，正常full、E2E重跑、24smoke、49Python、22architecture/parity全绿，独立review No findings。unchecked25→22，19files，server仍0。probe fixture观测改checked Mutex，原sleep/timeout/断言保留。日志 `/tmp/raft-daemon-checked-{baseline,after,full-test,e2e,e2e-retry,smoke,python,architecture,parity,baselines}.log`；首E2E因第二进程bind address-in-use失败，已核原freePort无持有/原stop清理路径，未改tests/timeout/并发，同参数retry双server+daemon通过，未确定具体端口占用方。不是新的行为红，不声称真实helper daemon wiring或TSan/reference/error identity/全部FIFO交错。
- **G4 已接受**：隔离树 `/mnt/data/raft-server-swift/.agents/worktrees/agent-event-ingress`（basebe64078），完整5path patch `/tmp/task6-g4-implementation-4q0sfe25/g4-agent-event-ingress.patch` SHA `16773b49e77fe08a47ee4438bc00f34edb7d80bb6a02d87bcd6f0582b39eb680`，同目录manifest；Service643行、owner344、values44，Tests保持冻结SHA `4d3bc91b35b1d78af586b0c8e0e92574b6cbfb5cdf3f02521623065dd12fe77e`。baseline四HTTP与after十三项含queued32claim/旧body/byte/消费/邻接principal全绿，正常full、E2E、24smoke、49Python、22architecture/parity全绿，独立review No findings。日志 `/tmp/task6-g4-{baseline,after,full-test,e2e,smoke,python,architecture,parity}.log`。typed markers/8refusals/原principal→claim同锁、Foundation payload无Double/重编码、旧queued仅status、expiry原ISO整秒均保留，不增live gates；旧owner HTTP API/caller0无wrapper。精确旧时间字段未全做pre-claim快照，部分依原赋值核对。本片仍完整旧Fallback，不冒称新全图。新IDs644/670已用，AGENTS next645/671。
- **Channels B 已接受**：树 `/mnt/data/raft-server-swift/.agents/worktrees/channel-admission-query`（base0b4419e），8path `/tmp/raft-channel-admission-query.patch` SHA `4141b7afe9c99b1b365f2f357ed4485f865b951d45897190b65ca66f6a11561b`；固定query只private实际OAuth，原cap→人数→独立协议→audit/消费→后置membership保留，真实owner unit/HTTP无spy，旧IDs复用。十八定向（unit5+HTTP13）、isolated notification1、正常full重跑、E2E、24smoke、49Python、22architecture/parity全绿，review No findings，Lead核八文件SHA。首full的旧notificationStream case首帧/后续断言8issues，未修改相关Source/Tests、poll/timeout/并发；route cursor在beginStream已捕获，isolated后原参数full重跑绿，根因未定位，不能说已修复。日志 `/tmp/raft-channel-admission-query-{targeted,full-test,notification-isolated,full-test-retry,e2e,smoke,python,architecture,parity}.log`，保首次失败。当时余thread2，现由下述C片闭合。
- **Thread C已接受**：树 `/mnt/data/raft-server-swift/.agents/worktrees/channel-thread-command` base66a3a16；9path `/tmp/raft-channel-thread-command.patch` SHA `ee87e7ef58148457a789d603c0668d2017da68d03bc53e11811db671ba16cc45`，逐9file哈希 `/tmp/raft-channel-thread-command.sha256`。固定command只private actualOAuth，normal/actioncard过滤/order/fallback/joint快照不同语义保持，真实primary rows替代minted/LockedCounter。二十定向（unit7/HTTP13）+正常full/E2E/24smoke/49Python/22architecture/parity全绿，独立review No findings；日志 `/tmp/raft-channel-thread-command-{targeted,full-test,e2e,smoke,python,architecture,parity}.log`。原七generic Channels API归零，不是允许未来任意callback；joint并发/self/inactive未补，源码逻辑保持，不冒称TSan全锁图。未新固定ID。
- **G7已接受**：树 `/mnt/data/raft-server-swift/.agents/worktrees/oauth-issuer-metadata` base9088d14。完整16path `/tmp/task8-g7-implementation-jt_frw39/g7-issuer-metadata.patch` SHA `6f77ac05da3db7bdea956c0d476f881b199e99c7f48422cbefee4277b641d019`，同目录manifest，原3HTTP tests保持5ad4...冻结patch。Lead六原Source baseline绿，十一after（mandatory新field1+HTTP10含JWT↔JWKS interop/scopedMount）绿，正常full/E2E/24smoke/49Python/22architecture/parity全绿，独立新实现review No findings。日志 `/tmp/task8-g7-{baseline,after,full-test,e2e,smoke,python,architecture,parity,baselines}.log`。真实profiles/oauth、live regex/row、secret独立锁/原KDF、六metadata与八scope所有原位错误/cache/body/origin??空保持；旧owner.jwks/死scopehelper已删。九group当前61field/61approved type，guard仅allowlist+正例扩展，13locals mandatory composer新identity.issuerMetadata与同graph flows/owner live事实已实际运行；不冒称全部61field/fullFallback新图。历史60不改，ID645/671已用，AGENTS next646/672。
- **Reminder/delivery小片已接受，clock仍单列**：task13的ManagedMcpTool immutable checked与ReminderInboxStore/RecentDeliveryIds各自两个关联集合单Mutex已完成，unchecked22→19（16 files），server仍0。独立review No findings，测试界限已明确；14before/after真绿，含128并发预置item替换/list与64 delivery记忆/容量/TTL零负回拨；正常full、E2E、24smoke、49Python、22architecture/parity全绿。五file冻结 `/tmp/raft-inbox-delivery.patch` SHA `d348647ad7cec7dd7d1e8ff874ff148b7981f9a1ffa1ddb1625fa25c672e6298`，日志 `/tmp/raft-inbox-delivery-{baseline,after,full-test,e2e,smoke,python,architecture,parity,baselines}.log`。不冒称并发首次item insert所有交错、daemon wiring/TSan；其他DaemonLog测试不碰。task14现已单独关闭（下段），不把原三个checked候选与clock行为修复混片。
- **StandingPrompt v2已接受**：隔离树 `/mnt/data/raft-server-swift/.agents/worktrees/standing-prompt-clock` base850b276。test-only `/tmp/raft-standing-prompt-clock-tests.patch` SHA `70fc9763dc1165e651398b4d30622973cfad50dc0bd9e4b3679dced1d37e87ee`，最终source-only `/tmp/raft-standing-prompt-clock-source-v2.patch` SHA `5d0b0ae2e097b17d7ac26821fdf205afd63351524ce60ecd114936a9749366d8`，manifest `/tmp/raft-standing-prompt-clock-final-v2.sha256`（Sourcecadd341...、Teste380575...）。原Source5例旧4pass/新1fail3真实file/read断言，exit1/2.002s且writer收回；v2五例全绿8.07s build，正常full/E2E/24smoke/49Python/22architecture/parity全绿，独立v2review No findings。v1 e662...已被最小布局v2替换，v1绿不算最终after，旧artifact保留。日志 `/tmp/raft-standing-prompt-clock-{behavior-red,green,green-v2,full-test,e2e,smoke,python,architecture,parity,baselines}.log`。mkdir第一IO段→唯一clock锁外→第二IO段record/sortedJSON/atomicwrite，read/plan/schema/errors不变；内层6000先commit/外层5000最后commit真实文件证明。重叠clock可overlap、最后actual commit胜，不许声称clock全局串行/timestamp单调或跨实例read-plan-write事务。checked三let，unchecked19→18/15files；仅helper/native thread/file证据，无daemon resume/TSan声称。
- **private Once gates已接受**：Lead task17冻结两Source `/tmp/raft-once-gates.patch` SHA `3fff9b00cf6c7ed2f22e02c3611148a5c824aeae7410395826d209c865909bda`。仅ChatBridgeRequest/OarListModels私有Bool gate改checked Mutex，所有take/cancel/resume/scheduler与Oar其余两unchecked不动，Tests不改。原16baseline首Oar两eventually200yield断言失败，isolated2绿+相同16retry绿，after16/正常full/E2E/24smoke/49Python/22architecture/parity全绿，独立review No findings。原失败保留、不称根因已修；日志 `/tmp/raft-once-gates-{baseline,baseline-isolated,baseline-retry,after,full-test,e2e,smoke,python,architecture,parity,baselines}.log`。unchecked18→16/14files，server0。
- **TokenAccumulator task16已接受**：隔离 `/mnt/data/raft-server-swift/.agents/worktrees/turn-token-state` base74bbccd，test-only `/tmp/raft-turn-token-state-tests.patch` SHA `7ec36c225dc7dc4b73ee524b802fe61aad75787a2f076480950f2177ad4058b5`，Source-only `/tmp/raft-turn-token-state-source.patch` SHA `74dff41dd17b6e6b160f342d5f2163d0d3cab7a70bf6a98f92261195b3f7c4aa`，最终manifest `/tmp/raft-turn-token-state-final.sha256`（Source736b046.../Test630cf7...）。原4绿，新per-call256真实丢更新/cohort+final+trace fail3（233/464/630/804），Codex fixedbase0 cohort fail1；新6绿、正常full/E2E/24smoke/49Python/22architecture/parity全绿，独立Source+Tests No findings。日志 `/tmp/raft-turn-token-{original,per-call-red,codex-red,state-green,state-full-test,state-e2e,state-smoke,state-python,state-architecture,state-parity,state-baselines}.log`。单Mutex added/base/latest完整note/count，三setter独立保；nil/负/finite转换/缺last首条不写latest/较小latest/任一倒退回整added保持，冻结tests无减256。Codex预置base0，无first-base并发选举/跨setter事务/daemon wiring/TSan声称。unchecked16→15/13files。
- **Turn-summary task18最终v2已接受**：树 `/mnt/data/raft-server-swift/.agents/worktrees/turn-summary-state` base497c068，Test-only `/tmp/raft-turn-summary-state-tests.patch` SHAd0e797...，最终Source-only `/tmp/raft-turn-summary-state-source-v2.patch` SHA `6f726f085a819d2768ba96e1acdd258a1dded139b69c9def96626d661309d3e4`，manifest `/tmp/raft-turn-summary-state-final-v2.sha256`（Source016e5c.../Test493436...）。原Source5与最终v2同5绿，private Sendable valueacc/单Mutexmap完整begin/batch/send/finish，无旧race修复声称；两个256join后唯一实际summary计数/20cap/FIFO/maxend真实。v2借用内removeValue/fold/writeback避免map保留旧嵌套值，v1 artifact不覆盖、v1after非最终证明。full首Realtime membership notice0/last race-70两断言fail，isolated1绿后首retry HTTP native malloc unaligned tcache/signal6；HTTP3 isolated绿后原参数native retry全绿。相关Source/Tests/timeout/256均不改，不能声称两根因已修。E2E/24smoke/49Python/22architecture/parity全绿、独立finalv2review No findings。日志 `/tmp/raft-turn-summary-{original,state-baseline,state-after,state-after-v2,state-full-test,state-realtime-isolated,state-full-test-retry,state-http-isolated,state-full-test-native-retry,state-e2e,state-smoke,state-python,state-architecture,state-parity,state-baselines}.log`。unchecked15→14/12files；无concurrentbegin/observe-finish混跑/TSan/wiring/benchmark声称。
- **G6 task19已接受**：WT `/mnt/data/raft-server-swift/.agents/worktrees/oauth-principal-projections` base3f526ab，完整14path `/tmp/task19-g6-source-jt31d618/g6-principal-full.patch` SHA `b697c0adbbf4aea8a0ab16e517a23a7a3bb6e7616984d7a938f13f8f7cb7a532`，v3 overlay12541d...，同目录manifest/equivalence-proof。Lead无Source修复、14hash吻合。旧Source v1compile36.40s三绿、人new197误认flat auth/me为nesteduser失败1，是test构造P1非Source红；v2eca34e...只修该行且三assert原样，4真绿/No findings；v3b7786...借既有removeAuthorizationCodeForTesting追加10line，human单例补绿而另3v2hash原样/绿，不谎称v3重4。旧公共seam不存在的limitation已纠正，canonical `.git/agent-checkpoints/20261107-g6-principal-baseline`完整归档。新Service92/Values49/Owner177/newUnit95：18unit+83HTTP+1daemon after实际102绿/build175.36s，新mandatory13locals经同图G5mint与actual profiles/OAuth事实证明identity.principal第63字段，含request删后S/A仍通。正常full/E2E/24smoke/49Python/22architecture/parity首次全绿，独立Source No findings并读actualafter；日志 `/tmp/task19-g6-{baseline,baseline-v2,baseline-v3-human,after,full-test,e2e,smoke,python,architecture,parity,baselines}.log`。四v3HTTP exacthash/0receiverdelta/nohook，三面URL-before-bearer/资格/cache/三picturehelper/原completeborrow不改，旧3ownerHTTP入口删/G4G7helper保。ID647/673/674已用AGENTS next648/675；boundednewfield证明非全63/fullFallback；病理caller/unknown/duphash/ties仍Source等价限度。
- **Kimi handle task20已接受**：WT `/mnt/data/raft-server-swift/.agents/worktrees/kimi-handle-state` base3f526ab，Source-only `/tmp/raft-kimi-handle-state-source.patch` SHA `1fed938536d66088e557d4f2937b2aad2d35af00dfdf35987b064abbc3f1bb97`，manifest `/tmp/raft-kimi-handle-state-final.sha256`（Source7d72.../原Test5cdd...）。soleString?→checkedMutex/firstnilwrite，两个publicgetter独立/API不改。原enum至EOF107行tail两bin同1bfef3...且Lead再核，FS/options/retry/mtime/monitor/withLockFn/defer/callback全byte保。原128Tests与imports/helper恢复、无新增Test；withdrawn `/tmp/raft-kimi-handle-state-tests.patch` 仅历史artifact，不可apply。原3before/after真实process/fs/monitor绿，正常full/E2E/24smoke/49Python/22architecture/parity绿、独立Source No findings；原NSLock已安全，不称旧race/完整takeover/pairedgetter/TSan/benchmark。日志 `/tmp/raft-kimi-handle-{original,state-after,state-full-test,state-e2e,state-smoke,state-python,state-architecture,state-parity,state-baselines}.log`。unchecked14→13/11files；当前下一G6仍test-only，nextuser647/server673（若Tests实际用674，验收后再递增）。
- **G5已接受**：task15 g2树 `/mnt/data/raft-server-swift/.agents/worktrees/oauth-authorization-protocol` base74bbccd，完整16path `/tmp/task15-g5-source-3cr6y_of/g5-authorization-full.patch` SHA `4b57e7b53f25551f78440a16a8ed13ac867853bd46efed130a2e1759c29e597d`，同目录manifest/equivalence-proof；Lead集成无Source修复、16hash吻合。原Source v2六函数grant5args真绿；新98定向（unit17/HTTP80/daemon1）含rawsession/mandatory62field/P256验签/PKCE/消费并发绿，正常full/E2E/24smoke/49Python/22architecture/parity全绿，独立Source No findings。日志 `/tmp/task15-g5-{baseline,baseline-v2,after,full-test,e2e,smoke,python,architecture,parity,baselines}.log`。v1 baseline session10issues是HTTPFields首尾OWS测试构造P1，不是Source行为红；v2test-only5fec...绿与正式No findings已另归档；raw空尾/尾SP通过新Service unit真验证，不能把HTTP规范化说成Service trim。232行Service两privateactualowner、typedattempt/flatreceipt四owner原事务、specialized session/body/config/key点/三parser/两grant资格/提交后openid签名保持，旧Owner4HTTP入口/旧session API删净无compat。当前九组62fields/62reviewedtypes，13actuallocals proof真实profile早snapshot/configctx/liveRole/key/JWT同图验签；不是所有62field/fullFallback runtime。只有旧ByteParity seed一次/Concurrency seed一次receiverdelta，冻结v2新增HTTP正文及另两filehash不变。IDs646/672已用、AGENTS next647/673。
- 服务端下一片OAuthScene/具体Feature参数：canonical `.git/agent-checkpoints/20261107-oauth-scene-followup-plan.md` 只读初案，G6后re-read实际名称；OAuthFeature只需flows/metadata/authorization/principal/apps五具体Service，原Fallback同owner供值保完整旧图，focused新app用13actual/sharedcomposer+private Auth/OAuthfixture，不同app不混Root/新图。先选现有OAuth HTTP场景迁接线/fixture、断言正文不改，别一口气移所有fixture或造Root别名。完整生产切换依赖在 `20261107-production-cutover-plan.md`：family-target窄查询、main readObserver先严后被configure覆盖、四factory/三files silent/custom/published、固定userHub/livegeneralrelay及Cards production/custom policies不可混。Daemon后续WalkBudget原优先/clock锁外/完整RMW/64批overdraw计划 `20261107-walk-budget-plan.md` 仅只读，须另task/原真实结果baseline再Source，不因计划当已授权。后续其余 fixtures/transport 与最终完整切换/删旧 Root/六扩展/兼容入口仍未完成。任务板仅作索引，源码/文档证据优先。
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

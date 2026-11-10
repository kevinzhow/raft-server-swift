# 复刻推进计划

**长期目标**：等价复刻 `raft-source` tag `v1.21.23-source.1` 的 server 与 daemon。
**规格**：上游 Node 测试中对外可见的 HTTP 状态码、JSON、响应头与套接字帧；实际交付还须满足固定版本 Web/CLI 消费端的完整业务链路。

## 0. 当前交付目标与推进顺序

**当前用户目标**：完成 Swift Raft 的真实生产部署，沿用既有 Cloudflare Tunnel、已登录 Codex、Cloudflare Email Sending 和 R2。开发、构建、缓存、服务与临时产物全部使用数据盘。生产域名、地址、密钥、收件人和操作凭据仅保留在仓库外。Phase 6 的架构债务不替代本次交付目标。

**当前阶段**：完整交付路径已按实际 Web／CLI 消费者、注册路由与 frame、DTO、Service、真实 Store、PG／daemon／provider 建立代码契约矩阵。Codex owned reset、typed DM、non-Codex 配置保存和相关共享文件已整组收口，并通过完整相关目标及同一最终 Source 的九组独立 PG。profile 与 Task 旧 gate 消费及完整 native 接收／取消／清理出口已完成整组作者回读和同一唯一独审，精确采用两个测试／脚本差量，生产 Source 未变。最新完整实进程 E2E、smoke、architecture、parity-check 均已通过，完整单元门禁也已通过，最终 Source 输入保持不变。官方 Computer 的干净构建、复制包闭包与复制 Node 冷导入，以及现有 Caddy 两个静态 profile 的临时完整 HTTP 验证也已通过。已验证批次已提交并 push 为 `1c40fe5b4b00f81b788f86222577dec2cd0700d5`，从该干净提交构建的最终 Main release 已成功，构建前后所有跟踪字节不变。独立复制的 Main、资源与 Swift／JSC 已通过普通冷启动和实际 PID／文件映射验证。四角色制品已完成真实来源、完整 inventory、私有配置与启动器绑定校验，并已复制到生产数据盘。显式 closed-all 已在相同既有 gateway 实际加载；全新 PostgreSQL 17／Redis 的鉴权、初始空数据与 schema 初始化均已验证。最终 Main 已在真实 user unit 下通过 private health200、公开版本字段、native／Socket.IO 协议及实际 PID／载入文件验证；随后再次核验相同 gateway 与全部关键路径的本机和 Cloudflare 公共 503，现有 owner-bootstrap phase 已通过。真实 owner 已经正常注册，验证邮件的 durable outbox 已获 Cloudflare 正向 recipient acceptance，只有一次发送尝试；实际到箱链接与后续正常 Web 消费另有独立证据。静态制品已逐字节复制到既有 gateway 的数据盘目录，实际浏览器、Computer HTTP、daemon HTTP 与 native WSS 的出口也已分别观察。受限静态入口已实际加载，真实浏览器已显示正常登录页且未见 console error；主／feedback 的 HTML 除既有 Cloudflare 注入的一项 analytics beacon 外，解析后的节点与数据一致，十项实际公共脚本／样式／预载资源逐字节匹配制品。受限 peer/header 拒绝与真实 Cloudflare 防伪、私有缓存策略已验证。真实邮件链接已在正常公共密码登录后由 Web 消费，公开 `me` 已确认邮箱验证与 profile 完成，页面保留了原有显示名。随后发现首个 server 创建前的必要缺口：真实已验证且 profile 完整的账号读取 server 空列表时返回401，原因是普通账号零 membership 被转到另一身份域的 public fallback。用户现要求更新进度并准备交接，修复与部署在此处停下。公开 Before 已在原 Source 上重现该缺口；仅有的红色回归草稿已归档到仓库外数据盘，并恢复跟踪测试原字节，生产 Source 与监听进程均未修改。整组源码核对还确认 normal completion、survey、原 owner handoff、持久化兼容及 setup 路由 scope 的连接缺口，见下方交接矩阵。下一位应按矩阵完成一个 coherent batch，完整门禁和新干净制品通过后，继续正常 enrollment、实际 Computer／Codex child、模型与完整正常 Web 验收。通过前不开放完整入口。

**已验证及其边界**：

- 先前隔离 stage 已证明真实 Main、PG／Redis、官方 Node Computer、实际 Codex catalog，以及普通消息和 Task 的真实模型执行。这是较早制品的证据；最终干净制品、完整正常 Web 流程和生产仍待验收。
- 加密 R2 字节、认证下载、有界预览、应用备份、新目录恢复和恢复后 Main／TLS 已通过。恢复复用原应用密钥与同一 R2，不代表独立对象桶或异地密钥恢复。
- Auth、消息权限与冷读、Task、Socket、active-account、机器查询、legacy scan、human delivery、Grok admission 和 terminal recovery 已分别通过相关公开目标及独立 PG／socket。保留真实 14-owner 图、rollback-only 丢弃和原 writer lease 下的真正 stale CAS；这些协议输入受控，不能当作官方 provider 接受。
- Builtin v2 的完整定义、sources、edit 与 formValues-only 往返、secret identity、拒绝不变、更改触发 lift 及 no-op 不重复 lift 已通过。完整八定义、v1 字节和既有 Grok／权限链保留；builtin provider/native 执行不在此资格内，真实生产模型路径使用 Codex。
- 固定版本成熟 mdast／GFM 与上游相同配置已接入进程内 JavaScriptCore。原 UTF-16 range、非 BMP／NUL ABI、原生语料、C 审查和实际资源 bundle 已验证；独立复制制品能解析并证明 JSC 映射，缺 bundle 会在监听前拒绝。最终 release 也已实际递归核验 ELF，并显式纳入动态 JSC，复制完整选定库与内部别名。复制后的普通 Main 冷启动已真正调用随包 parser，同一 PID 的 Swift／JSC 及其余文件映射均对应复制 inventory 或明确的 host platform；全体复制 ELF 的搜索结果也符合该边界。另已在全新生产依赖上，从真实 user unit 的最终 Main PID 复验实际 Swift／JSC／其余载入文件、private health200、版本接口与 native／realtime 协议。该结果仍不代表完整正常 Web、Node service／resident／Codex child、provider 或邮件已通过。
- Forward／Share 的真实 native membership、postable facts、原重放／PNG／host 合同已通过完整相关目标。workspace 的完整授权顺序和 orphan Task retained no-write 也已通过，原 RBAC 断言保留。
- runtime 原始输入、JS 转换失败、精确错误响应与拒绝后未写入已通过整组目标。typed DM／follow／inbox 最终 S4＋T3 经完整独审后与这些共享文件精确合并；公开 Before 已重现缺口，完整相关 After 和新的 fresh mentions PG 已通过且未 skip。覆盖实际 typed roster、同 UUID 的不同类型、真实 parent/follow、receipt 只读、实际 reminders、不可消费历史 roster 的明确 503、formal eligibility、claim／receipt／BPR。此结果不是模型 PATCH reset、全门禁或生产资格。
- 前次完整提交门禁的 architecture 与 parity-check 通过，`make test` 因普通断言失败退出，未发生 signal 6／11。两个 quoted restart-mode 旧 golden 已按 pinned Node 的 `res.json(object)` 修正，保留精确字节断言并增加严格 JSON 对象断言。released-mobile builtin edit 的反例也已确认：原请求在裸组合返回 500，真实 PG／producer 返回 503；只补 fixture 无法修复。最终源码已从现有权威 runtime 记录读取状态，仅允许同 runtime、无 retained 执行／控制事实的窄 metadata 分支沿原 config lift 保存。其余 guard、Domain、active-reset coalescing 和既有错误路径原样保留，不新增拒绝。原 Mobile 测试及样本字节不变，修复后相关目标与独立 metadata PG 完整尾部通过，包括密钥身份／redaction、历史执行拒绝和真实 active coalescing／session publication；同一 Source 上的三个模型 PG 及旧 controls／config／human／conversation／builtin 复验也全部通过。前轮完整 `make test` 已通过；profile 平面响应适配采用后，下一次 E2E 暴露旧 `taskIds` 解码及不安全索引的确定性 SIG4。已按完整双 gate 契约矩阵收口公开 `{tasks}`／`{task}` 消费、实际帧接收与 EOF／error／取消／超时／连接清理，保持两个完整 profile 验证块。最终候选经作者全文回读和原唯一独审后已精确采用；最新实进程 E2E 完整两场景、smoke、architecture 与 parity-check 均通过，完整单元门禁也已通过，最终 Source 输入保持不变。真实 daemon 等待完整身份输出，标记后的 online 帧仍仅是本地观察位置，不当作 server epoch 或 OS 证据；新接收拒绝出口只有静态边界与正常完整帧运行证据，没有伪称故障 Before。
- 官方 Computer 已从固定源码的新导出实际完成规范构建，原始源码未变化；复制包保留完整运行依赖及 vendor 资源，所有剩余链接均在包内严格解析。复制的 Node runtime 已实际冷导入 Computer／Core／Codex 定义，正常 CLI sidecar 版本与固定 metadata 一致，复制前后 inventory 不变。这不代表真实 service／resident／Codex child 的最终角色已验收，也未执行新 provider。
- Web 使用已构建且逐字节核验的同一版本，保留上游 release identity 和 same-origin API。Main 没有静态服务，旧独立端口没有启动依赖；已改为现有 Caddy `file_server` 的不可变版本目录，不新增 Web server。两个新 profile 在同一镜像、UID、实际 capability 设置的临时 loopback 实例通过主／feedback SPA、静态资源、缺失与隐藏文件、缓存头、强 ETag／304、metrics 拒绝及保留 peer/header cohort 的 HTTP 验证。真实静态制品已复制到既有 gateway 的数据盘目录；实际浏览器、Computer HTTP、daemon HTTP 与 native WSS 到同一 Cloudflare origin 的出口已分别测得，WSS 诊断只证明该 transport 的出口，不当作 daemon101 或 enrollment。相同既有 gateway 已实际加载 restricted profile，真实浏览器显示正常登录页且未见 console error；本机无来源头、未列入 cohort 与不可信 peer 伪造成员头的九条路径全部503，metrics404，真实 Cloudflare 拒绝客户端伪造 connecting-IP。公共主／feedback HTML 的唯一解析差量是既有 Cloudflare 注入的单项 analytics beacon，其他节点／数据一致；十项脚本／样式／预载资源逐字节匹配，公开版本仍绑定实际 Main 构建。重复公共请求保持 private/no-store 与 DYNAMIC，origin 明确发送 CDN no-store；没有冒称另一个外部访客的实测。首次逐字节比对公共 HTML 未通过后已自动恢复维护，按完整 header／origin／Edge 变换路径查明原因，后续证据保留该边界。现有 restricted-canary phase 已通过，full-static 尚未发布。真实 owner 正常注册后仅一次发送尝试已获 Cloudflare 正向 recipient acceptance；真实到箱链接已由用户提供并通过正常 Web 消费，正常公共密码登录、邮箱验证及 profile 完成已获实际页面和公开 `me` 确认；没有从数据库提取内部 token 或手工改验证标志。profile 已完成的真实账号尚无 membership 时，必要的 server 空列表却返回401，整组身份／membership／fallback／创建及 onboarding 源码核对已完成，修复尚未实施。用户名可用性预检返回404，固定 Web 明确将其作为非阻断建议，最终提交仍由权威 Store 验证；不补造可用结果。完整正常 UI、enrollment 和生产模型尚待验收。已登录流程的 console 存在上述实际401／404，不能沿用 guest 登录页零错误的资格。

**当前模型路径验证**：六文件 owned reset 修复及完整 PG 回归已由同一独审者整组复核，并与 Core 的共享文件精确合并。三个独立 fresh-PG/public-HTTP 场景均已实际运行到尾且未 skip：canonical 新模型 PATCH 触发并完成 reset；正常 active no-op 保留真实未退出 process 的等待窗口，human POST 形成真实 held 消息，随后经受控 exit／automatic start／实际 delivery／ACK 完成释放与重放不重复；真实 pending-ready 下，已 written 的 public reset 经两次同值 session PATCH 只清 session／发布一次，保持原 operation、terminal generation、fence 与 stop，再由实际 ready 恢复正常 start。旧 controls／config／human／conversation／builtin 也通过。保留 Node 首次配置更改的两次 lift 与正常 start generation、旧 public reset 默认、manual／unexited／backoff 保护和 14-owner rollback。此处是服务器真实 HTTP／PG／NIO 与受控 daemon 协议资格；没有 stop ACK，也不把协议回执当作 OS cleanup 或官方 Codex／provider 接受。

**明确能力边界**：legacy machine-on-behalf attested-send 的 E1／freshness 仍为 partial；credential-route 测试不锁该旧 funnel。正常 CLI／官方 Computer 强制 credential v2，本批不伪造 legacy 成功。CLI threads list 所需未知历史 follow time／reason 不猜造，不用 last message 或 UUID 时间代替。active joint HUMAN 写入、物理 workspace 删除保持明确 503；未知旧 metadata、survey／handoff、owner intro 和 native TTL 不补造。通用文档预览保留下载回退，HTML 为独立路径。Share 的 local PNG 已验证；若配置非空 CDN base，URL shape 不代表已写入外部对象，部署配置必须与实际存储路径一致。

**下一批与完成条件**：

1. 交接矩阵批次已实现并通过完整提交门禁（见下方快照）。已部署的 `1c40` 制品仍在运行；下一步从该批次的干净提交重建并资格化 Main，再按维护顺序升级。保留 profile、canonical Task 消费、实际帧和全部拒绝边界，不把协议 context 或本地帧位置当作 OS／provider 成功。
2. 干净提交的 Main release、实际资源 bundle、Swift 与动态 JSC 的递归依赖、独立复制及普通 Main PID／映射已验证，四角色制品来源与完整 inventory 绑定也已通过。最终生产 Main user unit、private200、版本字段、native／realtime 与实际 PID／载入文件已通过；Computer／resident／Codex child、enrollment 与 provider 仍须以部署后的实际输出验证，不能以制品 metadata 替代。
3. 正常 Cindy onboarding、模型选择与实际执行、消息／Task／Computers／workspace／附件冷读和监督重启均使用同一已验证制品，在下述受限入口阶段完成。保留上游 Web、Computer 与 Node 各自正确来源，不把 Web 重标为 Swift 提交，也不把旧 stage 结果提升为最终验收。
4. 显式维护屏障已在任何生产 Main 启动之前实际加载，并证明公共入口全部503；全新生产 PostgreSQL 17／Redis、初始空数据与 schema 初始化已验证。最终 Main private200 后又复查相同 gateway 与全部本机／Cloudflare公共路径503，现有 owner-bootstrap phase 已通过。真实 owner 已通过正常注册创建，durable 验证邮件获 Cloudflare 正向 recipient acceptance，仅一次发送尝试；实际到箱链接已由用户提供，经正常公共密码登录与 Web 消费后，公开 `me` 确认邮箱验证和 profile 完成。不迁入 stage 合成账号、业务数据或 Computer 凭据。
5. 已加载审查后的新静态 restricted profile，实际浏览器登录页、Cloudflare peer/header 防伪、静态资源与缓存边界均已验证，现有 restricted-canary phase 通过。真实收件链接、正常公共密码登录和 profile 已完成，公开权威状态已确认。server 空列表401及连接合同已在源码修复并通过门禁；下一位从新干净提交重新资格化受影响 Main 制品并升级，保留现有真实账号、邮件验证、生产数据与 writer epoch。随后继续正常 first-server、enrollment、真实模型、实际 unit／PID、故障恢复和完整 Web canary，全部完成后才发布新的 full-static profile。完整公共入口仍未开放。

**批次快照（2026-11-10）**：交接矩阵的 coherent batch 已实现。公开 Before（归档红色回归，401 而非200 `[]`）已在原 Source 上重现，After 全部通过：canonical principal 的 server collection、setup 四路由（projection／transition／handoff／reset）的 pinned `requireServerMatchesParam` 前置作用域、新真实完成的 `normal` provenance、原 owner 的 postSetup 资格、PATCH me survey、`(serverId, originalOwnerId)` 首次 ack 与 account-global 首次 onboarding 事实、Auth AccountRow 与 Collaboration servers 两类严格 v1 快照。完整 `make test`、实进程 E2E、26 项 smoke、architecture、parity-check 均通过。新增 gated 真实 PG 验收（`RAFT_ONBOARDING_PG_ACCEPTANCE`）：全新 PG 上 register→verify→profile→200 `[]`（登录与 refresh）→survey→建 server→projection，经真实新可执行进程两次重启后字节一致。`scripts/upgrade-rehearsal.sh` 在一次性 PG／Redis 上以已部署 `1c40` 二进制写入真实账号与 server，再由新二进制读取：旧密码、旧 refresh、survey 字段为 null、server 列表、无 server 用户200 `[]`、重启保持，12 项全部 PASS。完成／handoff 在 PG 上没有受控 daemon peer 无法经公开路径到达，测试断言真实409 `OFFICIAL_ONBOARDING_AGENT_NOT_USABLE`，不伪造完成。

已知边界：上游 handoff 后的 owner onboarding briefing 已按 pinned 默认 opener-v2 路径落地（详见下方简报快照）：可见 opener 四条 agent 消息以 `agentSendKey` 幂等落入 owner 的 `onboarding-owner`／启用 `#all`，ledger 与 owner facts 以 seq 0 的 transient system notice 经既有 durable outbox 送达真实 daemon，sent stamp 只由 typed accepted receipt 写入；Team-Mode artifact／thread（本移植无 transfer-intent 存储投影）与 legacy instruction 路径（flag 显式关闭）仍为已知缺口，不伪造；mobile OAuth completion、register、login、me、PATCH me、complete-profile、avatar 与 app-login 的 `user` 已统一为 `toPublicUser` 全量投影（成员顺序、null、`description`、四项 observed timezone 与由 mode 派生的 `autoTranslationEnabled`），mobile callback 也会把已绑定 provider 的既有账号写进完成事务。其余57个 `/api/servers/:id/...` 路由尚未接入 pinned 前置作用域（非 UUID／缺 header／错 header 的状态与上游不同），各 handler 自身仍校验 membership，正常 Web 路径不受影响，留作后续切片。新二进制在 SIGTERM 恰逢或紧随事务邮件投递时的 Foundation `_MultiHandle` 释放 SIGABRT（134）已定位为 pinned FoundationNetworking 6.4 的既有释放竞态：修复前同一生产模式可执行验收 20 次中 8 次退出 134（信号 6，打印 `non-zero retain count 2`）；修复后 20/20 退出 0，outbox 保持未投递可重试。修复采用进程生命周期内保留已用 `URLSession`、先停接单再取消在途 HTTP、最后等待已开始的 PG 操作，未改动 durable outbox 语义。升级前仍须以该验收与 upgrade rehearsal 复核。

**生产升级快照（2026-11-10）**：Main 已从干净提交 `f70d6a3`（含 onboarding 批次与事务邮件 shutdown 修复）按 release-tools 构建、暂存并以既有 launcher `verify_release` 资格化：运行时闭包与 `1c40` 逐字节一致，独立冷启动 /livez200、/health503、版本字段、映射仅含暂存文件与四个 host 库、SIGTERM 退出0。维护顺序为 pg_dump 备份 → closed-all → 停旧 unit（exit0）→ 换 manifest／launch spec（保留旧副本可回滚）→ 真实 user unit 启动 → 私有验证 → 恢复 restricted。私有 health200、版本 `f70d6a3`、PID 映射62个 release 文件加 host 库；writer epoch 2→3（正常 fencing），14个 domain row 中仅 auth 账号新增四个 null 字段、servers 新增空 setupCompletion 组，其余 payload 不变；真实 owner 登录与 refresh 后 `GET /api/servers` 均为200 `[]`。restricted operator cohort 已按用户批准从单个会过期的临时 IPv6 改为该网络 /64 前缀，并加入用户指定的四个地址；cloudflared remote_ip 约束与其余配置不变。官方 Web 自动建议的 slug `raft` 少于上游5字符下限（Swift 与上游同为400），首个 server 按用户选择使用 slug `myoland`。下一步：正常 Web 创建首个 server、官方 Computer enrollment、Cindy onboarding、真实模型／Task、冷读、重启恢复与完整 Web 验收，全部通过后才发布 full-static。

**首个 server 与 enrollment 快照（2026-11-10）**：正常 Web 以真实 owner 创建首个 server（name `Raft`，slug `myoland`，POST /api/servers 200）。官方 Computer 1.0.49 经公开设备页完成正常 device login，`setup myoland --no-start --yes` 成功；computer launch spec 绑定 Computer release `db5e399`、`start /myoland`、requiredMainCommit `f70d6a3` 并把 Codex 所在目录加入 PATH（原 spec 已备份），真实 systemd user unit 已 enable 并运行，service／runner／Codex 0.167.0 app-server child 均在，Main 侧 machine online、Codex 可用。setup-projection 依次为 computer_offline → create_agent（official_onboarding_agent_missing）→ 正常创建官方 onboarding agent Cindy（codex，`gpt-6.1-sol`）后 setup-transition 200 → `complete`，postSetup 为 surveyPending／handoffPending 均 true。已登录 Web 的可选404（product-feedback/tickets、joint-invites、push prompt-events、billing/subscription）为未实现的可选能力，Web 容忍。待观察：Cindy 空闲时 presence 为 inactive／offline。materialize 的 finalize-computer 资格 spec 仍固定旧 requiredMainCommit 且缺 Codex PATH，下次 release 工具更新时一并修正。下一步：survey、handoff、真实模型消息、channel mention、Task、附件与冷读，然后 Main／Computer 重启与故障恢复、完整 Web 验收。

**对话阶段与实时修复快照（2026-11-10）**：正常 Web 完成 survey（PATCH me 200，signupRole founder，surveyPending false）与 handoff（setup-handoff 200，handoffPending false；当时本移植尚无 Cindy briefing 服务，未伪造，现已在简报快照中补齐）。Cindy DM 由真实 Codex 在30秒内回复，Computer runner 记录 agent:start／deliver／outcome ack。验收暴露两个真实偏差并已修复：(1) NIO socket 监听器未发送 Engine.IO v4 服务端 ping，官方 Web 每约45秒 ping timeout 重连并丢失期间事件；现按 engine.io 6.6.11 由服务端每 pingInterval 发 `2`、收 `3`、超时走正常断开清理，客户端 `2` 按无效心跳方向关闭；另补上游每15秒的应用层 `heartbeat {seq,ts}`（Web 据此做 seq 缺口同步与断路器），seq 取既有消息 seq，不新增计数器；上游未开启 connectionStateRecovery。(2) /daemon/connect 把官方 Computer 发送的 agent:status／agent:activity 当作 malformed 丢弃，且从不推送 agent:activity、GET /api/agents 缺省 offline；现按上游 reducer 规则持久化 status、按 canonical detailKind 记录 activity 并推送，列表在无记录时对 active 且机器可达的 agent 报 online。两项均先写失败测试，组合树通过完整 make test、E2E、smoke、architecture、parity-check 后提交 `31ae625`、`be903bd` 并 push；Main 已按同一维护顺序升级到 `be903bd`（pg_dump、closed-all、swap、私有验证、restricted 恢复），writer epoch 3→4，Computer 自动重连且 unit 未重启。已知有界缺口：status 的 clientSeq／daemon-instance 排序、ready.runningAgents 对账、断线时 offline activity、activity trajectory 持久化、内部 agent serverInfo 固定 status active。下一步：实时回复、channel mention、Task、附件、workspace 冷读与各页面 console 审计，然后重启与故障恢复。

**Owner onboarding briefing 快照（2026-11-11）**：上游 owner onboarding briefing 已按 pinned 默认 opener-v2 路径实现。新增 transient agent notice 原语：新 `.notice` command kind 走既有 `agent.execution` durable outbox／machine registry，`seq: 0`、无 `messages` 行、无 `message:new`、typed `accepted`/`dropped` receipt；admission 要求 durable transaction、绑定 machine online/ready、agent active 与 daemon 已准入的 live launch，绝不为死 agent 冷启动，dropped 不标 rollback-only。wire 形状与 pinned Computer 一致（`agent:deliver`、system sender、synthetic `message_id`、无 message `seq`、envelope seq 0，Computer 以 ackSeq 0 回执）；ingress 以真实 seq-0 ack 结算，notice 丢失/错 seq 不会把 agent 置 manual，Agents 快照校验接受 seq-0 notice dispatch。`OnboardingBriefingService` 按上游顺序实现 gates（server／primary owner／configured onboarding agent／opener flag／survey／member prefs／未 sent／stale pointer self-heal／agent active）、5 分钟 claim lease、只由 typed accepted receipt 写入的 sent stamp、`onboarding-owner` 或启用 `#all` 中四条 `agentSendKey` 幂等 visible opener、ledger transient wake 与每次 ready 重发的 owner facts。触发点：`POST setup-handoff`（durable ack 后，best-effort）、`PATCH /api/auth/me {signupSurveyServerId}`（trigger-only、不持久化／不回显、仅 primary owner）、ready frame（ready commit 后的 detached task，`machine:online` 的移植等价物）。temporary fixture 无 durable writer 时 notice 返回 dropped、不伪造 stamp。red→green：briefing service gates／claim／文本／幂等与 notice admission／materialize／seq-0 receipt／snapshot 单测；真实 `POST setup-handoff` 与 `PATCH me` 的 HTTP 回归；真实认证 `/daemon/connect` TCP/WebSocket peer 的 notice frame＋真实 ack。另按既有 gated 模式尝试了真实 HTTP／PG／outbox／daemon peer 验收：两次实际跑到尾（idle active agent handoff 只发 visible opener、ledger dropped 不 stamp；survey-save 重试送达 seq-0 ledger 并 stamp；后续 ready 只重发 facts；chat 无 briefing 文本），但该 fixture 在同一竞争负载下重复出现挂起，未作为本批验收落地（测试文件已撤回，约束记录在此）。已知缺口：Team-Mode HTML artifact／thread 因本移植无 transfer-intent／attachment-projection 存储路径而延迟（四条 opener 仍发、ledger 省略上游条件行）；legacy instruction 路径（flag 显式关闭时）只返回 `openerDisabled` 不发送旧文案；hosted Cindy 与 Day-2 recap 不在本切片。生产后果：真实 owner 的 survey 与 handoff 都发生在本功能之前，两个 sent stamp 均为 null；部署后下一次 Computer ready／machine online 会触发同一幂等流程，补发 visible opener（该 server 无 `onboarding-owner` channel，落在启用 `#all`）、owner facts 与 ledger，无需专门 backfill；handoff 的 durable ack 不会被重写。
本批最终树门禁：完整 `make test` 通过（1582 tests，另 615 tests 仅有既有 known issue，无 failure），`make test-e2e` 通过（37 tests，两个独立 `RaftServer` 进程），`./scripts/smoke-server.sh` PASS 26 项，`check_architecture.py` PASS，`parity.py --check` PASS；新增内容字面测试 `OnboardingBriefingContentTests` 由 pinned 上游函数实际运行结果生成并在最终树聚焦通过（该文件在完整 `make test` 启动后加入，故完整套件未包含它；生产 Source 无差异）。opener-v2 的 notice admission／gates／文本／幂等／snapshot 行为均由上述 published-path 与聚焦测试锁定。

| 连接合同 | 实际消费者／生产位置 | 下一批必须保留或补齐的事实与边界 |
| --- | --- | --- |
| collection 身份与空列表 | Web `ServerSelector`／`serverStore` → `ServersFeature` → `ServerProfileAndOrderService`／`PublicVisitDirectory` | OAuth 非空成员列表优先；其后以既有 Auth 权威 principal 读取实际 legacy membership 投影，没有成员则200裸 `[]`。不再次用另一个 domain 的 bearer 映射选择 subject；锁定正常登录／refresh 无需 legacy token 注入、同 bearer 不同 subject 不泄露、已有 legacy／guest 投影及匿名拒绝。collection GET／POST／order 保持 user scope，不强加 tenant header。 |
| setup 路由前置作用域 | GET setup-projection、POST setup-transition／setup-handoff → 既有 `ServerScope` | 按 pinned mount 顺序核对 UUID、header 与 live membership：非 UUID404；合法 UUID 缺／错 header400；正确 header 但无 live membership403，再到 handler。projection 的 guest 公开请求403，不能把 service 的 `none` 当 guest HTTP 成功；member／admin 的非阻塞投影另行保留。 |
| 新真实完成与 legacy | `ServerSetupProjectionService`／`JoinLinksAndInvitesService` → 现有 setup phase owner | 新真正完成时在同一事务保存 `normal` completion reason；仅读兼容 `complete_after_defer`。旧 complete 缺 reason 保留 unknown，不能补 normal／now。terminal 重试不改原因、不重开，也不因电脑离线撤销已完成。跨 owner 继承完成不制造个人任务。 |
| survey／个人投影 | Web `ServerSetupSurveyStep` → PATCH／GET auth me → Auth Profile／Account | 只有已保留 `normal` 或兼容 `complete_after_defer` 完成事实且 actor 等于 server 原 owner 才 eligible，随后分别读取实际 survey 与 member ack。加入 nullable signupRole／signupSurveyCompletedAt 的 request、校验、原子保存、GET／PATCH 响应及持久化；role absent 不动，explicit null 合法且记录本次时间，非法 ID／类型400且 survey／referral 不部分写，保留原密码变更顺序。不能从 emailVerified／profile 完成或缺字段推断 survey 已答，也不按构建／注册时间把后续真实新完成判成 legacy。 |
| handoff 与原 owner | Web handoff → POST setup-handoff → 既有 membership／Account owner | 必须是 `server.ownerId`，coowner 不能仅凭 role owner 越权。保存明确 member subject 的实际首次 ack，重复保留首时；同时只首次保存 account-global onboarding 时间与实际 session family（无真实 family 则 null）。先 durable ack，briefing best-effort，不把点击记成模型送达。旧无 subject 的 Set marker 不迁移成新 receipt。 |
| 两类严格快照 | Auth AccountRow 与 Collaboration server snapshot capture／DTO／codec／restore | 在现有 owner 内贯通新字段与 completion／ack，不新增 owner／cache／SQL schema。旧 v1 缺整组新字段时只迁移为 unknown／nil／空记录；原 required keys 仍严格，新组只缺一部分／坏类型／坏 Date 必须拒绝且不部分 restore。保留各自精确 Date 编码，不全局改 decodeIfPresent／空表回退或只抬 version 常量。 |
| 可选分支与浏览器事实 | onboarding opener／hosted Cindy flags、display style、用户名预检 | opener 关闭时真实 `all` fallback 有效，不强加 private owner-channel；hosted provider 是可选分支，不补 fake ready。display style 完全 browser-local，不新增 server 完成字段。用户名 available404 是非阻断建议，不返回伪造可用。已有显示名按正常页面保留，无产品修复。 |

必须增加的验证包括：真正完成前后 postSetup 两项变化；原 owner 答 survey 后跨 server 不重复问；各 server handoff 独立；coowner／admin／member／guest 拒绝及无写入；首次 ack／global 时间／family 幂等；legacy／继承／terminal 不补历史；合成快照导出恢复到全新 Store／App 后公开状态一致，以及旧完整 v1、缺组、半组、坏日期／原键的严格拒绝。受控 daemon facts 的测试不等于官方 provider 接受。全部修复稳定后跑本仓库完整提交门禁，提交 push 干净代码，重建并重新资格化受影响 Main 制品；保留真实 owner、已验证邮箱、profile、session、PG 数据与当前 writer epoch。恢复受限服务后才继续正常 first-server／Cindy、官方 enrollment、真实模型、重启恢复与 full-static 公共 canary。

**目标更新纪律**：用户改变方向、代码审查改变范围或顺序、门禁失败及里程碑验证后，当轮同步本计划、任务清单和持久化 session goal，替换过期结论；不等待用户催问或上下文压缩。

## 1. 行为覆盖与已完成阶段

`make parity` / `make parity-check`：**406 个模块纳入账本，405 locked、1 partial**。legacy machine-on-behalf attested-send 的限定见上节。

| 区域 | 模块 | 用例 |
| --- | --- | --- |
| Route | `218 locked + 1 partial / 219 tracked` | `1975 / 2000`（98.8%） |
| Socket | `7 / 7` | `16 / 16`（100.0%） |
| Daemon | `180 / 180` | `2616 / 2616`（含账本中注明的排除项） |

Daemon 的 2616 条账本用例包含 Node 运行时、进程管理和外部集成轨道；约 1130 条已在 `docs/PARITY.tsv` 注明排除，便携可执行口径约 616 条。报告进度须保留这些资格说明，不能把账本总量当作实际执行量。

Phases 0–4 的真实进程闭环已建立：`make test-e2e` 启动两个隔离的 `RaftServer` 和一个 `RaftDaemon`；`scripts/smoke-server.sh` 检查真实端口上的注册、验证邮件、建服建频道、人类与 Agent 消息、Socket.IO 和 `/daemon/connect`。26 项 smoke 是接线检查，不单独证明全部 parity 模块。

Phase 5 已完成旧 `EmailLogin/` 文件提取、Feature 路由拆分、同步 body 读取退役和生产 `ForTesting` 入口迁移。`EmailLogin.swift` 从 34,306 行降到 48 行，原目录中不再有 Swift 文件。测试 seam 位于不被生产 target 依赖的 `Tests/TestSupport`。

这些结果不代表深度架构重构已经完成：字段转发和目录全局锁已删除，旧类型在其他目录仍有工厂扩展、构造调用和测试 API。Store/OAuth 的 checked 隔离与消息 owner 事务已完成，最终显式 Service 装配仍需迁移。Phase 6 是分层债务计划，受上节当前交付目标约束；精确分层、检测范围和数值快照只在 `docs/ARCHITECTURE.md` 维护。

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
2. **共享纯装配首场景已建立**：17 行 ServiceContainer 只持九组 63 个具体 Service/Support 值；共享 composer 无参时分配十三个 actual owner，显式入口十三参数全必填，无 Store bag、Root-taking bridge、别名或缓存策略。AuthScene 的私有 Auth/Invite fixture 与实际七服务 AuthFeature 使用同一 composer/owner 图，注册后配置仍活读。完整 Fallback/main 与未迁 fixtures 仍用原 Root；整体切换须等全部 Feature/raw-ledger/transport 依赖和 HTTP 场景同步，不能混接两个 graph。保留 fixed-user-Hub/live-general-relay 作用域、published/silent/custom publisher 明确变体，以及生产 Cards 真实幂等 port 与 fixture 特殊 port 的区别。
3. **Feature 与 fixture 迁移未完成**：Reminder delivery 两个 POST 已返回 typed completion，Feature 仅向固定可选 Hub 发原帧。G2 installation credential、G3 app-initiated agent request 与 G4 resource-bound agent event 已归 IntegrationsAndAppAccessService。OAuth owner 接 typed attempt、回领域 outcome/facts，保 mint/GET 锁边界、app request 单事务与 event principal验证/claim/append 同锁；旧 event payload/hash/expiry 与原兼容接受集保持。G7 metadata/shared resolver已归独立OAuthIssuerMetadataService：六metadata与八scope保原liveURL/key/row独立门槛和错误/cache/协议时点，旧owner JWKS与死scopehelper已删。G7当时新增第61字段的13locals同owner runtime proof已过，未冒称完整新Fallback。G5授权跳转、human authorize、consent及两grant协议已归独立OAuthAuthorizationService：specialized oauthSession仅raw Bearer/drop7/known account，保unverified与revokedfamily接受；begin在body前不throw，四typedowner事务保原RNG/Date/拒绝顺序，消费后才独立key/openid签名。identity.authorization当时新增为第62字段并有实际13owner/P256验签/快照与live事实证明，旧HTTP owner API和旧session入口已删。G6 principal projection也已归OAuthPrincipalService：三publicmethod先读raw live URL再bearer，三个owner各保完整原事务/独立资格/flatfacts，旧U/S/A HTTP owner入口删除。第63字段通过13actual mandatory composer+同图G5mint/profiles配置与OAuth真实事实变化证明，覆盖U/S/A、disabled与request删除差异；不冒称完整Fallback或全63fields方法证明。G2–G7 raw-ledger Feature迁移闭合。InstallationScene 已将私有 Auth/InstallationFixture、同 owner shared composer 与三路由真实 production registrar 接通；原 Features 在原位置委托，另保完整旧 Fallback 接线回归。OAuthScene五批已把OAuthFeature五服务与IntegrationsFeature七服务改为显式参数，在原Fallback注册点供同owner旧图服务；focused app从十三actual owner的shared composer供值并组合private Auth/OAuth fixture，五批共30HTTPfile（20OAuth前缀HTTP+9OIDC+FeatureOAuthRoutes；前三批15+12+11处挂载，事件/并发批保16focused与7bareOAuth/1bareIntegrations原子集，应用末批六file七挂载），原断言/参数/并发保。Pixel实际handler提为共用production registrar，Notifications原点委托；额外FeatureIntegrations只迁同Root七参数ctor。OAuthFlowsServiceTests的十二函数另迁local privateprofile/flags与同十三owner服务+internalStore subject，counterspy改实际24typedcallback receipts；旧EmailLoginTests另迁39非Native函数/458断言到同profile Auth/Mobile fixtures，三counterspy替公开拒绝观察并删unusedgetter，Native5另迁同图纯同步provider输入/公开响应，三旧observer删、原103公开事实保，此Auth测试file已无Root；Core/Identities/Profile三Unit file另迁localprivate13图/36typedops，同owner自定义clock/token与211expect5require保，2累计counter改真实tokenrecords，30Root-derived迁/5既有pure图tests不动；剩余verification累计counter另按全repo审计退privatefield/2++/compat与2testgetter，3HTTP+1Store中5assert改storedrecord/hash身份，真实ledger/IssueDates全保；Source/Tests两旧name0，历史docs不冒全仓spyclean。其他领域fixtures仍未完成，unit/Auth资格不扩大HTTP30 inventory或生产Root完成。当前唯一主线是四阻塞能力→Feature具体服务入口及必需HTTP场景→同图Fallback/main/transport同步cutover→阻止删除的测试调用方迁清→Root/六扩展/兼容入口删除；无关unit扫尾、额外旧合同矩阵及剩余daemon小片不打断它。四个生产阻塞能力现已闭合：task42的push平面target/startup严格Bool已接Main/Notifications，task43的Threads/Assignments仅换publisher且保同owner/customnow，真实TCP/帧、定向、首次full及全部门禁通过。ChannelsFeature现已改为15具体Service与显式可选Hub，ChannelsScene用同13owner图/privateOAuth+Messages窄fixture接真实54路由，保customThreads/silentAssignments及原headers/body/副作用顺序。下一直接推进剩余11个Root-bearing Feature+Fallback/Main共13个核心生产文件的同步同图切换，两个Ledger adapter已有concrete leaves；同时迁移真正阻止新构造编译的seeded HTTP调用方/共享fixture，禁止Root→Container桥与双图，不逐Feature再做scene/矩阵。完成生产切图后迁清Root类型删除必需的剩余unit调用方，再删Root/六factory扩展/兼容入口；当前仍不能宣称生产构造切换完成。新图定向与原完整Fallback回归均绿，未在同app混Root+新图。下一片继续迁剩余OAuth场景，随后收窄family-target/read-observer/publisher variants并完成其余领域scene与完整Fallback/main/transport切换。Fixture 使用实际 owner、shared composer 和专属领域操作，不能造改名 TestRoot/global facade。最终删除旧类型、Root 工厂/helper 扩展及所有兼容构造器/别名；只删名字或缩行不算完成。
4. **已完成非 daemon unchecked 清理**：完整服务端依赖闭包与 Generated 均为零，guard 包含生成代码；恢复可复现的 knowledge 生成脚本及 template，`--check` 不改变固定语料。NIO 局部非 Sendable handler 通过 SDK loop-bound 值限定安装与访问，不以新 unchecked 壳替代。
5. daemon-only 原 41 处已逐项评估。六个不可变错误、child guard lifecycle、HTTP completion/loop timer、四个可变模型及 notification/Janitor timer、immutable activity sink、progress clock、actor-owned probe results、immutable managed MCP tool 与 reminder/delivery关联集合及StandingPrompt锁外clock、两个private completion gate及完整turn-token fold/count及turn-summary归属及Kimi lock-handle状态、WalkBudget内部消费、FetchPool缓存及ModelLister Task及native deadline scheduler所有权及daemon upgrade handler NIO confinement及AgentStartCoordinator值状态及RuntimeModelSourceCache时钟/值状态、DaemonLog回调/退役与DaemonReconnectLoop策略调用所有权及ProcessMemory.Reporter锁外sampling/clock/timer token-handoff已迁移，余 3 处见 `docs/CONCURRENCY.md`。child timer、并发 Probe 快照、Data 释放、notification、Janitor及StandingPrompt clock均有各自红→绿证据。StandingPrompt mkdir与commit两IO段之间无锁采clock，保每次步骤/原文件格式和last-actual-commit，不新增重叠clock全局串行或timestamp单调；原4绿/新3文件断言红，v2五例全绿。Janitor 的公开 Timers seam 确定性交错证明 stop/register/rearm 与不重叠 pass，原磁盘策略、已准入 pass 保活与 pending 弱引用保持；notification 另有一次真实默认 timer。这些证据不是 stdin/socket 或 TSan；HTTP 跨队列问题的原证据是源码审查。Reporter sample内publicstop旧started124→新真实sampleFileJSON/原6+新1通过；强identity slot仅保护schedule返回ID的发布，不过滤tick/admitted输出，stop仍非drain。剩余 raw Any 和 storage 能力仍需收窄，不能因 daemon-only 而判为安全。
6. 如实同步文档，再跑最终完整门禁。只在所有目标确实完成后宣布 Phase 6 结束。

## Production storage foundation

The isolated `RaftObjectStorage` adapter uses Soto/SotoCore 7.17 and swift-crypto AES-GCM. Local network acceptance covers ciphertext, tampering, roundtrip and deletion; live acceptance uses a separate prefix with existing credentials. Native HTTP binding, retained attachment references, official Computer/Codex execution and bounded application recovery have since been exercised. Final clean-release qualification, the complete Web delivery path and production activation remain open under section 0. Phase 6 and all existing parity qualifications remain open.

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

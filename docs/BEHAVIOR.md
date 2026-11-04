# Raft Server Swift — Locked Behavior Reference

This file is the historical locked-behavior log moved out of README.md.

# raft-server-swift

等价复刻 [raft-source](https://github.com/botiverse/raft-source) `v1.21.23-source.1` 的 server 与 daemon。

规格是现有测试里对外可见的行为。Swift 测试先写这些断言，再写实现。Node 测试断言的行为优先，直到那条行为本身被改掉。

工具链：`/mnt/data/opt/swift-6.4.1-RELEASE-ubuntu26.04`（Swift 6.4.1）。系统的 `/usr/bin/swift` 仍是 6.1.3，本仓库用 `make test`。

当前切片：`/daemon/connect` 和只读 HTTP。鉴权决策在 `RaftConnectAuth`，SwiftNIO 监听在 `RaftMachineSocket`。拒绝时写出和 Node 相同的 401/500 字节；接受时回 101、`raft-server-capabilities`，再发一帧 `machine:context`。`RaftDaemonClient` 按 `packages/daemon/src/connection.ts` 完成客户端握手：默认 `Authorization: Bearer`，也可走旧的 `?key=`；拒绝时交出状态码和 `Slock-Reason`，错误文本不含 api key；101 时读能力头和第一帧 `machine:context`。`DaemonLink` 是同一处的重连循环，由调用方推进时钟，不打开套接字：退避从 1s 加倍到 30s，成功打开后回到起点；默认抖动铺在至少 5s 的窗口上；4003 的重复连接等 5 分钟，被关掉后的 30 分钟内再次被拒仍走长延迟；401 `legacy_machine_key_migrated` 停止重试；入站看门狗 70s 先发 `ping`，再过 70s 才断开。断线期间每个 agent 只留最新的 `agent:activity`、`agent:status` 和 `agent:session:invalidate`：失效帧在重新打开时先写出，status 和 activity 等这根套接字上的 `ready` 之后按 `clientSeq` 重放。连接时会记下 `wss` 地址、Bearer 头，以及 `HTTP(S)_PROXY` / `NO_PROXY` 选出的代理 URL。同一个代理 URL 复用一个 fetch 连接池，传输失败才丢掉它，4xx 和 5xx 保留它。预响应超时默认 30s，同时作为 connect 和 headers 超时。出站 fetch 会打开 HTTP CONNECT 隧道：HTTPS 上 `200 Connection Established` 之后若对端一直沉默，原因是 `UND_ERR_CONNECT_TIMEOUT`；隧道已通但源站不写响应头，原因是 `UND_ERR_HEADERS_TIMEOUT`。响应头到达之后，这个超时不再切断响应体。

`RaftHTTP` 按 `app.ts` 给出 `/robots.txt`、`/livez`、`/health`、`GET /api/version` 和 JSON 404，这些响应都带 `X-Robots-Tag: noindex, nofollow`。未捕获的路由异常回 500 `internal_server_error`，带 `X-Slock-Error-Id`，正文不包含抛出的查询文本；`RisingWaveOverloadedError`（含 cause 链前五层）回 503 `rw_overloaded` 和 `Retry-After: 2`。路由自己写出的状态不会被改写。`/api/app-admin/me` 不存在，走 JSON 404。`GET /api/desktop-download?target=` 按 Latest 的 electron-builder feed 302 到安装包；没有 target 时去 web 的 `/download`，不看 User-Agent；没有构建或 GitHub 失败时去该仓库的 `/latest`。`GET /api/desktop-download/platforms` 公开返回各平台是否可下。`GET /api/public/feature-flags` 在登录前回答，只看标成 pre-auth 的旗标的 kill switch、enabled、platform 规则和默认值；别的 key 都是 false，凭证不影响结果，`Cache-Control` 是 `public, max-age=60`。`/api/public/search` 只接受 GET 和 HEAD，其它方法在查找前回 405，`Allow: GET, HEAD`，`Cache-Control: no-store`。索引开关关闭时 `/index` 是空列表，server、channel、thread 页面是不带 `path` 的 404。开关打开后，可搜索的公开频道和至少有一条回复的线程以公开 id 和展示字段出现在这三个页面和 `/index` 里，内部 id 和邮箱不出现；超过 50 条回复会截断。所有者把服务器设为公开时会补上缺失的公开 id，搜索默认开启；管理员不能读也不能改公开开关，公开服务器的总开关关掉时，所有者读和写公开开关都是 404，匿名页和不存在的 slug 是同一段正文，被拒绝的写入不会改掉已经存下的 `publiclyVisible`。公开翻译 `POST /api/public/servers/:slug/message-translations:batch` 有单独的每分钟 120 次 IP 限额：空请求先回 400 `Invalid public translation request`，第 121 次回 429 `Too many public translation requests, please slow down`。合法请求在服务器未公开、翻译关掉或没有翻译服务时是 404；LLM 翻译不可用时是 403；通过后未知消息是 `not_found` 结果。`POST /api/auth/login` 在邮箱或密码不是非空字符串时回 400 `email_login_body_invalid`，`issues` 标出该字段。未知邮箱和错误密码都是同一段 401 `AUTH_INVALID_CREDENTIALS` / `Invalid email or password`，并且不签发会话；密码正确才回 200，带 `accessToken` 和 `refreshToken`。`GET /api/auth/me` 要这个 access token：没有 `Bearer` 是 401 `Missing or invalid Authorization header`，无效 token 是 401 `Invalid or expired token`，两者 `code` 都是 `auth_required`。通过后 `gravatarHash` 是邮箱 trim 再小写后的 SHA-256。`PATCH /api/auth/me` 用错当前密码时回 401 `AUTH_CURRENT_PASSWORD_INCORRECT` / `Current password is incorrect`，密码保持原样。显示语言只接受界面能渲染的目录：`zh-Hans` 存成 `zh-cn`，`en-US` 存成 `en`，`fr-FR` 和 `zh-TW` 是 400 且不改已保存的值，`null` 清空。`POST /api/auth/register` 的 email、password 或 name 如果不是字符串，是 400 `email_register_body_invalid`，`issues` 标出该字段，不建账户、不写协议、不开发会话。带 `stagingSelfAccountCapability` 时，`SLOCK_RELEASE_BRANCH` 不是 `staging` 或邮箱不是 `@mail.build`，注册是 403 `Staging self-account registration is unavailable`，不建账户。在 staging 上注册会记下能力的 SHA-256。`POST /api/auth/staging-self-account/retire` 只接受本人：别人的 id 是 403 `User ownership mismatch`，能力不对或账户没有这份能力是 403 `Invalid retirement capability`，这两种都不写收据。成功后回同一张收据，正文不含邮箱和 refresh token，会话被删掉，session family 标上 `revokedAt`。再调一次仍是同一张收据。之后密码登录、refresh 和旧 access token 的 `GET /api/auth/me` 都是 401。`POST /api/auth/device/authorize` 默认开着：`SLOCK_DEVICE_LOGIN_ENABLED` 为 `false`、`0`、`no` 或 `off` 时是 404，空串和 `true` 仍是 201。没有 `APP_URL` 是 503 `DEVICE_LOGIN_URL_UNAVAILABLE`。批准前轮询是 400 `authorization_pending`，没有 Bearer 的 approve 是 401。批准后 token 回这个用户的 access token 和 refresh token，再用是 410 `device_code_consumed`。`approve: false` 之后 token 是 403 `access_denied`。未知 device code 是 400 `device_code_invalid`，未知 user code 是 404 `user_code_invalid`。`GET /api/mobile-download` 不需要登录。`platform=android` 跟 Hands `latest` 里的 APK，AAB 在前也一样，302 到签名地址，`Cache-Control` 不超过 300 秒。只有 AAB 是 404 `no_installable_build`，不跳转。Hands 的 `no_active_release` 是 404 `No build available yet`；`app_not_found`、没有 `code`、或者这个平台没有产物，是 502 `not_configured`；上游失败是 502 `upstream_error`。没有 platform 时 Android 的 User-Agent 仍去 APK，iPhone 和旧 iPad 去 TestFlight，不跟 Hands 的 `.ipa`。现代 iPad 和 Mac 的 User-Agent 302 到 `APP_URL` 的 `/download`，尾部斜杠不会叠成两段。`/api/feature-flags/admin/flags` 的读写、kill switch 和规则路径都没有挂上，带 Bearer 也是 JSON 404。`POST /api/feature-flags/evaluate` 仍在：已验证的用户交上空的 `keys` 是 400 `keys must contain 1-50 valid feature flag keys`，不是 404。已登录的 `POST /api/messages` 在 `channelId` 不是字符串、`attachmentIds` 里有非 UUID、或 `asTask` 不是布尔时，是 400 `Invalid message request body`，不写消息。没有 Bearer 仍是 401。这个服务器打开了 Computer 和 App 引用、但没有安装 `custom.missing` 时，正文里的 `<app:custom.missing>` 是 400 `App reference is not installed in this server`，消息不会留下。这个开关关掉时，`<app:system.reminder>` 是 400 `Computer and App references are not enabled in this server`，同样不写消息。同一个 `randomId` 先写进一个频道后，再拿到另一个频道是 409 `random_id_conflict`，错误正文不含原来的私密内容，第二个频道也不会留下这条消息。`attachmentIds` 的顺序会原样出现在发送回执、`channel:{id}` 上的 `message:new`，以及 `GET /api/messages/channel/:channelId` 的冷读里，并写成 `messagePosition` 0、1，不按上传时间重排。同一个 `randomId` 重放时，只有附件 id 的顺序和已提交的完全一致才回 200 且是同一条消息；顺序反过来是 400 `attachment_replay_conflict`，换一个 `randomId` 再带上这些已挂上的附件是 400 `attachment_already_linked`，频道里仍只有第一条消息，`messagePosition` 仍是 0、1。同一请求里附件 id 出现两次是 400 `attachment_duplicate`，缺失的 UUID 或别人上传的附件是 400 `attachment_not_found`，消息不会留下，这两条附件的 `messageId` 和 `messagePosition` 仍是空。`randomId` 写成内部哨兵文本 `invalid` 时仍是 200，回执里的 `randomId` 就是这个字符串。联合频道的短链预览走调用方服务器上的本地投影：本地频道成员用这个 `channelId` 和 8 位短 id 能读到存在宿主频道上的消息，回执 `channelId` 是本地投影，`targetMessageId` 仍是原消息；不是这个本地频道成员的人是 404，正文不含那条内容。同一条短链如果指向宿主线程里的回复，回执 `channelId` 改成调用方的本地线程投影，`canonicalTarget` 的 `kind` 是 `thread`，`channelId` 是本地父频道，`threadChannelId` 是本地线程，`threadParentMessageId` 是父消息；直接用本地线程 id 再查一次，也是这条回复。给一条消息加 `👍` 回 200，`reactions` 的 count 是 1，`reactorIds` 是本人，`reactorNames` 是 `reaction-owner`；再加一次次数仍是 1，`GET /api/messages/channel/:channelId` 读到的也是 1。删掉同一表情后 `reactions` 是空数组，这一行也不再留下。`X-Server-Id` 指着另一台服务器时，往这个频道发消息是 404，正文里的内容不会写进该频道。点到还没加入频道的 agent 和用户时，发送回执是 `message` 加 `pendingMentionActions`，`message` 自己不带这个字段。两条动作的 `reason` 是 `not_member`，`availableActions` 是 `notify` 和 `add`，`targetHandle` 是提及里的名字，agent 带头像，用户头像是 null。频道列表里的这条消息不带这些动作。公开频道上这种非成员提及会留下行，但 `notifiableAtSend` 是 false，也没有通知；收件箱事实和 agent 投递都是空的。该 agent 用带 `mentions` 范围的 key 调 `GET /internal/agent-api/mentions` 是 200，列表里没有这条消息。私信里点到对话双方以外的人和 agent，回执仍是消息本身，没有 `pendingMentionActions`，也没有 `mentions`。提及行同样 `notifiableAtSend` 为 false。局外人的 `GET /api/channels/inbox?filter=mentions` 是 200，条目里没有这条私信，agent 的 mentions 列表也没有。`POST /api/v2/messages` 发到已停止 agent 的私信仍是 200，`message.content` 是原文，`deliveryWarnings` 有一条 `targetType` 为 `agent`、`reason` 为 `agent_stopped`。这次投递记在该 agent 上，频道类型是 `dm`。`POST /api/messages/mention-actions/execute` 的 `notify` 只认原发送者：别人是 200 且 `status` 为 `not_found`，提及行不变，agent 不会加入频道。发送者自己执行是 `queued`，`dedupedResolutionIds` 是该 resolution id，行上记下 `notifiedAction` 为 `notify_only`，执行人是这个用户，agent 仍不是频道成员。同一路由的 `add` 把 agent 加进频道，也把被点名的用户加进成员。结果是 `delivered`，没有 `reason`，`notifiedAction` 改成 `add`，执行人仍是这个用户。agent 的 mentions 列表出现原来那条消息，并且只投递这一次。再执行一次仍是 `delivered`，`reason` 是 `already_delivered`，不会再投递。对还没加入公开频道的用户执行 `notify` 是 `queued`，`notifiedAction` 是 `notify_only`。这个用户再读 `GET /api/messages/channel/:channelId` 是 200，能看到原来那条消息，`mentions` 是发送时的 `type`、`id` 和名字。私有频道和挂在它下面的线程上，对还不能读这条消息的 agent 执行 `notify` 是 200，`status` 是 `no_permission`，`reason` 是 `target_lacks_read_access`。提及行不会标成已通知，agent 不会加入频道，也不会留下投递。发送者被移出频道之后再执行 `add` 也是 200，`status` 是 `no_permission`，`reason` 是 `sender_lacks_channel_access`。agent 不会加入频道，也不会留下投递。给带转发来源的消息加反应时，HTTP 回执仍保留来源标签。频道上的 `message:updated` 不含 `agentSendKey`、`searchText`、`searchVector`，`commentRef` 是 null，反应表情是 `👍`，转发来源的服务器和目标 id 被清空，快照标签是空串，`labelVisibility` 是 `restricted`。频道里的 agent 用绑定的机器密钥给同一条消息加 `👀`，第一次 count 是 1，`reactorNames` 是 `reaction-agent`，再加一次仍是 1。人再加同一个表情后 count 是 2，两边的 reactor 都在。删掉 agent 的反应后只留下这个人。系统消息不能加反应，回 400 且错误含 `System messages`；公开频道的非成员和被移出的原成员对 `POST` 与 `DELETE` 都是 403，不会留下反应；归档后是 409 `channel_archived`；删除后是 404。私有频道的局外人对普通消息和系统消息加或删反应都是 404，两条共用短 id `dddddddd` 的私有消息也是 404，而公开频道里唯一可见的同前缀消息会命中并把 `👀` 记在那条消息上。反应回执和 `user:{id}` 的 `reaction_viewer:updated` 共用一份快照：`👍` 的版本是 1，重复加不变，加上 `👀` 和 `❤️` 后版本是 3 且按码点排成 `❤️`、`👀`、`👍`，`GET /api/messages/:id/reactions/viewer` 读到同一份，删掉 `👍` 后版本是 4 且再删不变，频道 `message:updated` 不含这些 viewer 字段。反应者分页在两个人加上 `👀` 后 `discussionVersion` 是 2，`limit=1` 的第一页是 user 并带 cursor；别人复用、换消息或换表情都是 400 `invalid_reaction_actors_cursor`。agent 用机器密钥加反应后旧 cursor 是 409 且 `currentDiscussionVersion` 是 3，再用带 `reactions` 范围的 key 删掉后是 409 且版本是 4，加回来后 `limit=100` 的版本是 5，名单是这两个用户和这个 agent。`#all` 在隐藏成员目录打开时，成员按 `limit=1` 翻页只看到 agent 和自己，被藏起来的人不会占页。关掉隐藏后再用第一页的 cursor 是 409 `reaction_actor_visibility_changed`。所有者仍能看到这三个人和这个 agent。私有频道的局外人读反应者是 404。归档后所有者再读是 409 `channel_archived`。两条公开消息共用短 id `eeeeeeee` 是 400。同一条消息换到另一台服务器是 404。带空格的表情是 400 `invalid_reaction_emoji`。cursor 写成 `tampered` 是 400 `invalid_reaction_actors_cursor`。联合频道里客方用自己的服务器给宿主上的消息加反应是 200。客方读反应者时 `discussion.root.serverId` 和 `parentScope` 都是客方服务器，`scopeId` 是客方本地频道，`scopeKind` 是 `channel`，`limit=1` 仍有下一页 cursor。宿主拿这张 cursor 再读是 400 `invalid_reaction_actors_cursor`。私信参与者用消息 id 的前 8 位和这条私信的 `channelId` 读 `GET /api/messages/context/:messageId` 是 200，`channelId` 是这条私信，`targetMessageId` 是完整消息 id，正文是发出去的那句。父频道上的短链如果指到线程里的回复，`GET /api/messages/context/:messageId` 是 200，`channelId` 改成线程，`targetMessageId` 是这条回复，`canonicalTarget` 的 `kind` 是 `thread`，`channelId` 是父频道，`threadParentMessageId` 是父消息，`threadChannelId` 是线程，返回的消息都在线程上。用线程频道自己的前 8 位，再带上父频道，`GET /api/messages/context/:messageId` 是 200，`channelId` 仍是父频道，`targetMessageId` 是父消息，正文是父消息那句。`GET /api/messages/search?q=chronos&limit=2` 默认把出现次数更多的旧消息排在前面。`sort=recent` 改按 `createdAt`，较新的那条在前。`sort=fancy` 是 400。查询 `今晚八发刚收工，明天开` 在每条消息里都凑不齐全部汉字时，改按单个汉字匹配，重合最多的「今晚真收工」排第一，结果仍只留 `limit=20` 条，`hasMore` 是 false。不带 `q`、也不带筛选时，`GET /api/messages/search` 是空的 `results` 和 `hasMore: false`。只给 `senderId` 和 `channelId` 时按时间从新到旧列出，线程回复的 `channelId` 是线程、`parentChannelId` 是父频道，`snippet` 是回复正文，超过 `limit` 时 `hasMore` 是 true。只给 `senderId` 时也会带上别的频道里这个人较新的消息。`senderType=user` 只留下人发的消息，较新的在前；`senderType=agent` 只留下 agent 的那条。`mentionTarget=self` 只留下提及当前用户的消息。`senderType=robot` 和 `mentionTarget=all` 都是 400。非成员用私有频道的 `channelId` 调 `GET /api/messages/search` 是 404 `Channel not found`，正文里没有那条私有消息。成员和绑定了机器密钥的 agent 都能搜到将要删除的频道、它下面的线程回复，以及已归档频道里的消息。所有者 `DELETE /api/channels/:id` 是 200 之后，被删频道和线程从两边的搜索里消失，归档频道里的那条还在。`message_forwarding_v0` 的 kill switch 打开后，`GET /api/messages/forward/enabled` 仍是 200，正文是 `{"enabled":true}`。所有者把源消息 `POST /api/messages/forward` 到自己已加入的目标频道，空的 note 写成 `Forwarded 1 message`，状态是 200。`POST /api/messages/forward` 把来源按 `createdAt` 收成 `forwarded-bundle`：较早的消息在前，没有附件的是 `excluded`，有附件的投影出新 id，`mimeType` 和 `sizeBytes` 跟源文件一致，响应里没有 `forwardRequestFingerprint`、`sourceProjectionId` 和 `url`。同一个 `randomId` 再提交是 200，`X-Raft-Forward-Outcome` 是 `idempotent_replay`，投影 id 不变；note 改掉是 409 `idempotency_conflict`，不会多写一条消息。`destinationChannelIds` 按去重后的顺序返回 `results`：重复目标只写一次，还没加入的私有频道是 `failed` 且 `code` 为 `destination_unavailable`，整次仍是 200，`X-Raft-Forward-Outcome` 是 `partial_failure`。加入后用同一个 `requestId` 补上那个目标，再提交整批会重放这三条消息 id。note 改掉时三条都是 `request_conflict`，仍是 200。缺 `requestId` 或超过 10 个目标是 400。同一条公开线程里的回复转发到自己的目标频道是 200，按时间从早到晚，`sourceTargetId` 和 `sourceThreadId` 是线程，`parentChannelId` 是父频道，快照类型是 `thread`，标签是父频道名。父消息和这些回复一起转发时，父消息排在最前且 `sourceIsThreadParent` 是 true。只转发父消息，或再加上同频道里另一条无关消息时，来源仍是父频道，没有线程字段。父频道消息和线程回复混在一次请求里是 400 `cross_source_bundle`。目标频道的成员读频道消息时能看到这份来源。私有父频道下的线程回复转发出去后，所有者回执里的 `sourceTargetId` 是 null，没有 `sourceThreadId` 和 `parentChannelId`，快照标签是空串。读不到这个父频道的人在目标频道列表里看到的 `sourceServerId`、`sourceTargetId`、`sourceThreadId`、`parentChannelId` 和 `sourceMessageId` 都是 null，标签可见性是 `restricted`，`provenanceState` 是 `original_unavailable`，正文里没有线程 id 和父频道 id。不是私有频道成员的人转发那条消息是 404，正文不含私有内容。所有者转发后内容快照还在，`sourceAuthorSnapshot.uniqueName` 是所有者名字，`sourceMessageId`、`sourceMessageSeq`、`sourceServerId` 和 `sourceTargetId` 都是 null，快照 id 是 null，标签是空串，可见性是 `restricted`，附件投影出新的 id。目标频道成员读这个新附件的 `/url` 是 200，读原来的私有附件是 404，用私有频道读原来的消息上下文也是 404。`sourceMessageIds` 里的 8 位短 id 在查找之前就是 400 `Destination channel and full source message ids are required`，不是 `Message short id is ambiguous`，也不是 `source_not_found`，正文不含那两条私有消息。公开来源转发到联合频道的本地投影是 200，`channelId` 和 `destinationTargetId` 都是这个投影，来源标签是公开频道名。消息记在规范频道上：宿主读本地投影能看到来源，客方服务器以及同一个所有者改用客方服务器来读时来源被抹掉，`provenanceState` 是 `original_unavailable`。客方的消息上下文和 `GET /api/messages/sync?since_seq=0` 也是这份抹掉的来源。从联合频道转出的快照类型是 `joint`，指针是 null。频道、私有、私信和联合频道之间的 16 种组合都是 200。两条不同频道的消息一起转发是 400 `cross_source_bundle`。带任务字段的普通聊天仍可转发，回执 `messageType` 是 `chat`，内容快照是原文，回执、频道列表和消息上下文都不带 `taskStatus`、`taskNumber`、`taskAssigneeType`、`taskAssigneeId`、`taskClaimedAt` 和 `taskCompletedAt`。系统消息和带动作元数据的消息是 400 `unsupported_source_message`。已经是转发包的消息是 400 `forwarded_source_not_supported`，这些拒绝都不会多写一条消息。`GET /api/messages/forward/targets/search` 在 `q` 为空时是 200 且 `targets` 为空。未加入的公开频道标题是 `#` 加名字，`joined` 是 false，`canForwardNow` 是 false，`requiredAction` 是 `join_channel`。已加入的频道可以立刻转发。`search-private` 只返回已加入的私有频道。没有私信的成员是 `human`，`requiredAction` 是 `create_dm`，`dmExists` 是 false。已经有私信的 agent 是 `dm`，`dmExists` 是 true。作者还能读这条私有频道时，`GET /api/messages/:messageId/mention-deliveries` 是 200，投递的 `targetHandle` 是 `original-name`，`outcome` 是 `lost`，`reasonCategory` 是 `unclassified`。同伴、另一台服务器、未知消息，以及作者被移出频道之后，都是 404 `{"status":"NOT_JOINABLE"}`。agent 的机器密钥来读是 401，正文没有 `deliveries`。`GET /api/messages/context/:id` 的 `before` 和 `after` 缺省各是 15，并且不会超过 15。`before=0&after=0` 只返回目标消息。`before=2&after=1` 按频道顺序带上前面两条和后面一条。`before=500` 或 `after=-3` 仍是左右各 15。频道消息页、`GET /api/messages/context/:id` 和 `GET /api/messages/sync?since_seq=0` 返回的消息都不带 `searchText` 和 `searchVector`。`POST /api/messages` 和 `POST /api/v2/messages` 把合法 IANA 时区 trim 后存下来：`Asia/Shanghai`、`Europe/Berlin` 和 `UTC` 留下，火星时区、`EST`、`+05:00`、超过 128 字符、数字、`null` 和省略都存成空，发送仍是 200；发送回执、频道消息页、消息上下文和 `since_seq=0` 的同步都不带 `senderTimezone`，频道页能按 `content` 找到 `valid v2`。`GET /api/messages/channel/:channelId` 在同一份响应里带上本页父消息的 `threadSummariesByParentMessageId`：有线程的父消息 `replyCount` 是回复条数，`latestReplies` 含回复预览；没有线程的消息不占键，摘要键都落在本页消息 id 上。`GET /api/messages/context/:id` 同样带上这个窗口里父消息的摘要，`replyCount` 和回复预览都在同一份响应里，摘要键不会超出窗口里的消息 id。这一页没有线程父消息时，`threadSummariesByParentMessageId` 仍在，值是空对象。`limit=2` 只留下最新的两条频道消息，窗口外的旧父消息和它的线程摘要都不会出现。私有频道的非成员读这条频道页仍是 404，拿不到消息和线程摘要。`GET /api/email/mobile-app/unsubscribe?token=` 用签名 token 打开确认页，正文含 `Unsubscribe from mobile-app emails?`，这次读取不写退订。同一个地址 `POST` 且正文是 `List-Unsubscribe=One-Click` 时是空的 200；再带 `source=visible` 是 200，正文含 `You are unsubscribed`。两次提交只留下一条 `mobile-app-lifecycle` 退订，邮箱是账户邮箱，状态是 `unsubscribed`，并记下退订时间。改过的退订 token 做一键 `POST` 是 400，不会写入联系人。`zh-CN` 签出的退订 token 让确认页和成功页保持简体中文：`lang` 是 `zh-CN`，确认标题是 `要退订移动端应用邮件吗？`，按钮是 `退订`，成功页是 `你已退订。`。不带 `List-Unsubscribe=One-Click` 正文的一键 `POST` 是 400，不会写入联系人。已经排好的 `first_computer_mobile_app_48h` 邮件在这次一键退订里被取消：取消的是 `scheduled-mobile-email`，`day1Status` 变成 `skipped`，`suppressedReason` 是 `unsubscribed`，并记下取消时间。`SLOCK_NATIVE_NOTIFICATIONS_ENABLED` 不是 `true` 时，`GET /api/notifications/stream` 是 404 `not_found`，`persistNativeNotificationIntents` 返回 0，不写通知账本。开关打开后，`POST /api/notifications/enrollment-grants` 回 201，grant 形如 `rng1.` 加 uuid 加密钥，过期不超过 60 秒；库存的是哈希，整段 grant 不在记录里。错密钥兑换是 403。同一 grant 并发兑换只有一次 201，另一次 403，再用仍是 403。成功兑换的 credential 形如 `rnc1.`，`scope` 是 `notifications:stream`，凭证记录不含这串密钥。`GET /api/notifications/devices` 是 200，正文没有 `secretHash`、`publicKey` 和这串 credential。没有 proof、证明签的是另一份 nonce、grant 已过期，或 session family 已撤销，兑换都是 403，不会发出 credential。`NATIVE_NOTIFICATION_ATTESTATION_MODE=enforce` 时，没有通过签名应用校验的 attestation 不能签发 grant，是 403；校验接受的证据才是 201。`GET /api/notifications/stream` 拒绝用户会话，是 401，不是 `text/event-stream`。没有游标的连接不重放连接前的事件，只推之后的新事件。`Last-Event-ID` 重放该用户游标之后的事件；别人的事件 id 是 409。没有有效原生凭证的用户不会写入账本。同一 `eventKey` 只留一条。登出撤销 session family 后，正在开着的流会关掉，再用这张凭证是 401。已经读出的一批事件在写出每一帧之前都会重新鉴权：凭证被撤销，或 session family 被登出撤销时，流立刻关掉，只留下撤销前已经写出的帧。用设备公钥签过的 `POST /api/notifications/credentials/rotate` 换发新的 `rnc1` 并作废旧凭证，旧凭证再开流是 401；这张新凭证过期后，设备列表里该设备是 `inactive`。`DELETE /api/notifications/devices/:deviceId` 记下 `revokedAt`，列表状态是 `revoked`，该设备的流是 401。`DELETE /api/notifications/credentials/current` 是 204，之后这张凭证也不能再开流。错误的轮换证明是 403 `native_credential_proof_invalid`，响应正文不带回 grant、凭证、`secretHash`、proof 或 access token。`Last-Event-ID` 之后如果还有超过 512 条未过期事件，`GET /api/notifications/stream` 在写出 SSE 头之前回 409 `replay_window_exceeded`；游标那条事件过期后则是 409 `replay_cursor_unavailable`。`GET /api/oauth/.well-known/openid-configuration` 是 200，`scopes_supported` 只有 `openid`、`profile`、`email`、`identity`、`agent:read`、`agent:event:write`、`agent:notification:write`，不包含 `agent:action_request:write`、`app_admin` 和 `winbox:opencli:twitter`。`POST /api/oauth/authorize/human` 给仍是该服务器成员的用户签发一次性 human code。`POST /api/oauth/token` 接受 form 里的 `client_id`/`client_secret`、JSON 里的 `clientId`/`clientSecret`，以及 `Authorization: Basic`，三种都回 200，正文是 `access_token`、`token_type` 为 `Bearer`、`expires_in`、空格分隔的 `scope`，请求里有 `openid` 时还有 `id_token`。超过 10 分钟的 human authorization code 换票是 400 `authorization_code_expired`，并带 `next_action` `obtain_fresh_authorization`，且不会签发 access token。`POST /api/oauth/installation-token` 用客户端凭证给活跃安装签发 `raft_installation_` 令牌，`Cache-Control` 是 `private, no-store`，正文含 `token_type` `Bearer`、`expires_in` 600、`installation_id` 和 `server_id`。`GET /api/oauth/userinfo` 和 `GET /api/oauth/agents` 只认 principal access token：安装令牌打这两个地址都是 401，`/agents` 的 JSON 里没有 `agents`。用户会话打 `GET /api/app-installation/server` 是 401；安装令牌打同一地址是 200，`Cache-Control` 是 `private, no-store`，`installation_id` 和 `server.id` 对得上；缺 `channel` 组的安装令牌打 `GET /api/app-installation/channels` 是 403。App 被收成 `slock_builtin` 或登记了平台身份之后，之前签发的安装令牌读投影是 401，重新签发也不会新增令牌。`POST /api/oauth/installations/lookup` 用客户端 Basic 凭证和 `server_id` 只找到这个 App 在该 Server 上的活跃安装，回 200、`Cache-Control: private, no-store`，正文含 `installation_id`、`server_id` 和默认 `setup`；同一个路径挂到 `/oidc/:server/...` 是 404。同一个 App 查别的 Server、用另一个 client 的凭证、安装被暂停，都是 404 `Active installation not found`；`third_party_global` 被关是 401，`server_local` 被关仍只回 404；非 UUID 的 `server_id` 是 400 `server_id must be a Server ID`。`GET /api/oauth/userinfo` 对 principal 令牌回当前成员投影：`type`、`sub`、`server_role`、`preferred_username`、`name`、`avatar_url`、`picture`、`description`；只有 Raft 上传的用户头像会变成 `picture` 绝对地址，第三方 provider 头像只留在 `avatar_url`，`picture` 是 null；成员被移出 Server 后同一令牌变 401。`GET /api/oauth/serverinfo` 只按令牌里的 Server 回 `id`、`slug`、`name`、`avatar_url`、`picture`、`is_paid`、`plan_tier`，忽略查询里的 `server_id`；Server 改名或换头像后同一令牌读到新值，非 `free` 的 plan 一律投影成 `paid`，Server 删除后同一令牌 401。`POST /api/oauth/requests/agent` 让 server-local 或已安装的 App 为 Agent 申请访问并由所有者侧自动批准；`POST /api/oauth/token` 的 `urn:slock:grant-type:agent_request` 用 `requestId` 换 `slock_at_` agent 令牌，该令牌读 serverinfo 时和 human 用同一套 Server 字段投影。`agent_request` 的 `requestId` 不是 UUID 是 400 `invalid_grant` / `The authorization request is invalid or has expired`，格式正确但不存在是 404 `Access request not found`。`GET /api/oauth/clients/lookup` 给 Server 成员看 client 和 `scopeValidation`；client 不允许的 `email` 在 lookup 里是 `{"allowed":false,"reason":"not_allowed","disallowedScopes":["email"]}`，`POST /api/oauth/authorize/human` 回 400 `invalid_scope`、`errorCode` `OAUTH_SCOPE_NOT_ALLOWED` 和同一句说明。lookup 正文带注册时的 `name`、`description`、`homepageUrl`、`returnUrl`，不回 `clientSecret`；非成员或换 Server 都是 404。`slock_builtin` client 在 lookup、authorize/human、token、installation-token、installations/lookup 都关闭（404/401），已经发出的 bearer 读 userinfo 也 401。`GET /api/oauth/clients/lookup` 对未安装的公开 marketplace App 回 `marketplace: true`、`availability: "install_required"` 和 `installation.canInstall`（owner/admin 是 true，普通成员 false）；未发布或私有的 App 和未知 id 一样 404；安装后同一查询变 `ready`，不再有 `installation`。`third_party_global` App 只在该 Server 有活跃安装后才被 lookup 命中并允许 `authorize/human`；非成员仍是 404。`POST /api/oauth/requests/agent` 的 server-local 请求直接 approved，scopes 排好序；换票重放是 409 同一句 `request_already_consumed`；agent 令牌读 userinfo 是 `type: agent`、实时 `server_role`、`displayName`、`avatar_url` 和 pixel `picture`，成员被移出后 401。`GET /api/avatars/pixel/:key.svg` 对 `pixel:` 头像回 SVG，`Content-Type` 是 `image/svg+xml; charset=utf-8`，`Cache-Control` 是 `public, max-age=31536000, immutable`；`pixel:cat` 这类命名头像也能取到。agent request 的未知 scope 是 400 `{"error":"invalid_scope"}`；`slock_builtin` client 申请 agent 访问是 401，不留下请求。agent 的 inbound scope（`agent:event:write`）只有 client 的 `allowedScopes` 显式列出才批，否则也是 400 `invalid_scope`；批准后 scopes 排序。inbound agent scope 换票必须带 `resource`，缺了是 400 `{"error":"resource is required for requested scopes"}`；值必须是 `urn:raft:server:<id>:agent-inbound`，成功响应回同一个 `resource`；identity scope 不带 resource 也兼容。`POST /api/oauth/agent-events` 只认绑定该 Server resource 的 agent token 和匹配的 inbound scope；新事件是 202 `{id,status:"queued",payloadHash}`，同一 `externalEventId` 重试是 200、同一 id、`deduped: true`；排队中的事件被重试会重新领取，仍回 `status: "queued"` 和原 id。`GET /internal/agent-api/wake-hints` 用带 `read` 的 agent credential 看未排空的第三方事件；`GET /internal/agent-api/events` 取出即标记 delivered，重放为空，wake hints 也随之清空。`GET /internal/agent-api/wake-hints/stream?since=0` 先回 `: connected`，再按 `event: wake-hint` 推同样的空正文 hint；`since` 必须是非负整数或 `latest`，否则 400 `since_invalid`。`POST /internal/agent-api/third-party-events/delivered` 用 `read` credential 上报本地已投递的事件 id，只标记本 agent 的 delivering 事件，回 `{ok:true,delivered:N}`；重复上报是 0，空数组或坏 id 是 400 `event_ids_invalid`。没绑定 resource 的 agent identity token 打 `/api/oauth/agent-events` 是 403 `resource-bound token required`，并带期望的 resource。并发发两个同 `externalEventId` 的请求也只会入队一次：一个 202、一个 200，id 相同，只有一个 `deduped: true`。`GET /api/oauth/agents` 对带 `agent:read` 的 human/agent 令牌回本 Server 未删除 agent 的 `{id,handle,display_name,avatar_url,picture}`，`Cache-Control` 是 `no-store`；identity-only 或 client 关闭是 403，成员或 agent 成员被移出是 401。`/oidc/:server/api/oauth/agents` 和同前缀的 discovery 按 id 或 slug 匹配；令牌的 Server 不匹配回 401，scoped discovery 的 `agents_endpoint` 带 `/oidc/<slug>`。webhook group 不能授予 `agent:read`；identity-only 是 403；缺失、无效、过期或已撤销的令牌是 401；agent grant 被撤销后 agent 令牌也 401。token 端点（含 `/oidc/:server`）只要请求体出现 `code_verifier`（字符串、空串、null、数组都算）就是 400 `invalid_grant`，不消费 code；不带的非 PKCE 换票仍成功一次，重放是 409。`authorize/human` 带了 `returnUrl` 时必须与注册值完全一致且安全（HTTPS 或 loopback HTTP，无 credentials/fragment），否则 400 不签 code；创建 client 时 `javascript:`、`data:` 等直接拒绝。`GET /.well-known/openid-configuration` 与 `/api/oauth/.well-known/openid-configuration` 是同一份文档。`GET /api/oauth/jwks` 回一把 ES256/P-256 验签公钥（`kty`、`crv`、`use`、`alg`、`kid`、`x`、`y`），不带私钥 `d`。`GET /api/oauth/authorize` 校验 `response_type=code`、注册的 `redirect_uri`（不能带 fragment）、scope、S256 challenge 和不超过 512 的 nonce，然后 302 到 `APP_URL/login-with-raft/setup`，带 `flow`、`client_id`、`return_to`、`scope`、`state`、`nonce`、`code_challenge`；unscoped 路径不带 `server`。`authorize/human` 的 `oidc: true` 分支要求 43 位 S256 challenge，签 `raft_oidc_` code；换票必须带匹配的 `code_verifier` 和 `redirect_uri`，ID token 带 `nonce`、`name`、`email`、`email_verified`、`server_id`；缺或错 verifier 都不消费 code。OIDC code 没有 challenge 时换票不要求 verifier；没有 `email` scope 时 ID token 和 userinfo 都不带 `email` / `email_verified`；过期 OIDC code 是 400 `invalid_grant`、不带 `next_action`；成员被移出后换票 400，恢复成员后同一 code 仍可换。 ID token 的 ES256 签名能用 `/api/oauth/jwks` 里的 `kid`、`x`、`y` 验过。 `POST /api/product-events/onboarding-wizard` 用 human bearer 加 `X-Server-Id`，成功是 204；metadata 只保留 `step_id`、`wizard_version`、`session_id`、`action`、`result`、`reason` 和取整的 `latency_ms`；`enable-notifications` 这个 push 步骤是 400；用户 opt-out 或 workspace 关闭时仍 204 但不记录。 `GET /api/product-events/config` 回 `{clientEventsAllowed}`，只有用户显式开启 shareUsageData 才是 true；`POST /api/product-events/batch` 在未共享时 202 `{accepted:0}`，共享后只收已注册事件（`activity_open`、`activity_mark`），未知属性、未注册事件和超过 7 天的都丢弃，uuid 去重，properties 追加 `$browser`、`$browser_version`、`$os`、`$device_type`、`$country`，原始 UA 和 user id 不入库。 `POST /api/product-feedback` 无 bearer 是 401；坏 multipart、非 UUID `submission_id`、未知 `type` 或伪造的 native attribution 是 400 `feedback_invalid`；没配 Hands 时合法提交是 503 `feedback_not_configured`；`/api/internal/hands-feedback/webhook` 是 404。Hands 上游代理尚未移植。 `/api/provider-connections` 默认 404 `provider_connections_disabled`；打开后只有 owner/admin 可读，member 403；创建只接受 `name`、`providerId`、`apiKey`、`endpointUrl`、`supportsImageInput`、`authMethod`，带 alias 字段是 400；响应和列表都不回显 api key，`hasCredential` 为 true、`status` 为 unchecked，列表带 preset/gateway 的 `providerOptions`。 PATCH 把 `apiKey` 和 `providerId` 混在一起是 400；`credentials/rotate` 和只改 `name`+`apiKey` 的 PATCH 都把 `credentialVersion` 加一并回到 `unchecked`，响应不回显 key。 `GET /api/provider-connections/:id/agents` 列出分配的 agent（owner/admin 才能看，跨 Server 是 404）；活动 agent 的分配删除是 409 `provider_connection_assignment_active`，有活动分配的 connection 删除也是 409；agent 软删后可以删除连接。 启用连接功能后 `POST /api/provider-connections/:id/test` 和 `GET /api/provider-connections/:id/models` 都回 410，不做 provider I/O；未启用时仍是 404。 `POST /api/push/registrations` 校验 APNs/FCM tuple（`installationId` 安全形状、APNs 只有 sandbox/production、FCM 只有 production、deviceToken 字符集），同一 installation+provider 幂等 upsert 并回稳定的 `revoke_capability`；`DELETE /api/push/registrations/:installationId` 回 `{ok:true,unbound:N}` 并把绑定置空，保留注册行。 `GET /api/push/delivery-status?installationId=` 无 auth 是 401、缺或坏的 id 是 400；回该用户所有 Server 的 `{servers:{id:{fcmActive}}}`，`fcmActive` 只在 FCM 可用且该 installation 有本人在用的 fcm 注册时为 true。 `POST /api/push/family-revoke` 不需要 auth，capability 是 `<familyId>.<nonce>`；首次撤销清空该 family 的 refresh/access token 并回 204，30 天内重放仍是 204，过期或改坏回 403，格式坏回 400；`/api/auth/logout` 也把 family 标成 logout 且 capability 仍可确认。 `POST /api/push/subscribe` 需要 bearer；只收 https、无 userinfo、公网 DNS 的 endpoint，拒绝 http、IP 字面量、`localhost`/`.local`/`.internal`、私网/loopback/link-local 和坏 URL，400 不落库；有效订阅按用户去重存储。 `GET /api/servers/:id` 对 owner/admin/member 回完整资料（`id`、`ownerId`、`plan`、`translationEnabled`、原样 `avatarUrl` 等），guest 只回 `{id,name,slug,avatarUrl:null}`。 `GET /api/servers/:id/settings` 只有 owner/admin 200，member/guest 403；`notification-settings` 和 `onboarding-settings` 所有成员可读；`GET /:id/machines` member 以上可读、guest 403；guest 只能 PATCH 自己注册的机器，别人的 403。 机器写操作按 registrant 关系：owner/admin 可改所有，其他角色只能改、rotate 或删除自己注册的机器；离开 Server 后所有机器写操作是 403 `Not a member of this server`；`rotate-key` 回新的 `apiKey`。 Agent 的 `PATCH`/`DELETE`、`/stop`、`/reset`、`/migrate`、`/credentials` 对 owner/admin 或该 Agent 的创建者开放，其他 member 403；离开 Server 后普通操作是 403 `Not a member of this server`，credentials 是 404 `agent_missing`；managed Agent 不能从 session 拿 credential（400），external 可以（201）。 `GET /api/agents/manageable` 不需要 `X-Server-Id`，回 `{ok:true,data:{agents:[{id,name,serverId,serverName}],reason,manageable_server_count}}`；owner/admin 看本 Server 全部 Agent，member 只看自己创建的；reason 是 `ok` / `no_agents_on_manageable_servers` / `no_manageable_server`，不回 `suggested_next_action`。 `POST /api/agents` 接受 `runtimeConfig`，回 200，带 `runtime`、`model`、合并后的 `envVars` 和规范化 `runtimeConfig`（补 `mode`、`reasoningEffort: null`）；PATCH 的 `envVars` 会剥掉 `ANTHROPIC_*` 再由 provider/model 重新派生；`GET /api/agents` 对非 owner/admin、非创建者省略 `runtimeConfig`/`envVars`；`GET /api/agents/:id` 对非 UUID 是 404。 `POST/PATCH /api/agents` 的顶层 `envVars` 在边界校验：非对象/数组是 `envVars must be an object`，非字符串值是 `envVars keys and values must be strings`，坏 key 是 `Invalid env var key "X": must match ...`，含 null 字节是 `envVars keys and values must not contain null bytes`；`null` 或缺省是 no-op，被拒的 PATCH 不改原值。 `external: true` 的 Agent 固定 `runtime`/`model` 为 `external`，忽略 runtimeConfig/envVars，`machineId` 是 null；带 `machineId` 创建是 400 `External agents cannot be assigned to a Computer`；列表回 `external: true`。 `GET /api/agents/:id/external-status` 对 external Agent 回 `waiting_for_login` / `credential_minted` / `connected`，`credentialLastUsedAt` 只在用过后是 ISO 时间，`lastActivityAt` 为 null；非 external 是 400 `Agent is not external`；list/get 带 `serverRole: "member"`。 `POST /api/agents/:id/avatar` 超过 5 MB 回 400 `{error:"Avatar image must be 5 MB or smaller",errorCode:"PROFILE_AVATAR_TOO_LARGE",maxBytes:5242880}`；权限同 Agent 管理。 非 claude runtime 带 `runtimeConfig.command` 是 400 `runtimeConfig.command is not supported for runtime: <runtime>`；PATCH 带 `runtimeConfig` 时整体替换并更新 runtime/model，响应和 GET 都回派生 model（preset id 或 custom name）。 PATCH `/api/agents/:id` 接受 `avatarUrl`；`POST /:id/avatar` 在 5 MB 内回 `{avatarUrl:"/api/avatars/users/<32hex>.webp"}` 并写到 Agent，超限仍是 400。 `GET /api/channels` 对 Server 成员回数组，含默认 `all`、每频道的 `joined` 和 `lastMessageAt`（ISO 或 null）；新频道创建者自动 joined。 `POST /api/channels`（owner/admin/member）校验小写 name，回 200，含 `joined:true`、`activityMuteSupported:true`、`activityMuted:false`、`muteFromSeq:null`、`prefsVersion:0`、`maxReadSeq:0`、`readStateVersion:0`。 新频道同时进入可发送消息的频道集合：创建后 `POST /api/messages` 可直接发，`randomId` 重放不覆盖原消息。 `PATCH /api/channels/:id` 改名会写一条系统消息 `@<name> renamed this channel from #old to #new.`（system sender，带 seq）；只改 description 不写系统消息。 `GET/PATCH /api/channels/:id/notification-settings` 按用户存 activity mute：默认 `false`/`0`；置 true 时 `muteFromSeq = 当前 seq + 1`、`prefsVersion` 加一，重复同值不涨；非 bool 是 400；线程走 follow/unfollow 是 400；频道列表带同样字段。 `GET /api/channels/unread`（`Cache-Control: private, no-store`）回每个 joined 频道的未读数，排除自己发的；`?summary=1` 回 `{channels:{id:{unreadCount,hasMention,hasAnyMention,readState:{kind,maxReadSeq,latestActivity}}}}`；DM 频道同样计入。 `GET/PATCH /api/channels/:id/message-display-settings` 默认 `collapseLongMessages:true`、`prefsVersion:0`；非 bool 是 400；必须是频道成员（`all` 对所有 Server 人类隐式开放），否则 404；PATCH 变更时版本加一。 `POST /api/channels/dm` 建 DM，`GET /api/channels/dm` 列 DM，`GET /api/channels/:id` 回频道详情；DM 在通知设置、详情和列表里都回 `activityMuteSupported:false`，普通频道是 true；DM 的 notification PATCH 允许并返回 false，线程才是 400。 `POST /api/channels/system/all/hide` 把 #all 置为 private，`restore` 恢复 channel；两者仅 owner/admin，重复 hide 幂等 200，member 403。 `POST /api/channels/saved` 保存 `messageId`；`GET /api/channels/saved` 回 `{saved,total,hasMore}`，支持 `q`（内容或 thread 父消息预览）、`channelId`（thread 按父频道）、`sort=asc|desc`、`limit`/`offset`；`total` 在分页前算；thread 条目带 `channelType`、`parentChannelId`、`parentMessageId`、`parentMessagePreview`、`replyCount`。 `GET /api/reminders` 只读：owner/admin 看本 Server 全部 Agent 的 reminder，普通 member 只看自己创建的 Agent；显式 `ownerAgentId` 越权 403；`POST/DELETE /api/reminders` 是 404。 `GET /api/servers/:id/sidebar-order` 回 `{channelOrder,agentOrder,dmOrder,pinnedOrder,hiddenDmIds}`，只保留本 Server 可见且是 UUID 的 id；DM 只保留自己参与的；pinned 同时接受频道、Agent、DM。 `/api/tasks/channel/:id` 对已加入成员可读写；未加入的 Server 成员对 public 频道只读（列表/编号 200，claim/status/create/convert 403），private 频道一律 404；`number/:n` 回 `{task}`；`?status` 只接受单个合法值，重复或未知 400；`GET /api/tasks/server` 同样校验。 `PATCH /api/tasks/:id/assignee` 是 member 级：body `{assignee:{type,id}|null, expectedRevision?}`；分配不推进 status、不盖 claimedAt、revision 加一；同值 no-op 不涨；越界 assignee 409；stale expectedRevision 409 并带 currentRevision；done 任务 409；unassign 保留 status；claim 仍推进 todo→in_progress 并盖 claimedAt。 `PUT/GET /api/servers/:id/agreement`：仅 owner/admin（member 403 固定错误 `Only server owners and admins can manage the pre-join agreement`）；PUT 每次新建一版并停用旧版；body 上限 5000 字符，超出 400 `Agreement body must be 5000 characters or fewer`；GET 回当前生效版。 `POST /api/servers/:id/scope-attestation`：member 可签 `web-trace-batch:create`（aud `trace-ingest-worker`，resource `servers/<id>/web-traces`）；`feedback-report:create` 仅 owner/admin（aud `feedback-worker`，resource `servers/<id>/feedback-reports`）；回 `{attestation,scope,audience,resource,expiresAt}`，attestation 是 HS256 JWT。 `POST /api/servers/:id/machines/:machineId/agents/:agentId/feedback/:reportId/transcript`：owner/admin 或 Agent 创建者才可；reportId 非 UUID 404；`reportGeneratedAt` 非法 ISO（含小数秒）400；成功 202 `{accepted:true,feedbackReportId,agentId}`。 `POST .../agents/:agentId/diagnostic/mention-delivery/:messageId/redrive`：无权调用者和未知对象同为 404，body 的 `status` 区分 `NOT_ACCESSIBLE` 与 `NOT_JOINABLE`；owner/admin 或 Agent 创建者才算有权限。 `POST /api/servers/join-community`：登录用户加入 `community` 或 `community-cn`，回 `{serverId,serverName}`，角色 member；未知 slug 400（unsupported），未种 Server 404（not available），已是成员 400（already）；未登录 401。 `POST /api/channels/:id/join`：已在频道内直接 200 `{ok:true}`（即使 Server 角色已移除）；否则 Server 成员可加入；无 Server 角色 403 `Server role cannot join public channels`；未登录 401 `{"error":"Missing or invalid Authorization header","code":"auth_required"}`。 `POST /api/channels/:id/archive` 仅 owner/admin，回 `{archivedAt: ISO}` 且幂等；归档后发消息 409 `{error:"This channel is archived",code:"channel_archived"}`；`unarchive` 清空并恢复写入。 归档也冻结频道改名、notification-settings、message-display-settings 和创建 task，均 409 `channel_archived`。 `GET /api/tasks/server/period-metrics`：仅 owner/admin；`from`/`midpoint`/`to` 必须各差 7 天，否则 400；可选 `channelId`（非 UUID 400，不可见 404）；回 current/previous 的 `{completed,durationSamples,meanHours,medianHours}`，基于 completedAt 与 createdAt；超过分页上限的 task 也计入。 `GET /api/tasks/server/snapshot-metrics`：owner/admin；可选 `channelId`（不可见 404）；回 `{total,inReview,done,durationSamples,medianHours,p90Hours,firstCreatedAt,latestUpdatedAt}`，统计全部可见 task。 未知或仅消息侧的 task id 在 claim/status/assignee/delete 上都是 404，不产生部分写入。 `GET /api/servers/:id/labs` 回 `accessEnabled`/`version`/`canManageAccess`/`canManageEnrollments`/`labs`（仅 open/paused）；`PATCH .../labs/access` 仅 owner，CAS `expectedVersion`，stale 409 `{code:"server_labs_version_conflict",currentVersion}`；`PUT .../labs/:labKey` owner/admin，关闭时 409 `server_labs_access_disabled`，paused 409 `lab_not_open`，同值 `applied:false` 且不涨版本。 `POST /api/servers/:id/leave` 成员离开（owner 400）；`DELETE /api/servers/:id/members/:memberId` owner/admin 移除（owner 400）；`DELETE /api/servers/:id` 仅 owner，软删后不再出现在成员 Server 列表。 owner 只有在还有另一个 owner 时才能 leave；最后一个 owner 仍 400。 `POST /api/servers/:id/invites`：owner/admin；非法邮箱 400 `Enter a valid email address`；合法回 200 `{invite:{id,email,status:"pending"}}`；普通 member 403。 `POST /api/servers/:id/avatar`：owner/admin 可传，回 `{avatarUrl:"/api/avatars/server-<id>/<hex>.webp"}` 并同步到 Server 详情；普通 member 403。 `GET /api/servers/:id/member-graph`：Server 成员可读；回 `{humans,agents,channels,edges}`；只暴露非归档 public 普通频道和虚拟 `all`；排除 private/archived/DM/thread 与已删除 Agent；不泄漏 email/env。 `GET /api/servers/:id/members` 回成员数组 `{userId,role,name,displayName,email,avatarUrl}`；owner/admin 看全部 email，普通成员只看自己，其它为 null；X-Server-Id 不匹配或缺失 400。 `GET /api/servers/:id/members` 在 `hideHumansFromMembers` 开启时对普通 member 只返回自己；owner/admin 仍看全量。 `GET /api/servers/:id/members/:memberId/profile`：非成员 403；目标非成员或 hidden directory 下不可见 404 `User not found`；owner/admin、本人、或共享可见 public 频道时可读；非 admin 的 peer email 仍为 null。 `GET /api/servers/:id/apps`：composer references 未开启时 404；开启后回 `{apps:[{appId,displayName}]}`（system.cleaner/system.reminder，隐藏 system.canary）。 `GET/PATCH /api/servers/order` 持久化 Server 切换顺序：PATCH 去重并过滤非成员 id，非数组 400；值变化才 `serverOrderVersion` 加一；`GET /api/servers` 按该顺序返回并带 `serverOrderVersion`。 删除成员关系后 `GET /api/servers/order` 会丢弃该 Server，但用户级版本仍单调递增，下一次真实变更继续 +1。 `GET /api/servers/:id` 对非成员 403 `Not a member of this server`；成员回 Server 详情。 `PATCH /api/servers/:id`：owner/admin 可改名和设 `hideHumansFromMembers`；member 403；空名或非 bool 400；响应带更新后的 name 和 hideHumansFromMembers。 `GET/PATCH /api/servers/:id/translation-settings`：成员可读 `{translationEnabled,translationAvailable,canManageTranslation}`；owner/admin 可改；member 403 `Only server owners and admins can update translation settings`；非 bool 400 `translationEnabled must be a boolean`；availability 由 `TRANSLATION_PROVIDER` 与 provider 凭证决定（fake/volcengine/google）。 `GET/PATCH /api/servers/:id/onboarding-settings`：回 server 级 `onboardingAgentId`/`agentAllChannelGreetingEnabled`/`onboardingWizardEnabled` 与 per-user `setupModalReminderOptOut`/`dismissed*StepAt`/`onboardingWizardCurrentStep`；owner/admin 改 agent 与 greeting，member 只能改 reminder/dismissed/currentStep；member 改 agent/greeting 403 固定错误；非 bool 400、非法 step 400；`GET /settings`（owner/admin）包 `{settings:{onboardSettings,feedbackSettings:{enabled:true}}}`。 `onboardingWizardEnabled` 对 slug 为 `community`/`community-cn` 的 Server 恒为 false，其它 Server 默认 true。 `GET/PATCH /api/servers/:id/notification-settings`：每个成员独立 `{serverPushMuted,serverPushMentionsOnly,serverPushMode,prefsVersion}`；默认 all/0；mode ∈ all/mentions/none；muted=true 归一到 none；同值不涨版本；非 bool 或非法 mode 400。 `PATCH /api/servers/:id/machines/:machineId`：`description` 去首尾空白，空白串清空为 null；列表同步。 `DELETE /api/servers/:id/machines/:machineId`：owner/admin 或机器所有者可删，回 `{ok:true}`；重复删除 404；列表立即消失。 `OPTIONS /api/...` 预检回 204，带 `Access-Control-Allow-Origin`、`Access-Control-Max-Age: 7200`（Chrome 两小时上限）。 已下线的 `/api/app-admin/*` 和 `/api/oauth/operator/feature-flags/*` 保持 404（即使已登录）。 Slack bridge 未配置 provider runtime 时 `/api/slack-bridge/oauth/start`、`/oauth/callback`、`/provisioning`、`/events` 全部 503 `{ok:false,code:"slack_bridge_provider_unavailable"}`，不产生 OAuth attempt。 `POST /api/computer/attach` 回 201 `{apiKey,machineId}`；`GET /internal/computer/runners` 用该 key 200，机器删除后同一 key 401（凭据随机器撤销）。 `POST /api/channels/:id/join`：已是成员幂等 200；无 Server 角色 403 `Server role cannot join public channels` 且不入频道。 `POST /internal/agent-api/channels/:id/join`：agent 凭据需 `channels` scope；已是成员幂等 200；无 Agent Server 角色 403 `Server role cannot join public channels`。 `POST /api/oauth/authorize/human`：returnUrl 必须与已注册安全 URI 完全一致；未注册、`javascript:`、mismatch 都 400 且不发 code；valid 200 回 code 与 returnUrl。 `GET /api/servers/:id/member-graph` 在 hidden directory 下对非 owner/admin 403 `Member graph is not available`；X-Server-Id 不匹配 400。 `GET /api/servers/:id/member-graph` 缺 X-Server-Id 400，非成员 403。 `PATCH /api/servers/:id/members/:memberId`：owner 可改任意非自己角色；admin 只能改 member/guest 目标且不能授予 owner；guest 需先启用 guest 迁移开关，否则 403；降为 guest 时移除 #all；成功回 `{ok:true,changed:true}`。 owner 在还有另一个 owner 时可自降 guest，否则自改角色 400。 归档频道仍可被 `/api/messages/search` 搜到，结果带 `channelArchivedAt`；`/api/messages/context` 回 `channelArchived:true`；unarchive 后字段归 null。 父频道归档会冻结其 thread 回复（409 `channel_archived`）；unarchive 同时恢复子 thread 写入。 `POST /api/servers`：新 slug 至少 5 字符，否则 400 `Slug must be at least 5 characters`；已存在且为成员回 200；创建者成为 owner。`GET/PATCH /api/servers/:id/product-analytics-settings`：成员可读 `{productAnalyticsEnabled,canManageProductAnalytics}`；owner/admin 可改；非 bool 400。 `GET /api/servers/:id/model-label-catalog`：成员与 guest 可读 `{machines:{<machineId>:{runtimes:{<runtime>:{models:[{id,label}],updatedAt}}}}}`，非成员 403，字段仅 id/label/updatedAt。 `POST /api/servers/:id/machines/:machineId/computer/:action`：owner/admin；未知 action 400 `unknown_action`；非 Computer 409 `not_a_computer`；离线 409 `computer_offline`；在线 200。 `upgrade` 缺 targetVersion 400 `invalid_target_version`；在线但无版本 409 `computer_control_unsupported`（固定错误文案）；成功回 `{ok,action,requestId,operationId,computerVersion}`，未来版本仍 200。 `POST /api/servers/:id/invites`：role 缺省 member；非法 role 400 `role must be one of: member, guest`；guest 需 gate，关闭时 400 `Guest access is not enabled for this server` 且不落库；`GET .../invites` 列出 `{id,invitedEmail,role,status}`。 `POST /api/servers/:id/join-links` owner/admin 回 `{token}`；`GET /api/auth/invite-info?token=` 回 `humanSeatLimitReached`/`humanSeatLimitMessage`；`POST /api/auth/accept-invite` 座位满 400 `Seat limit reached (x/y on Pro plan)`，否则加入成员；member 邀请在座位满时 400，guest 邀请不占座。 Guest→Member 提升需要空余付费座位，否则 409 `{code:"human_seat_limit_reached"}` 且角色保持 guest；座位计数不含 guest。 `DELETE /api/servers/:id/members/:memberId`：admin 移除 owner 403；owner 可移除另一个 owner；最后一个 owner 400。 `POST /internal/agent-api/profile`：hosted agent 改 description 403 `hosted_agent_description_human_only`（含 suggestedNextAction，任何字段都不写）；只能改 displayName；self-hosted external agent 可改 description。 `POST /internal/agent/:agentId/runtime-profile/migration-done`：machine key 认证 + 同 Server agent；空 migrationKey 回 deprecated noop 形状，非空回 deprecated handled 形状；无效 key 401。 `POST /internal/agent/:agentId/send`：machine key 必须属于同一 Server，否则 404 `Agent not found`；按 `#channel` 解析同 Server 频道，非频道 agent 403，未知频道 404，归档 409 `channel_archived`，成功写入 agent 消息并回 `{id,channelId}`。 thread target `#parent:shortid` 解析到 thread，授权看父频道 agent 成员；未加入父频道回 403 `Agent is not a member of the parent channel`；未知 short id 404 `Thread not found`。 `GET /api/messages/sync`：返回 `{id,channelId,seq,content}` 且 `seq` 为数字；`since_seq` 过滤；非法 channel 400。 省略 `channel_id` 时跨可见频道同步（`limit` 默认 50）；private 频道只对频道成员可见。 `GET /api/channels/:id/files` 列附件；`/api/attachments/:id` 与 `/html-preview-url` 按频道可见性 200/404；private 非成员被 cloaked。 `GET /api/channels/saved` 与 `POST /api/channels/saved/check` 按频道可见性重新过滤；private 移除成员后 total 0、savedIds 空。 private 频道成员被移除后 `POST /read`、`/read-all`、`/unread` 均 404。 read receipts 开启的 Server：`GET /api/channels/:id` 带 `peerReadStates`，只含 agent peer；关闭时字段缺失；removed agent 不出现。 超过 50 个 agent peer 时改为 `peerReadSummary{peerCount,readCountAtSeq}`，否则 `peerReadStates` 全量（含 seq 0）。 `GET /internal/agent-api/history` 与 `/internal/agent/:id/history`：`messages/has_more/has_older/has_newer/last_read_seq`，支持 before/after/around/limit 与 `#parent:shortid` thread ref；消息含 senderType/senderId/senderName/createdAt/attachments；读取推进 agent cursor 并反映到 peerReadStates。 `POST /internal/agent-api/resolve-channel` 回 `{channelId,type}`，private 非成员 404；`POST /internal/agent-api/channels` 创建频道（agent 自动加入，不占 human membership）。 `GET /internal/agent-api/server`：runtimeContext/serverRole/capabilities/channels（joined 按 agent membership）/agents。 agent-api 的 channel PATCH、members POST/DELETE、server PATCH：member agent 403 `server_role_required`（固定文案）；owner/admin 可改；channel create 返回 type/createdByAgentId，`visibility:private` 同步 private kind；members POST 返回 `alreadyMember`/`member`，DELETE 返回 `wasMember`/`member`/`attention`（thread follows 警告）；channel PATCH 返回 type，server PATCH 返回 id/name。 `GET /internal/agent-api/mentions?limit=` 最新在前，返回 `has_more`。 `PATCH /api/tasks/:id/unclaim` 任意频道成员可清空 assignee（claimedById null），revision+1。 `PATCH /api/tasks/:id/status` 仅当前 assignee 可 in_progress→todo（否则 409）；todo 清 claimedAt；in_progress stamp claimedAt。 `GET /api/channels/:id` 带 channelRole/channelAdminBasis/channelAuthorityRevision/channelCapabilities；roster humans 带 serverRole/effectiveChannelRole/channelAdminBasis/canChangeChannelRole。 `PATCH /api/channels/:id/members/user/:memberId/role`：channel/server admin 可改；self demote 409 `channel_admin_self_demote_forbidden`；server role 目标 403 `protected_server_role`；archived 409；authorityRevision 递增。 channel admin（local role）可 POST archive/unarchive；archived 下 PATCH/members/role/leave 均 409 `channel_archived`。 channel admin 可 add/remove 成员；普通未加入 private 的 server member POST members 404；DELETE channel 仅 server owner/admin。 `GET /api/channels/:id/agents` 按频道可见性 404；server admin 对未加入 private 的 agents/remove/archive/patch 均 404，但仍可 add members。 `POST /api/channels/:id/join` 仅 public；private 403。 visibility 切换：列表对 private 仅成员可见，detail/messages 非成员 404，响应带 `type`，成员与 agent 行保留。 列表中的虚拟 #all `joined:true`；创建名为 `all` 的频道 400。 `POST /api/channels/threads/follow|unfollow` body `{threadChannelId}`；`GET /api/channels/threads/followed` 立即反映。 `GET /api/channels/inbox` 响应头 `Cache-Control: private, no-store`。 `GET /api/channels/inbox/unfollowed` 返回冻结在 unfollow 边界的 thread history（replyCount/latestActivityMessageId/unfollowedAt），`q` 只搜索边界前消息；refollow 移除；同样 no-store。 `GET /api/attachments/upload-capabilities`：directUpload false；free 50MiB / pro 90MiB；threshold/session null。 `POST /api/attachments/upload-sessions` disabled 403 `UPLOAD_FORBIDDEN`；GET/DELETE/complete 未知 404 `UPLOAD_SESSION_NOT_FOUND`。 `GET /internal/agent-api/attachment-upload-capabilities` 返回同一 plan limits。 `POST /api/channels/:id/members/batch` 响应 `added`/`alreadyMembers`（userIds/agentIds），去重且幂等。 batch 先整体校验 userIds；非 Server 成员 400 `users_not_in_server` + `invalidUserIds`，且不部分写入。 `GET /api/channels/:id` 带 `joined`（regular 非成员 false、private 成员 true、DM recipient true）。 `POST /api/channels/:id/threads` 幂等返回 threadChannelId/replyCount/lastReplyAt/participantIds；无 content 不造 reply；父消息作者计入 participant。 `GET /api/channels/:id/threads` 最多返回最新 100 个 parent 的 summary。 `GET /api/channels/:id/threads/:messageId` 返回 thread summary；parent 必须属于该 channel，否则 404。 thread channel 上 members add/remove/role、join/leave 均 400，错误提示 follow/unfollow。 public→private 会 prune 不在 private snapshot 的 thread follows。 parent 频道 public 时，非成员可读 thread info/history（private→public 恢复 permalink）。 `GET /api/channels/:id/members` 对 thread 返回 parent channel roster；`GET /internal/agent/:id/channel-members?channel=#parent[:short]` 同样投影 parent members。 `GET /api/channels/:id/threads` 回 `{parentMessageId:{threadChannelId,replyCount,participantIds}}`；频道不可见 404。 默认 `GET /api/channels` 排除已归档频道；`?archived=include` 返回归档频道，每行带 `archivedAt`（active 为 null）。 `activityMuteSupported` 仅普通 channel 为 true；DM 在列表、详情、notification-settings GET/PATCH 和 DM 列表都为 false。 `GET /api/channels/unread` 省略 unreadCount=0 的频道；自己发送的消息不计入未读。 `POST /api/channels/:id/unread` 把未读游标设到最后一条他人消息之前，返回 `{unreadCount}`；最新消息是自己时也至少把上一条他人消息记为未读。 `PATCH /api/channels/:id` 改名写入 system message 并回 `systemMessageSeq`；仅改 description 不写、seq 为 null。 `GET /api/channels/unread?summary=1` 的 `hasMention`/`hasAnyMention` 来自该频道内当前用户的 user mentions；readState 带 maxReadSeq 与 latestActivity。 `GET /api/channels/threads/followed` 回 `{threads:[{threadChannelId,unreadCount,taskId,taskClaimedByType,taskClaimedById,taskClaimedByName}]}`。 `GET /api/channels/threads/followers?threadChannelIds=` 回 `{threads:[{threadChannelId,canManage,agents:[{id,name}]}]}`；owner/admin 或 parent message 作者 `canManage:true`，普通 viewer false。 `DELETE /api/channels/threads/:threadId/followers/agents/:agentId` 仅 owner/admin 或 parent 作者可删（普通 viewer 403），回 `{removed,undoToken}`；`POST .../restore` 恢复 agent。 `POST /api/channels/:id/read` body `{seq}`：单调推进，回 `{ok,maxReadSeq,readStateVersion}`；`POST .../read-all` 推进到最新，回 `{ok,seq,readStateVersion}`；重复 read 不回退、不递增版本。 `read-all` 可带 `{receiver:{kind:"agent",id}}`：owner/admin 或 agent 创建者可代读，更新 agent cursor 不动 human；human receiver 或普通 member 403。 `GET /api/channels/:id/members` 的 agent 带 `activity`/`activityDetail`，来自批量 activity 状态；未设置时 `offline`/空串。 `GET /api/announcements/active?after=` 回最旧未读公告 `{announcements:[{id,title,pages}]}`，after 跳过失败行，非法 UUID 400，未登录 401；`POST /api/announcements/:id/dismiss` 200/404。 `GET /api/messages/context/:shortId?channelId=` 解析半开前缀短 id；server 成员即使未加入 public channel 也能读 `{channelId,targetMessageId,messages}`；非法 id 400。 `GET /api/channels/inbox` 的 item 带 `kind`、`unreadCount`、`hasMention`；channel 带 `channelId`，thread 带 `threadChannelId` 与 `isFollowing`。 响应同时带 `totalUnreadCount`，等于各 item 的未读之和。 `GET /api/channels/inbox?filter=mentions|unread` 分别按 user mention 与 unread>0 过滤。 inbox item 还带 `firstUnreadMessageId`（无未读时为 null）。 用户回复 thread 会自动 follow 该 thread，随后出现在 followed 列表。 `GET /api/servers/unread-summary` 跨 Server 聚合 joined regular channel 未读（含 human 消息），返回 `[{serverId,unreadCount,serverPushMuted,activityUnreadCount}]`，`Cache-Control: private, no-store`，无需 X-Server-Id。 `GET /api/channels/:id` 也带 `maxReadSeq` 与 `readStateVersion`。 `GET /api/messages/channel/:id` 支持 `before`/`after` 游标；非法或同时提供回 400 `{code:"invalid_message_page_cursor"}`；`before=0` 回空页。 `PATCH /api/channels/:id` 的 `visibility:private|public`：需 owner/admin 且频道成员；#all 403 `all_channel_visibility_managed_separately`（固定文案）；非成员 403 `channel_membership_required`。 `GET/PATCH /api/servers/:id/sidebar-order`：sort modes `manual|recent|az`；panel tab order 白名单过滤（agent 的 permissions 被移除）；非法 400。 `sidebar-order` 还支持 `customSections/sectionOrder/sectionPlacements/sectionsVersion`：section 名 trim、system section 补齐、失效 channel placement 丢弃、position 重排、版本冲突 409 `SIDEBAR_SECTIONS_VERSION_CONFLICT`。 `channelOrder` 会过滤已删除 channel；只改 section 的稀疏 patch 保留 live channel order。 `DELETE /api/channels/:id/members/user/:memberId`（self 或 owner/admin）与 agent 路由在归档时 409 `channel_archived`；unarchive 后恢复。 归档频道冻结全部写路径：PATCH channel、members add/batch/remove、join/leave、threads create、messages、internal agent send/join/leave 都回 409 `{code:"channel_archived"}`。 `POST /api/channels/:id/members` 支持 `{userId}` 与 `{agentId}`；`/members/batch` 支持 `userIds`/`agentIds`。 `GET /api/servers/:id/member-graph` 只投影可见 regular channel 与 #all；排除 private/archived/DM/thread、deleted agent；不含 email/env。 `GET /api/servers/:id/members` 要求 X-Server-Id 匹配，缺失/不匹配 400；非成员 403；非 admin 看不到他人 email。  响应带 `historyLimited` 与 `messageWindow`（含 `schemaVersion,domain,serverId,receiverKind,receiverId,scopeId` 及 `coveredFromSeq,coveredAfterSeq,coveredThroughSeq,remoteHighWaterSeq,hasGap,hasNewer,completeThroughLatest`）；空频道回 from=1/through=0/highWater=0。 `POST /api/channels/inbox/done`（channel）与 `POST /api/channels/threads/done`（thread）回 `{ok:true}` 并抑制对应 inbox/followed 条目；thread 传给 inbox/done 404；`POST /api/channels/inbox/read-all` 回 `{ok,markedCount,scopes:[{scopeId,maxReadSeq,readStateVersion}]}`。 `GET /api/channels/inbox/done?limit=` 回已 done scope（thread 含 `isFollowing`）；`POST /api/channels/threads/undone` 恢复 thread。 `GET /api/channels/unread` 排除父频道已删除的 thread。 `GET /api/channels/threads/followed` 同样排除父频道已删除的 thread。 `POST /api/message-translations:batch`：server translation 关闭时 403 `{error:"Translation is disabled for this server"}`；未登录 401；开启时可见消息回 `translated`（原文直通），不可见/跨 Server 回 `not_found`；外部 provider 未接。 `GET/PATCH /api/auth/me` 新增 `preferredLanguage,preferredTimezone,preferredTranslationMode,autoTranslationEnabled,preferredTranslationDisplay,preferredTimeFormat,preferredMessageBodyFontSize`；默认 mode `off`/auto false；值规范化；非法 400。 `PATCH /api/auth/me` 支持 `referralSource`（7 个枚举值）、`referralSourceOther`（仅 other，trim 200）、`referralSourceSkipped`；非法 source 400；other 无 source 400。 `PATCH /api/servers/:id/members/:memberId`：仅 owner 可改角色（admin/member 403）；可升/降 owner；改自己 400；目标非成员 404；`POST /members` 仍 404。 `POST /api/servers/:id/leave` 移除 admin 与 member，唯一 owner 仍 400；存在另一个 owner 时 owner 可离开。 `GET /api/channels/activity/snapshot` 与 `/difference` 当前 400，但都带 `X-Raft-Contract: raft.activity-sync;revision=2` 和 `Access-Control-Expose-Headers: X-Raft-Contract`；客户端 revision 取值不影响结果。 `GET /api/servers/:id/setup-projection`：owner/admin 回 `surface:"computer_runtime"`、`phase`、`gateReason:"computer_offline"` 等；member 回 `surface:"none"`、`gateReason:"insufficient_permission"`；`POST .../setup-transition` 支持 `start`/`reset`/`return_to_server`，`defer`/`advance` 400 `INVALID_SETUP_ACTION`，member 403 `INSUFFICIENT_PERMISSION`。 `POST /api/channels/:id/members` 加 Agent，`DELETE /api/channels/:id/members/agent/:agentId` 移除，均回 `{ok:true}`；legacy `/channels/:id/agents` 路由保持 404。`GET /api/servers` 行带 `slug` 和 `role`。 `GET /api/servers/unread-summary` 为每个成员 Server 回 `{serverId,unreadCount,serverPushMuted,activityUnreadCount}`；`activityUnreadCount` 是 joined 频道未读之和（known zero 也出现）；非成员没有条目；mute 不改变计数。 `POST /api/share-artifacts/message-selection`（Guest 403，频道须属当前 Server）回 `{id,url,imageUrl}`；`GET /share/:id` 回 200 HTML（`X-Robots-Tag: noindex, nofollow`，含 robots/twitter:card/twitter:image/og:image 尺寸/alt/share-card 样式）；`GET /share/:id.png` 回 1x1 PNG，`Cache-Control: public, immutable, max-age=31536000`；坏 id 404。 `GET /api/version`（无鉴权）回 `{version,sha,builtAt,branch}`；缺 `SLOCK_RELEASE_SHA` 时 503 `{error:"Build identity unavailable",code:"build_identity_unavailable",detail:...,sha:null,builtAt,branch}`。 `GET /api/tasks/server` 支持 `limit`（1-500）/`cursor`/`detail=full|summary`/`status`，按 channel name + taskNumber 稳定排序，每个 task 只出现一次；cursor 是 base64url `{c,n}`，坏值/未知 channel/重复参数 400；无分页参数保持 legacy `{tasks}`，summary 省略 description 并给 `hasDescription`/`descriptionBytes`。 `DELETE /api/tasks/:id`：owner/admin 或 task 创建者可删；删除后频道列表不再出现、按编号查询 404；未知 task 404。 `POST /api/auth/me/timezone-observation`（需登录）只接受 `{timezone}`，trim 后须是 IANA 且 ≤128 字符；首次值保留，last 每次更新；`GET /api/auth/me` 带 `firstObservedTimezone`/`firstObservedTimezoneAt`/`lastObservedTimezone`/`lastObservedTimezoneAt`；坏 body 400。 public 翻译与成员端点共用 120/min IP 预算：前 120 次仍做参数校验（400），第 121 次 429 `Too many public translation requests, please slow down`。 `GET /api/channels/:id/members`：Server 成员可读；回 `{agents:[{id,name,activity,activityDetail}],humans:[{id}]}`；public 频道无需加入，private 需参与；未登录 401。`/oidc/:server` 家族对语法坏的 segment 一律 400；未挂载的 `authorize/human`、`installation-token`、`clients/lookup`、`requests/agent` 是 404；scoped userinfo/serverinfo 的令牌 Server 必须与 segment 一致，否则 401；scoped jwks 和 discovery 可用。`/oidc/<slug>/.well-known/openid-configuration` 的 issuer 和 endpoints 都带 `/oidc/<segment>`（用 id 也可以）；unscoped authorize 再带 `server` 查询参数是 400 且说明 no longer supported；scoped authorize 的 setup 重定向带 `server=<slug>`。同一个 code 在别的 Server 的 mount 上换票是 400 `invalid_grant`；在自己的 slug 或 id mount 上都能换。未知 scope 是 400 `OAUTH_SCOPE_UNSUPPORTED`；`winbox`、`winbox-315c18` 等旧 client 的既有 legacy scope 元组只对这些 client 保留（`winbox:opencli:twitter` 换 client 或换新 scope 都仍拒绝），`app_admin` 也拒绝。没有 `acceptTerms: true` 时是 422 `LEGAL_ACCEPTANCE_REQUIRED`，并带上当前协议版本 `2026-05-12`；版本对不上是 409 `TERMS_CHANGED`。这两种都不会建账户。`POST /api/auth/google/complete` 在首次登录还没有账户时，缺协议是 422 `LEGAL_ACCEPTANCE_REQUIRED`，完成码仍可再用；带上当前协议版本才回 200，签发 `accessToken` 和 `refreshToken`，协议来源是 `oauth`。已经绑定账户的完成不要求协议，回 `provider`、`mode`、`returnTo` 和两枚 token，同一完成码再用是 400。`mode` 为 `link` 时必须是该账户的 Bearer：没有凭证是 401 `auth_required`，别人的凭证是 403 `link_user_mismatch`，这两种都不消耗完成码。所有者完成回 `mode: link`，不签发登录 token，只留下一条身份，同一完成码再用是 400。过期的 access token 绑定时是 401 `auth_required` 且不消耗完成码；`POST /api/auth/refresh` 用登录发的 refresh token 换一张新的 access token，这张 token 仍能完成同一次绑定。带上同一对 `X-Slock-Auth-Refresh-Attempt-Id` 和 `X-Slock-Auth-Installation-Id` 重放已用掉的 refresh token，两次都回 200 且后继 token 相同；收据里的密文不是明文。错的绑定或拿掉请求头是 401。坏的 installation 是 400，不消耗前驱。`POST /api/auth/logout` 撤销这个 family 之后，重放是 401。桌面回环 `GET /api/auth/google/callback` 在 state 里的 desktop nonce 和返回地址 `#state=` 不一致时回纯文本 400 `Invalid mobile OAuth request`，不向 Google 换票，事务保持 `pending_provider`。nonce 一致时 302 回那条回环地址，hash 原样留下，并带一次性 handoff code。浏览器直接拿这个 code 调 `/complete` 是 400，事务停在 `provider_completed`。`POST /api/auth/mobile/oauth/complete` 要 PKCE verifier 和当前协议，成功后用户邮箱来自 provider profile，名字是 `pending_`，`profileSetupProvider` 是 `google`；再用同一 code 是 410 `handoff_code_consumed`。不在允许列表里的返回地址，例如 `https://evil.example.test/oauth/callback`，启动时是 400 `return_uri_not_allowed`，不会留下事务。`raft-debug://oauth/callback` 也是允许的返回地址。非空的 `MOBILE_OAUTH_RETURN_URI` 会整表替换这五个默认值；它为空时，非空的 `MOBILE_OAUTH_ALLOWED_RETURN_URIS` 同样替换默认值，所以只配置 `raft-legacy://oauth/callback` 时这次启动回 201 并回显该地址，同时 `raft-debug://oauth/callback` 变成 400。桌面回环不看这两张表。默认列表里的 `raft-beta://oauth/callback` 启动回 201 并回显；请求里没有 `returnUri` 是 400 `return_uri_not_allowed`，也不会留下事务。回调查询带 `error=access_denied` 且没有 code 时，302 回应用地址，`error` 是 `access_denied`，事务变成 `failed`，不向 provider 换票。有 code 但换票失败时同样 302 回 `raft-debug://oauth/callback`，`error` 是 `provider_exchange_failed`，事务变成 `failed`，不会改走网页回调。签过名但没有对应事务的 mobile state 是纯文本 400，响应里没有 `Location`。交接码过期后，`POST /api/auth/mobile/oauth/complete` 在 PKCE 和协议检查之前回 410 `handoff_code_expired`，不建账户，事务变成 `expired`。verifier 对不上是 400 `pkce_mismatch`，不建账户、不签发会话，事务变成 `failed`。`POST /api/auth/mobile/oauth/:provider/link/start` 没有 Bearer 时是 401 `auth_required`，不留下事务。所有者的交接码在 `.../link/complete` 回 200，`mode` 是 `link`，身份里的 `providerEmail` 来自 provider profile，`providerUserId` 记在所有者账户上，响应不含登录 token，也不新开会话。别人的 Bearer 是 403 `link_user_mismatch`，交接码仍可用。登录模式的交接码拿到 `.../link/complete` 是 400 `mode_mismatch`，不建账户，事务仍是 `provider_completed`。`POST /api/auth/me/avatar` 收下名为 `avatar` 的图片后回 200，`avatarUrl` 是 `/api/avatars/users/` 加 32 位十六进制再加 `.webp`，`GET /api/auth/me` 读回同一地址。超过 5 MB 是 400 `PROFILE_AVATAR_TOO_LARGE`，`maxBytes` 是 5242880，已保存的地址不变。`PATCH /api/auth/me` 的 `shareUsageData` 在选择前是 null。`true` 保留已有的 analytics id，`false` 删掉这条映射，`null` 只把选择清回未决定。关掉后再打开会发一个新 id。其它值是 400。`GET /api/auth/providers` 缺省平台是 web。`platform=desktop` 是 400 `platform_invalid`。Google 和 GitHub 配了 client 就开；Apple 还要该平台的允许规则，只有 web 的规则不会打开 mobile。规则打开前，`GET /api/auth/apple/start` 和 `POST /api/auth/apple/link/start` 是 404；打开后，start 302 到 `https://appleid.apple.com/auth/authorize`，`response_mode` 是 `form_post`，link 的 `url` 也是。只有 web 规则时，Apple 的移动 start 仍是 404。取消的 form post 302 回应用，`error` 是 `user_cancelled_authorize`。带 code 的 link form post 只 302 出一个完成码，不写身份。没有 Bearer 是 401 `auth_required`，别人的 Bearer 是 403 `link_user_mismatch`，这两种都不消耗完成码。所有者完成回 `mode: link`，不签发登录 token，身份里的 `providerUserId` 是 Apple 的 `sub`，同一完成码再用是 400。未验证的 Apple 邮箱不能留下：网页 link 的 form post 302 的 `error` 含 `not verified`，且没有完成码；移动 link 302 的 `error` 是 `provider_exchange_failed`，事务变成 `failed`，`providerUserId` 仍是空，身份表没有 Apple，账户的邮箱验证状态保持 false。原生 Apple iOS 登录在移动闸门或 client secret 缺失时 start 是 404；`platform` 不是 `ios` 是 400。成功的 start 回 201，带 `requestToken`，不带 `authorizationUrl`。过期的 request token 是 410 `native_apple_request_expired`，错误算法和串到别的请求的 token 是 400 `native_apple_invalid_credential`，这三种都不去换票，事务保持 `pending_provider`。两边身份令牌的 `sub`、nonce 和邮箱一致后才发一次性 handoff，换票表单的 `client_id` 是 `build.raft.app`，`grant_type` 是 `authorization_code`，没有 `redirect_uri`。再用 authorize 是 410 `native_apple_request_consumed`。缺协议是 422，handoff 还在；补上当前协议后完成，再用是 410 `handoff_code_consumed`。两路 authorize 同时打到同一请求时，先把事务改成 `provider_processing` 再去换票：输的那路在赢家还停在换票里时就是 410 `native_apple_request_consumed`，换票只发生一次，赢家 200 后事务是 `provider_completed`，`codeHash` 是 handoff 的 SHA-256。数据库行的 `expiresAt` 已经过去时，即使签出的 request token 仍在 JWT 有效期内，authorize 也是 410 `native_apple_request_expired`，不去换票，事务变成 `expired` 而不是 `provider_processing`，`codeHash` 仍是空，`expiresAt` 保持写下的那个过去时刻。原生 Apple 的 link 没有 Bearer 时，start 和 authorize 都是 401 `auth_required`，别人的 Bearer 在认领事务前是 403 `link_user_mismatch`，这两种都不去换票、也不写身份。所有者 authorize 只发 handoff，身份要等 link complete。之后同一 Apple subject 的登录即使身份令牌不带邮箱，也会用已验证的 `providerEmail` 回到这个账户，不再要协议。第一次登录如果两边令牌都没有邮箱、库里也没有这个 subject，是 400 `native_apple_invalid_credential`，事务变成 `failed`。nonce、audience、subject、邮箱或邮箱验证对不上时同样是 400 `native_apple_invalid_credential`，事务变成 `failed`，再 authorize 是 410 `native_apple_request_consumed`。缺协议时是 422 `LEGAL_ACCEPTANCE_REQUIRED`，交接码和 `provider_completed` 都还在，补上当前协议后同一 code 仍能完成。GitHub 的授权地址主机是 `github.com`，完成后 `profileSetupProvider` 是 `github`，身份里的 `providerUserId` 来自 GitHub 用户 id；刷新得到的 access token 读 `/api/auth/me` 仍是这个未完成身份设置的账户。`Reminders` 这类保留用户名在建账户前回 400 `This username is reserved. Choose another name.`，不写协议、不签发会话。当前版本会建账户，用户名先记成 `pending_` 加 20 位十六进制，最终名字留在 `profileSetupSuggestedHandle`，`profileSetupCompletedAt` 是 null，所以同一个最终名字和大小写不同的名字都能各建一个账户。来源是 `signup` 或 `invite`，并记下协议地址、User-Agent 的 SHA-256 和 `Accept-Language`。所有者读到的 `exposedChannels` 就是匿名页面会列出的访客可见频道；所有者打开开关后，匿名 `GET /api/public/servers/:slug` 立刻变成 200。索引的 lastmod 只随页面上看得见的编辑移动，私有频道的改名不动它。`GET /api/release-notes` 匿名列出已发布和已撤回的版本，草稿不出现；`limit` 超出 1–100 是 400 `invalid_limit`，坏 cursor 是 400 `invalid_cursor`；详情要 UUID，未知 id 是 404 `not_found`。`GET /api/servers/:id/members` 在查询前拒绝非 UUID 的 `:id`，回 404 `Server not found`；UUID 和 `X-Server-Id` 不一致时回 400，不会变成 500，正文也不含数据库错误。`GET /api/servers/:id/members/:memberId/profile` 在同一道服务器门之后，非 UUID 的 member id 回 404 `Member not found`。`GET /api/messages/context/:messageId` 在查找前拒绝既不是完整 UUID、也不是 8 位十六进制短 id 的路径，回 400 `Invalid message id`；`channelId` 不是 UUID 时回 400 `Invalid channel id`。短 id 只在该频道恰好命中一条消息时回 200，正文带 `targetMessageId` 和这条消息。`GET /api/messages/channel/:channelId` 对非 UUID 回 404 `Channel not found`；UUID 但看不见的频道回 404 `Channel not found or not visible`。`GET /api/public/servers/:slug` 返回服务器名称、slug、翻译开关、`canJoinAsGuest` 和 `translationAvailable`，并只列出访客可见的普通频道。标成 guest-visible 的私有频道不会出现，也读不到消息。公开频道消息是窄投影：展示名、过滤后的头像、回复预览，不含发信人 id 和任务元数据。附件只留文件名、类型、大小和宽高；提及只留仍出现在正文里的名字和展示名；反应只留表情和次数。缩略图地址、存储键和反应者 id 不出现。没有存储记录的 `@名字` 只在它是当前成员或未删除的本服务器 agent 时标出；代码里的 `@名字` 不算。外部来源的正文不查这张目录，只保留已经存下的提及。`GET /api/public/servers/:slug/attachments/:attachmentId` 每次按那条公开消息重判：普通公开频道上的图片内联返回，HTML、SVG 和 `?download=1` 是下载，`Cache-Control` 是 `no-store`。草稿、私有或已归档频道、别的服务器的 slug，以及关掉公开之后，都和找不到附件一样是 404。对象存储能签名时改为 302，地址有效 60 秒，`Cache-Control` 仍是 `no-store`。PDF 只有带 `?disposition=inline` 且没有 `download=1` 时内联，响应用 `frame-ancestors` 而不是 `sandbox`，并且不带 `X-Frame-Options`。HTML 和 SVG 即使请求内联也仍是下载。对象存储签 PDF 时也按这个选择：内联请求签成 `inline`，普通请求签成 `attachment`，有效期仍是 60 秒。同一 IP 每分钟最多 120 次公开附件请求，第 121 次在查找前回 429 `Too many public attachment requests, please slow down`。只有所有者能改访客加入：公开之前打开是 409，管理员是 403；关掉公开时这次写入会同时清掉访客加入。已登录的自助加入在协议打开时，缺 `agreementId` 是 409 `agreement_required`，不会先写入成员；正文里的 role 和 source 不能把角色抬成 member，重复加入只留下一个 guest，审计来源是 `join`。访客加入关掉、访客总开关关掉，或公开总开关关掉时，自助加入都是和不存在的 slug 一样的 404，并且不会留下成员。发给本人的 Guest 邮件邀请在公开和访客加入都关掉时仍然可以接受，成员角色用邀请上存的 `guest`，不看公开自助加入开关。未登录的 `POST /api/messages` 和 `POST /api/channels/:id/join` 在写入前回 401 `auth_required`，公开消息地址没有 POST，所以匿名尝试留不下消息或频道成员。成员的 `GET /api/servers` 只带 `publicPageLive`：服务器公开且总开关打开才是 true，不返回 `publiclyVisible`，并和匿名公开页是否 200 一致。未公开的 slug 是 404，不是 403。`Cache-Control` 是 `no-store`。第三方头像是 null，存在本服务的 `/api/avatars/server-…/*.webp` 会留下。服务器不再公开后，这一页和它的频道消息都立刻变成 404 `Not found`。`GET /api/public/servers/:slug/channels/:channelId/messages` 对非 UUID 回 404 `Channel not found`，`.../threads/:threadChannelId/messages` 对非 UUID 回 404 `Thread not found`。UUID 但匿名读不到时是不带 `path` 的 404 `Not found`。`/api/mcp/agents/:agentId` 和 `/api/integrations/agents/:agentId` 对非 UUID 回 404 `Agent not found`；`/api/integrations/clients/:clientId/...` 和 marketplace 安装路径对非 UUID 回 404 `App not found`。MCP 上一个不存在的 UUID agent 再带 `code` `managed_mcp_agent_not_found`。`POST /api/public-visits/:slug` 不论 slug、来源或正文是否有效，都回空的 204，`Cache-Control: no-store`。同一站点上的合法访问会计入该公开服务器：匿名、已登录非成员、已登录成员由服务器决定；只有选择分享用量的登录访客带 analytics id。浏览保留 `entry`、注册域和合法的 utm，坏字段只丢掉它自己；打开频道只保留小写的频道 id。打开线程只在该线程还活着、且父消息就在所给的公开频道里时计数，并同时留下这两个 id。同意后的匿名访客 id 只进访客表，并改成小写；访问事件里没有它。坏 id 只丢掉这个字段，登录后的浏览不写访客表，访客 id 开关关掉后访问仍计数。以访客加入时，只有选择分享用量的人会记 `public_page_server_joined`，事件里只有 `has_visitor_id`，id 本身仍在访客表。访问事件带上粗粒度的浏览器、系统、设备和两位国家码，不保存原始 User-Agent。重复的 uuid 只计一次，超过当日上限就不再记。`GET /api/public/servers/:slug` 在访客 id 会被留下时给出 `visitorIdMode`：未知或需同意的国家是 `ask`，其余默认开启，`Sec-GPC: 1` 则默认关闭。允许的 `Origin` 上，`OPTIONS` 预检回 204，`Access-Control-Max-Age` 是 7200。`/api/version` 读 `RAFT_RELEASE_SHA`、`RAFT_BUILD_AT`、`RAFT_RELEASE_BRANCH`（旧名 `SLOCK_*` 必须与之相同）；身份不齐时回 503 `build_identity_unavailable`。服务器版本是这个源标签的 `1.21.23`。`/health` 的数据库探测是注入的；`/livez` 不在请求路径上探测。`RaftHTTPServer` 用 Vapor main `0f2a8ee`（钉住 swift-collections 1.6.0；5.0.0-beta.1 和 beta.2 在 Swift 6.4.1 上编不过）把这些响应挂到 `Application` 上，`RaftServer` 是进程入口。进程在接上数据库之前，`/health` 回 503。`/daemon/connect` 仍由 SwiftNIO 单独监听。


thread 内发送带 mentions 的消息会自动 follow 被提及的 human 与 agent，并出现在其 followed 列表。


thread 发消息要求 parent channel 成员身份（follow 不授予写权限）；非成员 403，parent 成员无 follow 也可发。


`GET /api/channels/:id/threads` 的每个 summary 带 viewer 维度 `unreadCount` 与 `firstUnreadMessageId`；只有 followed thread 才计数，未 follow 恒为 0/null。


`GET /api/channels/:id/threads` 的 summary 带 `latestReplies`（最多 3 条 conversation reply，system 只计入 replyCount 不进 preview），字段含 preview/senderType/senderId/senderName/senderDisplayName。


`GET /api/channels/:id/threads?parentMessageIds=a,b` 只返回指定 parent 的 thread summary；缺省时仍按最新 100 截断。


POST /api/channels/:id/threads 不写 content 时不创建 reply，也不自动 follow 创建者；只有带回复的 thread 才因发送产生 follow。


agent 向 thread 发送（`#parent:short`）要求 agent 是该 parent channel 成员；只在 thread 内 follow 的 agent 403。legacy machine key 也可认证 agent send。


`DELETE /api/agents/:id` 只接受 workspace `keep`/`delete`（缺省 keep）；其他值是 400 `archive_workspace_choice_invalid` 且不归档。


归档后的 `GET /api/agents/:id/archive` 返回 `{archive:{workspaceState,machineName}}`；workspace 选择 keep 时状态是 on_computer，选择 delete 时是 deleted；machineName 快照来自创建时的 machineId。未归档 agent 的 archive 视图 404。


`GET /api/channels/threads/followed` 的 `unreadCount` 也按 human reply + read cursor 计算，与 thread summary 一致。


`GET /api/agents/:id/channels` 返回 viewer 可见的 agent channel memberships（public/private/joint），含 description/type/createdAt/archivedAt/activityMuted/muteFromSeq；隐藏 private/joint、thread、DM、虚拟 #all 不出现。


`GET/PUT /api/agents/:id/scopes` 只对同 Server 成员开放；跨 Server 404。managed agent 的 PUT 是 422，external agent 接受 mode/default 并回 scope 集。


`GET /api/agents/:id/archive` 仅 owner/admin 可见；普通 member/guest 403，跨 Server 404。


`POST /api/agents/:id/archive/workspace` owner/admin 可把归档 workspace 改成 keep（on_computer）或 delete（deleted）；member/guest 403，跨 Server 404，非法 action 400。


`GET /api/agents/:id/workspace-files[/read]` owner/admin/creator 才可读；普通 member 403，跨 Server 404；没有在线 Computer 时 503 `daemon_offline`。


agent private surfaces（activity-log/activity-summaries/workspace-files/skills/agent-dms/channels）只对 creator 或 owner/admin 开放；普通 member 403，跨 Server 404。


agent create/GET 返回 `creator:{type:"human",id}`；`PATCH /api/agents/:id/creator` 仅 owner/admin，普通 member 404，可改 creator 为同 Server 成员。


`GET /api/agents/:id/runtime-options` 普通成员可读；`POST /api/agents/:id/bootstrap-tokens` 普通成员 403 `insufficient_role`，错误提到 issueAgentCredentials 与 human creator authority。


`GET /api/agents/archived` 对 member 及以上返回 `{agents:[{agentId,machineName,workspaceState}]}`；guest 403。


`GET /api/agents/:id/activity` 走 agent private surface 权限：creator/owner/admin 200（idle 占位），普通 member/guest 403，跨 Server 404。


external agent 的 start/stop/reset 都是 400 `External agents do not use Raft-managed runtime lifecycle`；assign-machine 是 400 `External agents cannot be assigned to a Computer`。


guest 读 `GET /api/agents/:id` 得到 bounded `profileProjection:"channel_summary"`，只含 id/name/displayName/avatarUrl/description，不含 runtime/model/envVars/creator。


managed agent 的 stop 对任意 Server 成员 200；reset restart/session 对成员 202 `{ok:true,status:"accepted"}`，full 仅 creator/owner/admin，普通成员 403 且 error 提到 resetAgentWorkspace。


managed agent 的 credentials/bootstrap-tokens mint 都是 400 `agent_not_external`；external agent bootstrap 201 且 scopes 为 `[channels,knowledge,mentions,reactions,read,send,tasks]`。


external agent 的 credential mint 返回 credentialId/apiKey/agentId/serverId/scopes；GET credentials 返回 masked inventory（不泄露 key）；DELETE credentials/:id 幂等 204，revoked key 打 internal agent-api 401；GET /internal/agent-api/ 回 agentId/credentialId/serverId/scopes。


external agent credential mint/list 响应带 `Cache-Control: no-store`。


external agent mint 接受请求体 `scopes`，返回去重排序后的 scopes；缺省返回默认 capability 集。


`GET /api/agents/:id/agent-dms` 返回 agent-to-agent DM `{id,peerId,peerName,lastMessagePreview}`；human DM 不出现，preview 跳过 system 消息。


agent credential 经 internal agent-api 使用后，inventory 的 `lastUsedAt` 非 null；同时 identity 返回 credentialId。


`GET /api/agents/:id/migration` 仅 creator/owner/admin；普通 member 403，跨 Server 404；无迁移时返回 `{migration:null}`；普通 member 403 `{code:"not_supported"}`。


`POST /api/agents/:id/migration/cancel` 普通 member 403 `{code:"not_supported"}`；creator/admin 在没有活跃迁移时 404 `{code:"migration_not_found"}`。


`GET /api/agents/:id/external-diagnostics`：member 403、managed agent 400 `agent_not_external`、缺失 404；external agent 返回最小 diagnostics 视图。


`PUT/DELETE /api/agents/:id/assistant-owner` 在 feature flag 关闭时 403 `{code:"assistant_not_enabled"}`；非 creator 的成员是 403 `{code:"assistant_requires_creator"}`。


真实进程启动时，HTTP 端口来自 `PORT`（默认 8080），`/daemon/connect` 由独立 SwiftNIO 监听器服务，`DAEMON_CONNECT_PORT` 默认 8081，`0` 关闭。启动打印 `raft-server ready http=127.0.0.1:<port> daemon-connect=127.0.0.1:<port>|disabled`。


真实进程对所有非 GET/HEAD 请求先缓冲请求体再进入路由，因此同步 handler 的 `request.body.string` 与 `app.testing` 一致；`/daemon/connect` 无 key 返回精确的 `HTTP/1.1 401 Unauthorized\r\nSlock-Reason: missing_key\r\n\r\n`，有效 Computer key 返回 101 加 `machine:context`。


machine key 形如 `sk_machine_` + 64 位 hex，computer key 形如 `sk_computer_` + 64 位 hex；`POST /api/computer/attach` 返回 `sk_computer_`，`POST /api/servers/:id/machines/:machineId/rotate-key` 返回 `sk_machine_`。


`RaftDaemon` 读取 `SERVER_URL` 与 `MACHINE_KEY`，完成 `/daemon/connect` 握手后打印 `daemon connected machine=... server=...` 并退出；真实重连循环仍留在 `DaemonLink` 库内。


`GET /socket.io/?EIO=4&transport=websocket` 返回 101，随后一帧 Engine.IO open：`0{"sid","upgrades":[],"pingInterval":25000,"pingTimeout":20000,"maxPayload":1000000}`。客户端 `40{"token","serverId","clientKind"}` 成功后回 `40{"sid"}`，再回 `42["rooms:joined"]`；非成员回 `44{"message":"Not a member of this server"}`；Engine.IO `2` 回 `3`，`41` 断开。clientKind 缺省为 `web`，非法值拒绝。


socket 房间为 `user:<id>`、`user:<id>:clientKind:<kind>`、`server:<id>` 或 guest 的 `server:<id>:guests`、`user:<id>:server:<id>`、`channel:<id>`；guest 不进 `server:<id>`，但可进自己的 guest 房间。`join:channel` 只接受该用户可见的频道，失败静默无回包。


`POST /api/channels` 成功后向 creator 的 `user:<id>` 房间发 `channel:updated`，payload 是 `{channel:{id,name,description,joined:true}}`。


`notification:push` 只发到 `user:<id>:clientKind:mobile`；其他用户事件仍发 `user:<id>`。


`DELETE /api/servers/:id/members/:memberId` 成功后，该用户在该 server 的 socket 最后收到 `42["server:membership-removed",{"serverId":"<id>"}]` 然后断开；同一用户在其他 server 的 socket 不受影响。


`POST /api/push/family-revoke` 204 后，属于该 session family 的 socket 断开，同用户其他 family 的 socket 保留。


agent 读游标前进且 server 开启 read receipts 时，`channel:<id>` 房间收到 `42["scope_read:updated",{"scopeId","peerKind":"agent","peerId","maxReadSeq"}]`；human 读操作不发。


`GET /api/channels/inbox` 返回 `{items,hasMore,totalCount,totalUnreadCount,activeUnreadCount,groups}`：channel row 有 `channelId,lastMessageId,firstUnreadMessageId,firstMentionMessageId,unreadCount,hasMention`，thread row 有 `threadChannelId,parentChannelId,latestActivityMessageId,...,isFollowing`。同一 scope 的多条 fact 聚合成一行；`channelId` 过滤把 thread 归到 parent；`q` 匹配内容或 sender 名；`limit/offset/sort` 分页；`filter` 支持 `all/unread/mentions/unread_mentions`；`scope=dms` 只保留 DM 与 DM thread，DM 标 Done 会同时隐藏其 thread；`groups` 聚合 parent channel 计数且不受分页影响；响应 `Cache-Control: private, no-store`。


`POST /api/servers/:id/machines` 仅 owner/admin，返回 `{machine:{id,serverId,name,userId,description},apiKey}`，key 为 `sk_machine_` + 64 hex；普通 member 403，缺 name 400，非成员 404。


`POST /api/servers/:id/join-links` 仅 owner/admin，返回 `{token,link:{id,token,createdAt,expiresAt,maxUses,useCount,revokedAt}}`；`GET` 只列未撤销、未过期、未耗尽的链接；`DELETE /api/servers/:id/join-links/:linkId` 撤销并返回 `{ok:true}`。邀请接受后 `useCount` 自增，耗尽或过期返回 400 `Invalid invite`。


`GET /api/servers/:id/system-notifications` 返回 `server-system-notifications-v1` replace 快照，`Cache-Control: private, no-store`；owner/admin/member 走 `viewMachines`，guest 空通知，非成员 403。离线 raw daemon 聚合成 `machine-offline:<ids>`，`kind` 按 active agent 数为 `error`/`warning`，managed Computer 不进入该 feed。


`GET /api/servers/:id/system-notifications-v2` 返回 `server-system-attention-v1` replace 快照；仅 owner/admin 且 `usage_limit_attention_v0` 开启时有内容，普通 member 空。每个 incident 带 `id/kind/severity/state/activatedAt/lastObservedAt/seenAt/machine/provider/windowKey/resetsAt/affectedAgentIds`，`unseenCount` 统计 `seenAt=null`。`POST .../:incidentId/seen|dismiss` 写 per-user receipt，`dismiss` 同时置 seen；非法 UUID 400，非 owner/admin、gate 关闭、跨 server 或非 active incident 404。


`GET /api/servers/:id/usage` 对成员返回 `{agents,machines,channels}`：agents 为非删除 agent 数，machines 为该 server 的全部 machine 数，channels 只计非归档 `channel/private`（不含 thread/DM）；guest 403，非成员 404，未登录 401。


`GET /api/servers/:id/machines/:machineId/workspaces` 仅 owner/admin 或 machine creator；返回该 server 自己 agent 的 workspace 目录，包含 live 与软删除 agent（`status` 为 `active/stopped/deleted`，带 `agentName/agentStatus`），其他 server 的 agent 不出现。`DELETE .../workspaces/:directoryName` 同样只允许自己的 agent，删除后不再出现在扫描结果；越权/未知目录 404。


`GET /api/servers/:id/machines/:machineId/runtime-options` 仅 owner/admin 或 machine creator；返回 `{context:"new_agent",machineId,options}`，每项含 `runtimeId/capabilityStatus/admissionStatus/admissionReason/current/availableForNew/manageableForCurrentAgent/canSelectInThisContext`。能力表来自 machine 的 `runtimes`：已上报为 `available`，纯内置未上报为 `update_required`，CLI 未上报为 `not_installed`；默认不提供 grok。`GET .../runtime-models/:runtime` 返回 `{kind:"live",value:{models,default},models,default}`；member 403。


`GET /api/servers/:id/machines/:machineId/runtime-account-usage/:provider` 仅 owner/admin 或 Computer attacher；provider 限定 `claude/codex/kimi/grok`，返回 `{state:"fresh|stale|missing",snapshot}`，`Cache-Control: private, no-store`，只含 masked label。`POST .../refresh`：`reason:"manual"` 时等待机器回复，fresh 200 `{accepted:true,state:"fresh",snapshot}`，timeout 200 `{accepted:true,state:"timeout"}`，offline 202 `{accepted:false,state:"computer_offline"}`；`stale_or_missing` 及后台路径 202 `{accepted:true,state:"requested"}`；同一 provider 60s 内重复 `{accepted:false,state:"cooldown"}`。普通 member 403。


运行时表单：`GET .../runtime-form-definitions/:runtimeId` 返回 v1 `{protocolVersion:1,runtimeId,schemaVersion,dataSchema,uiSchema,capabilities,optionSources}`，stale schema 409、未知 runtime 404；`GET .../runtime-form-definitions/:runtimeId/option-sources/:sourceId` 返回 provider/model source，未知 source 404。`GET .../runtime-forms/v2/:runtimeId` 返回 v2 字段表单并带 `Content-Language`/`Vary`，`Accept-Language: zh` 返回中文 label；v2 option source 不要求 schemaVersion。


`GET /api/servers/:id/model-label-catalog` 对任意成员（含 guest）返回 `{machines:{<machineId>:{runtimes:{<runtime>:{models:[{id,label}],updatedAt}}}}}`，只暴露 id/label/updatedAt；非成员 403。`POST /api/servers/:id/machines/:machineId/runtimes/rescan` 仅 owner/admin 或 machine creator，在线返回 `{requested:true}`，离线 409 `{error:"Computer is offline"}`。


`DELETE /api/servers/:id/invites/:inviteId` 仅 owner/admin，删除该 server 的 pending invite 并返回 `{ok:true}`；普通 member 403，未知 id 同样 200 幂等。


`POST /api/servers/:id/machines/:machineId/agents/:agentId/diagnostic/mention-delivery/:messageId/redrive`：非 UUID messageId 404 `NOT_JOINABLE`；无权/跨 server/未分配 machine 404 `NOT_ACCESSIBLE`；body 不是仅含非负整数 `expectedVersion` 时 400 `INVALID_REQUEST`；授权后无 occurrence 404 `NOT_JOINABLE`。


`GET /api/servers/:id/machines/:machineId/agents/:agentId/diagnostic/session-transcript`：非成员 404 `Server not found`，machine 不在该 server 404，agent 不在该 server 404，agent 未分配到 machine 400，无 owner/admin/creator 权限 403；machine 离线 409 `{error:"Computer is offline",code:"machine_offline"}`；在线返回 `{sessionId:null,transcript:[]}`。


`GET /api/servers/:id/machines/:machineId/agents/:agentId/diagnostic/mention-delivery/:messageId`：非 UUID 404 `NOT_JOINABLE`；无权/跨 server/未分配 machine 404 `NOT_ACCESSIBLE`；授权后无 occurrence 404 `NOT_JOINABLE`。


`POST /api/servers/:id/setup-reset` 仅 owner：admin/member 403 `INSUFFICIENT_PERMISSION`；server 已有 agent 时 409 `SERVER_ALREADY_SET_UP`；成功时重置 setup phase、撤销该 server 的 Computer，并在 projection 上追加 `revokedComputers`。`POST /api/servers/:id/setup-handoff` 仅 owner，缺失 server 404，非 owner 403，成功/重复调用都返回当前 setup projection。


`POST /api/servers/:id/machines/:machineId/computer-lifecycle-operations`：校验 `action/operationId/parentOperationId/targetVersion/completionMode`；仅 owner/admin 或 machine creator；非 managed Computer 409 `not_a_computer`；start 在线 409 `computer_already_online`、非 start 离线 409 `computer_offline`；upgrade 无 target 409 `computer_upgrade_unavailable`，带 `legacy_k_promoted` 409 ready pending；成功 201 返回 operation 投影。


`POST /api/servers` 新 server slug 少于 5 字符 400 `Slug must be at least 5 characters`；`POST /api/servers/:id/members` 未挂载 404；`GET/PATCH /api/servers/:id/product-analytics-settings` owner/admin 可写、member 只读；`GET /api/servers/:id/members` 缺/错 `X-Server-Id` 400，`GET /api/servers/:id` 非成员 403。


`GET /api/servers/:id/member-graph` 在 human directory 隐藏时对普通 member 403、owner 200；`GET /api/servers/unread-summary` 不需要 `X-Server-Id`，跨 server 返回成员所在 server 的行；`GET/PATCH /api/servers/:id/sidebar-order` 缺/错 `X-Server-Id` 400。


`PATCH /api/servers/:id/sidebar-order` 支持 typed `pinned` refs（`channel/agent/human`）：DM channel 归一化为 human/agent peer，private 不可见 channel 和不存在的人/agent 被丢弃，重复 ref 去重；返回 `pinned/pinnedChannelIds/pinnedAgentIds/pinnedOrder/pinnedVersion`，同值重放不升版本也不发事件；首次变更向 `user:<id>` 发 `pinned:updated` `{pinned,pinnedVersion}`；与 legacy `pinnedChannelIds` 混用或非法 kind 400。


已移除成员/已删除 agent 的 typed pin 保留（human 只要求账号存在），human pin 会带入其 DM channel 的 legacy id；legacy `pinnedChannelIds/pinnedAgentIds/pinnedOrder` 写入会保留 human typed refs，只替换 channel/agent 部分并升版本。


`GET/POST /api/agents/:id/onboarding-identity-adoption`：仅 owner/admin/creator，agent 必须是该 server 的 onboarding agent（否则 400）。GET 返回 `{canAdopt,changes}`，按 name/displayName/role/serverRole/avatarUrl 列出 before/after；POST 应用官方 Cindy 身份（Cindy / Cindy / Onboarding Assistant / admin / pixel:mug），返回 `appliedChanges` 和 `agent`，并广播 `agent:updated`；二次调用 changes/appliedChanges 为空；已有其他 active `Cindy` 时 409。


`GET /api/agents/:id/runtime-form`：仅 owner/admin/creator，external agent 404 `no_runtime_form`。返回 v2 `{protocolVersion:2,runtimeId,schemaVersion,fields,values,capabilities}`；`values` 从存储 runtimeConfig 投影 `model`/`envVars`，Claude 另带 `provider/apiUrl/reasoningEffort/fastMode/command` 且永不返回 `apiKey`，Antigravity 不返回 model；Claude 的 `writeOnlyPointers` 为 `["/apiKey"]`。


`GET /api/agents/:id/hosted-runtime`：仅 owner/admin/creator；非 hosted agent 404 `{code:"hosted_runtime_missing"}`；hosted agent 返回 `{hostedRuntime:{agentId,provider,model,state,retryNeedsModel,createdAt},onboardingSetup}`，响应 `Cache-Control: no-store`。


`GET /api/agents/:id/hosted-runtime/usage`：同一权限；`bucket` 只接受 `1h/1d`，`from/to` 必须为 ISO 且窗口 ≤31 天，否则 400 `hosted_runtime_usage_invalid_query`；未就绪 409 `hosted_runtime_usage_not_ready`；成功返回 provider usage body，`Cache-Control: no-store`。


`GET/PUT /api/agents/:id/hosted-runtime/model`：仅 owner/admin/creator；无 hosted runtime 404 `hosted_runtime_missing`，未 active 409 `hosted_runtime_model_not_ready`，均带 `Cache-Control: no-store`。GET 返回 `{models,default,defaultLabel,model,label,source,locked,picker}`，模型项只保留 `id/label/provider`。PUT 要求 body 含 `model`（id 或 null），非法 400 `hosted_runtime_model_invalid`；picker 关闭时非 Raft 默认模型 403 `model_picker_disabled`，命名 `deepseek-flash` 回落默认；未提供 422 `hosted_runtime_model_not_offered`；locked 且挑选非默认 409 `hosted_runtime_model_locked`；成功写回 `source` 为 `chosen/default`。


`POST /api/agents/:id/hosted-runtime/retry`：仅 owner/admin/creator；非 hosted 404 `hosted_runtime_missing`。`failed` 且 `retryNeedsModel` 时缺 `model` 返回 409 `hosted_runtime_model_required`；`failed`（无需模型）、`provisioning`、`deleting` 重新排队为 `provisioning`；`active`/`deleted` 等 409 `hosted_runtime_nothing_to_retry`。带 `model` 时非法 400 `hosted_runtime_model_invalid`；需要选型时 picker 关闭返回 403 `model_picker_disabled`，未提供 422 `hosted_runtime_model_not_offered`，locked 且非默认 409 `hosted_runtime_model_locked`；成功后返回 `{hostedRuntime}`。


GitHub 账号连接（`/api/agents/:id/connections/github`，provider 由注入的 relay 承担）：`GET` 返回 `{provider,supported,connected,account,connectedAt,connectedBy:{id,name},scopes,connectorId,connectors:[{id,account,createdAt,creator:{id,name,displayName},current,canManage}]}` 并 `Cache-Control: no-store`；其他 provider 404 `agent_connection_provider_unknown`；非 hosted 400 `agent_connection_not_provider_backed`；未 active 409 `agent_connection_agent_not_active`；普通成员/guest 403 `agent_connection_forbidden`（即使是 creator 的 guest 也拒绝）。`POST` 接受可选 `access:"private"`，其余 400 `agent_connection_invalid`，请求体带 `returnUrl`、`initiatedBy.raftUserId`（调用者）并返回 `{url,expiresAt,scopes}`。`POST .../confirm` 要求合法 `pending`（否则 400/404 `agent_connection_pending_invalid`），请求体用当前登录用户而非客户端 `by`。provider 404 按 agent lookup 分类：agent 存在 → `{provider,supported:false}` 或 409 `agent_connection_unsupported`；agent 不存在 → 409 `agent_connection_agent_missing_at_provider`；provider 4xx → 409 `agent_connection_provider_refused`（消息脱敏）；5xx → 502 `agent_connection_provider_error`。`PUT`/`DELETE .../connectors/:connectorId` 需要 connector creator 或 owner/admin（403 `agent_connection_connector_forbidden`），未知 connector 404，成功 assign 返回最新 status、删除 204；`DELETE /connections/:provider` 解除挂载 204。


Guest 角色降级后，其 follow 的 thread 从 `GET /api/channels/inbox`（`all` 与 `unread`）消失；`GET /api/messages/channel/:threadId` 对 guest 返回 403，即使该 thread 属于公开频道。


`POST/GET/DELETE /api/agents/:id/credentials`：未认证调用一律 401（不是 404），POST 也不要求 `X-Server-Id`。


`POST /api/agents/:id/migrate`（`target.kind:"hosted"`）：migration UI gate 关闭 403 `agent_migration_ui_disabled`；无权限 403 `not_supported`；hosted 迁移 gate 关闭 403 `HOSTED_TARGET_UNAVAILABLE`；hosted runtime 未启用/未知 provider 409/422 `HOSTED_TARGET_UNAVAILABLE`；`hostedModel` 非字符串/null 400 `HOSTED_TARGET_MODEL_INVALID`；无 source machine 409 `AGENT_HAS_NO_SOURCE_MACHINE`；已有 hosted runtime 409 `HOSTED_TARGET_ALREADY_USED`；已有 active migration 409 `MIGRATION_ALREADY_IN_PROGRESS`。成功返回 200 `{migrationRef,state,targetKind:"hosted",sourceMachineId,targetMachineId:null,prepDeadlineAt,transferDeadlineAt,arrivalDeadlineAt}` 并广播 `agent:migration-updated`。

`POST /api/agents/:id/migration/confirm-hosted`：migration UI gate 关闭 403 `agent_migration_ui_disabled`；agent 不在该 server 404 `AGENT_NOT_FOUND`；无 owner/admin/creator 权限 403 `not_supported`；hosted 迁移 gate 关闭 403 `HOSTED_TARGET_UNAVAILABLE`。`migrationRef` 必须匹配 `mig_` + 22 字符，否则 400 `MIGRATION_REF_INVALID`；`expectedRevision` 必须为正整数，否则 400 `MIGRATION_REVISION_INVALID`。未知 migration 404 `MIGRATION_NOT_FOUND`；revision 不符 409 `MIGRATION_REVISION_STALE`；state 非 `in_transit` 或 source machine 不符 409 `HOSTED_REVIEW_NOT_READY`；已有 hosted runtime 409 `HOSTED_TARGET_ALREADY_USED`。成功时 agent 切到 `external`、创建 provisioning hosted runtime、migration 变为 `arriving` 且 revision+1，返回 `{migration}` 并向 owner/admin 的 `user:<id>` 房间发 `agent:migration-updated`。


`POST /api/messages` 成功后向 `channel:<id>` 房间发 `message:new`，payload 是消息 HTTP body（id/channelId/content/attachments）。`POST /api/tasks/channel/:channelId` 成功后向同一房间发 `task:created`，payload 是 `{channelId,tasks:[{id,channelId,title,status}]}`；`PATCH /api/tasks/:taskId/claim` 成功后发 `task:updated`，payload `{channelId,task:<task JSON>}`；`POST /api/channels/threads/follow|unfollow` 成功后发 `thread:followers-updated`，payload `{threadChannelId}`。频道创建时该用户的在线 socket 自动加入 `channel:<id>`。task JSON 带 `messageId`。


消息 reaction 变更后向 `channel:<id>` 发 `message:updated`，payload 含 `id/channelId/content/senderName/commentRef/reactions`，不含 `agentSendKey/searchText/searchVector/reactionViewer/viewerVersion/reactedEmojis`。旧的 `messageUpdatedBroadcasts()` 侧通道已删除，断言走真实 socket。


`/daemon/connect` 接受握手后向 `server:<serverId>` 发 `machine:status`：online 为 `{machineId,status:"online",statusVersion}`，断开为 `{status:"offline",...,cause:"socket_close"}`；`statusVersion` 每次自增。

`GET /api/channels/:id/files` 的完整分页投影：`{files:[{id,messageId,channelId,filename,mimeType,sizeBytes,width,height,thumbnailUrl,createdAt,uploader:{type,id,name,displayName},source:{type,channelId,parentMessageId,parentMessageShortId}}],nextCursor}`；按 `createdAt` 降序、`id` 降序，包含该频道下 thread 的附件并带父消息 id 与前 8 位 short id。`limit` 默认 500、夹在 1..500；`cursor` 为 `{createdAt,id}` 的 base64url，非法 400 `Invalid cursor`；下一页游标取自本页最后一条。user/agent uploader 解析名称，非 UUID 或未知 uploader 名称 null；private 频道非成员 404 `Channel not found`。

消息历史 HTTP 读（`/api/messages/channel/:id`、`/api/messages/context/:id`、`/api/messages/sync`）不序列化 `searchText`/`searchVector`/`senderTimezone`。`POST /api/messages` 与 `/api/v2/messages` 存储合法 IANA `timezone`（trim，UTC 或含 `/`，≤128），无效/缺省为 null 且不失败；v1 回消息本体、v2 回 `{message}`，两者都不回显 `senderTimezone`。

`GET /api/agents/manageable` 不需要 `X-Server-Id`：`{ok:true,data:{agents:[{id,name,serverId,serverName}],reason,manageable_server_count}}`。跨 Server 合并；owner/admin 看本 Server 全部 Agent，普通 member 只看自己创建的；`reason` 为 `ok` / `no_agents_on_manageable_servers` / `no_manageable_server`，不返回 `suggested_next_action`。

任务频道可见性：public 频道的 Server 成员即使未加入频道也可 `GET /api/tasks/channel/:id`（200）与按编号读，但 claim/status/create/convert-message 均 403；private 频道非成员对 list/number/claim/convert 均 404。`convert-message` 能解析 API 发送的消息（human message 存储）。`GET /api/tasks/channel/:id` 与 `GET /api/tasks/server` 的 `status` 只接受单个合法值，未知或重复参数 400。

`/api/reminders` 对人是只读：`GET`（可选 `ownerAgentId`）对成员返回 `{reminders:[{id,title,ownerAgentId,fireAt}]}`；owner/admin 看本 Server 全部 Agent，普通成员只看自己创建的 Agent；显式指定不可检查的 Agent 403，未知 Agent 404。`POST /api/reminders` 与 `DELETE /api/reminders/:id` 未挂载，均 404。

`POST /api/feature-flags/evaluate`（成员限定）：`keys` 1–50 个合法 key（或 `key`）；`serverId` 必须为 UUID 且调用者是成员（否则 400/403）；`platform` 仅 `web`/`mobile`（否则 400）。求值顺序 kill switch → 未启用 → user → platform → client → server → 默认，返回 `{evaluations:[{key,enabled,reason}]}`，reason 为 `kill_switch`/`flag_disabled`/`user_rule`/`platform_rule`/`client_rule`/`server_rule`/`default`/`missing_flag`。client 规则按 `values` 命中 server，并要求 `clientOs`/`buildType`（`android|ios|ohos`、`release|alpha|debug`）和 `minClientBuild`；`buildNumber` 接受 1–15 位数字串或非负整数，缺失/畸形视为未上报，请求仍 200。`attachment_comments_v0` 默认开启。`GET /api/public/feature-flags` 已锁定为仅 pre-auth flag、platform 规则与默认决定，`Cache-Control: public, max-age=60`，凭据被忽略；非法 keys/platform 400。

External agent presence：任意 agent credential 认证的 API 调用会以 60s 窗口节流写 `last_used_at`；写成功时向 `server:<id>` 房间推 `agent:seen` 事件 `{agentId,lastSeenAt}`，仅 external agent 推送。`GET /api/agents` 对 external agent 返回 `lastSeenAt`（未见过为 null），managed agent 不返回该字段。`GET /internal/agent-api/wake-hints/stream` 打开即记为 seen，并按 `SLOCK_WAKE_STREAM_HEARTBEAT_MS`（默认 15s，夹在 50ms..60s）心跳刷新 `last_used_at` 且继续推送 `agent:seen`；流保持 SSE `text/event-stream`。

`POST /api/agent/login` 只在 `SLOCK_SELF_HOSTED_RUNNER_BOOTSTRAP_ENABLED=true` 时开启；关闭时 404 `self_hosted_runner_bootstrap_disabled`，开启后缺 `bootstrapToken`（含空白）400 `missing_bootstrap_token`，未知 token 401 `token_invalid`。`POST /internal/agent/:agentId/runtime-profile/migration-done` 需 machine key 且 agent 同 Server；空 `migrationKey` 回 `{ok,deprecated,noop:"no pending migration",message}`，非空回 `{ok,deprecated,message}`，无效 key 401 `auth_required`。

`GET /api/oauth/agents` 与 `/oidc/<server>/api/oauth/agents`：访问令牌过期、被撤销，或 agent 的 Server 成员关系/授权被撤销后一律 401 且不返回 `agents`；human/agent 令牌对 `/api/oauth/agent-events` 的写入都是 403；仅在 scopes 中声明 `agent:read` 的旧令牌不会因客户端后续放开 scope 而升级。

Identity setup：`POST /api/auth/register` 建 pending 账户（`name` 为 `pending_` + 20 hex，`profileSetupSuggestedHandle` 来自邮箱/名字，`profileSetupProvider:null`），`profileSetupCompletedAt:null`。`POST /api/auth/me/complete-profile` 用 `{name,displayName}`：`pending_` 前缀或保留名（如 Reminders）400 `PROFILE_SETUP_NAME_RESERVED`；完成后同名同 displayName 重放 200，不同 payload 409 `PROFILE_SETUP_ALREADY_COMPLETED`；并发两个不同 payload 只允许一个成功。资料未完成且邮箱已验证时 `POST /api/servers` 403 `{error:"Profile setup required",code:"PROFILE_SETUP_REQUIRED"}`；完成或既有账户可创建。

Guest-visible 频道：public 频道是否对 guest 可见由频道级 `guestVisible` 决定（本实现默认 true，测试可显式关闭）。关闭后 guest 的 inbox（含 `filter=mentions`）、done 列表、followed threads 与 direct thread 读取都不再返回该频道/其 thread；重新开启后恢复。残留的 mention/follow/done 记录本身不会授予访问。

`GET /api/messages/:messageId/mention-deliveries`：只有消息作者且当前仍可读该频道时返回 200 `{messageId,deliveries:[{targetId,targetHandle,outcome,reasonCategory?}]}`；无权/他人/跨 Server/未知消息/失去频道访问统一 404 `{status:"NOT_JOINABLE"}`；agent credential 401 且不返回 `deliveries`。终态 `IDENTITY_DRIFT` 回 `lost/unclassified`，`QUOTA_LIMITED` 回 `lost/quota`，无 occurrence 回 `unknown`。

`GET /api/announcements/images/:imageId`（匿名）：仅当公告已发布（`publishedAt` 非空、status 非 draft）且 `startsAt` 已到时返回图片字节，`Content-Type` 取资产类型，`Cache-Control: public, max-age=31536000, immutable`，`Cross-Origin-Resource-Policy: cross-origin`；draft、未来发布或未知 id 404；公告过期后仍可读；存储不可用 503。

`GET /api/external-avatars/:id.webp`（匿名）：仅 active 的已物化头像返回 200，`Content-Type` 来自资产、`Content-Length`、`Content-Disposition: inline`、`Cache-Control: public, no-cache, must-revalidate`、`ETag: "sha256-<digest>"`、`X-Content-Type-Options: nosniff`、`Cross-Origin-Resource-Policy: cross-origin`。非 UUID、未知 id、inactive 或非 `.webp` 后缀 404；存储不可用 503。

`RaftDaemon` 是活连接循环：握手成功打印 `daemon connected machine=... server=...`，会话结束后按 `DaemonReconnectPolicy` 重连（初始 1s，连续失败翻倍封顶 30s，jitter 窗口 5s，成功后重置）；迁移旧 key 的 401 终止循环并以非零退出。重连调度打印 `daemon reconnecting in <delay>ms (attempt <n>)`。DaemonLink 还记录 `daemon.connection.connect`（server_url_present/reconnect_attempt/outcome）、非 ping 入站的 consumer span（`inbound_message_kind`）、`agent.connection.inbound` 的关闭消息种类、activity sent 的 join keys（不含 producer fact id）；close/disconnect 清除 watchdog，不再发探针。

Daemon proxy：`buildFetchDispatcher` 按 proxy URL 复用 dispatcher；隔离 lane 按 route/origin/headers/body 组合缓存、互不共享，并可单独驱逐；`NO_PROXY` 同时作用于 WebSocket 与 fetch。fetch 只对显式 `UND_ERR_HEADERS_TIMEOUT`/`UND_ERR_BODY_TIMEOUT` 归为 `read_timeout`；pre-response 超时只约束 connect/headers，不中断慢 body；transport 拒绝会驱逐该 dispatcher，HTTP 4xx/5xx 不会。`proxyFailureTrace` 的投影只含 route_family/method/outcome/reason/error_class/error_excerpt 等允许字段，屏蔽 query、路径、URL、用户目录与代理细节；lifecycle 与 post-response 本地故障各有独立 reason/excerpt。

`/api/servers/:id/scope-attestation` 的 JWT（HS256，`SCOPE_ATTESTATION_SECRET`）claim 精确为 `scope/actorType:"user"/sub/serverId/aud/resource/exp`：member 可签 `web-trace-batch:create`（aud `trace-ingest-worker`），`feedback-report:create` 仅 owner/admin（aud `feedback-worker`）。`…/feedback/:reportId/transcript` 对非 UUID 与编码后的路径穿越（`..%2Fx`）都在触达 daemon 前 404；非 owner/admin/创建者 403；坏 `reportGeneratedAt` 400；成功 202。

`GET /api/agents/:id/external-diagnostics`（owner/admin/creator；managed 400 `agent_not_external`）：返回 external agent 的 `runtime`、`provider`（self-run 为 null；provider-backed 为 `{kind,state,providerAgentId,syncPending,lastErrorCode,lastErrorAt,activatedAt}`）、`presence{lastSeenAt,online,onlineWindowMs:120000}`（凭证使用后 2 分钟内 online）、`status{activity,statusProtocolAdoptedAt}`、`push{registered,enabled,endpointHost,disabledReason,disabledAt,consecutiveFailures,lastAttemptAt,lastDeliveryAt,lastError,nextAttemptAt}`（URL 只留 host，secret 不外泄）、`events{lastCursorPullAt,pendingCursorAckCount}`、`connections`（self-run `github/not_applicable`；provider-backed `github/unavailable` + reason）。`PUT /internal/agent-api/push-webhook` 需 agent credential，收 https URL + secret。

OIDC interop：`GET /.well-known/openid-configuration` 与 `/api/oauth/.well-known/openid-configuration` 返回同一文档（`Cache-Control: public, max-age=300`），含 `response_types_supported:["code"]`、`id_token_signing_alg_values_supported:["ES256"]`、`code_challenge_methods_supported:["S256"]`、`token_endpoint_auth_methods_supported:["client_secret_basic","client_secret_post"]`、`claims_supported` 含 `server_slug`。`/api/oauth/clients/lookup` 只认 `clientId`（记录 UUID 与未知 UUID 均 404），命中回 `availability:"ready"`。`POST /api/oauth/authorize/human` 对跨 Server 的 `serverId` 或 UUID 形式的 `clientId` 回 404 `OAuth client not found for server`；`server` hint 与 `serverId` 不符 400。`POST /api/oauth/token` 支持 Basic 认证与 form body；UUID 作为 client 标识 401 `Invalid client credentials`；成功回 `token_type:"Bearer"`、`expires_in>0`、排序后的 `scope`，并带 `Cache-Control: no-store`。ID token 头 `alg:"ES256"` 且 `kid` 等于 JWKS 的 `kid`；claim 含 `iss/sub/aud/nonce/name/preferred_username/email/email_verified/server_id/server_slug/iat/exp`，`exp>iat`。OIDC code 被兑换后重放、请求行被删除、PKCE 不符或 redirect 不符统一 400 `invalid_grant` 且无 `next_action`（非 OIDC 的 handoff 仍是 409 `request_already_consumed`）。未请求 `email` scope 时 ID token 与 userinfo 都不含 `email`/`email_verified`，签名仍可用 JWKS 验过。

`GET /internal/agent-api/history?channel=agent-event:<id8|uuid>` 重读第三方事件：只解析调用 agent 自己拥有的行。命中且未过期回 200 `{messages:[...],has_more:false,has_older:false,has_newer:false}`，正文含 `Third-party <kind>: <summary>`、`event_id: <uuid>`、`payload_hash:`、`resource:`，并带 `third_party_event.payload`；自己的事件已过期回 410 `errorCode:"EXPIRED"`；同一 8 位前缀命中多条自己的事件回 409 `errorCode:"AMBIGUOUS_ID"` + `suggestedNextAction`，完整 id 可分别读取；别人的事件与不存在的 id 都是 404 `{"error":"Channel not found or not visible"}`，字节完全一致且不回显请求 id 或摘要。

`POST /internal/agent-api/feedback-locators`（agent credential，`send` capability）：校验 `artifact_kind=raft-feedback-locator-v0`、`event_kind=feedback-locator:created`、禁止字段、resolved 路由必须是存在的 `#proj-feedback` 公共频道、`schema_version=raft.feedback.locator.v0`、producer 的 server/agent 与凭据一致；成功回 `{status:"accepted",receipt_id,report_id,duplicate:false}`。同 server+report_id 的相同 payload 重放回同一 `receipt_id` 且 `duplicate:true`；payload 不同回 409 `report_identity_conflict`。错误体是 `{status:"failed",reason_code}`：未知 artifact/event/schema、`forbidden_field`、`invalid_route_ref`、`invalid_payload`。`GET /internal/agent-api/feedback-locators`（`read` capability）按 `report_id/runtime/native_status/native_lookup_method/served_exact_sha256/route_basis/limit` 过滤，最新优先，返回 `{locators:[{report_id,receipt_id,captured_at,runtime,native_status,native_lookup_method,native_locator_kind,has_served_exact,served_exact_sha256,route_basis,route_target}]}`，不含 payload 或 session id。

Managed MCP（`/internal/agent-api/mcp/*`，agent credential 的 `mcp` capability，缺权限 403 `requiredCapability:"mcp"`）：`GET /mcp/tools` 返回 `{catalogVersion,tools:[{mcpServerId,serverName,toolName,inputSchema,assignmentVersion:1,catalogVersion}],unavailable?}`；OAuth 连接器在 `oauthStatus != "connected"` 时不贡献工具，只进 `unavailable:[{mcpServerId,serverName,status:"reconnect_required"}]`，且工具行不含 `endpointUrl`/`headers`。`POST /mcp/call` 对非 UUID `mcpServerId` 回 400；工具不在目录、`expectedConfigVersion`/`expectedAssignmentVersion` 过期回 409 `managed_mcp_config_stale`，`error` 与 `suggestedNextAction` 都是 `"<tool>" is no longer offered by "<server>"; don't call it again. If you still need it, tell the person who asked.`。

`GET /internal/agent-api/history` 的响应带 `channel_card:{id,name,type,description,archived}`：普通/私有/归档频道给自身卡片（`type` 取 `channel`/`private`，`archived` 反映归档）；thread 目标给父频道卡片；DM（`dm:@<name>`）给 200 但无 `channel_card`。`dm:@` 目标按 Server 内与 agent 共同的 DM 解析，未知/不可见仍 404。

Action card 结果回复：`POST /internal/agent-api/prepare-action`（agent `send`）以 `{target:"#name", action:{type:"channel:create",name,visibility?}}` 准备卡片，回 201 `{messageId,metadata}`；卡片消息落在目标频道（Joint 时落 canonical 存储）。`POST /api/actions/:messageId/execute`（Server 成员，`expectedState:"prepared"`）执行后在卡片消息的 thread 写入持久 system 回复：`@<agent> your action card \`<id8>\` (creating channel #<name>) was executed by @<owner> on <Server>, acting with @<owner>'s permissions.` + `Result: created channel #<name>.`；成功创建频道并 `state:"executed"`。失败（如频道已存在）回 409，thread 里写 `failed when … still pending and can be retried`，卡片保持 prepared。回复给 preparer 记一条 `personalMention:true, unreadEligible:true` 的 agent inbox fact 与 mention 行，确认人自己的 fact 是 born-read（`unreadEligible:false`）。Joint 卡片按 canonical thread 存储并在各投影建本地 thread；external preparer 通过 `GET /internal/agent-api/events` 收到同一条 `{message_id,content}`。

实验性内部面 kill switch：`SLOCK_EXPERIMENTAL_SURFACES_DISABLED=true` 时所有 `/internal/agent-api/*` 与 `/internal/computer/*`（含未挂载路径）统一 503，响应头 `Sec-Slock-Api-Version: 1`，body 为 `{"error":"Experimental internal surface is disabled","code":"experimental_surface_disabled","retry_after":null}`；其他 `/api/*` 路由不受影响，关闭开关后恢复原行为。

`GET /internal/agent-api/events` 现在同时返回 external agent 的 durable 频道 inbox：可见频道里未被 drain 的消息按时间排列，每条带 `seq/message_id/sender_id/sender_name/sender_type/senderType/content/mentioned/channel_*`。`sender_type` 与 camelCase `senderType` 始终一致：human、`system`（`senderId:"system"`/`messageType:"system"`）、`agent`、`third_party_app`（external projection）。外部投影消息附 `external_message:{message_id,provider,actor_name}`、`mentioned` 由真实 mention 行决定、正文保持原样；第三方事件正文把 `@handle` 改写为 `user:handle` 且带 `third_party_event.source`。调用后频道消息与第三方事件都被 drain，重放为空。

Agent history 的 thread 解析与消费身份：`#channel:<short>` 先按父频道里真实消息 id 前缀找 thread，再接受 thread 自身 id 前缀与 thread 的 `parentMessageId` 前缀；成功响应的 `target` 是 `#channel:<anchorShort>`（thread-id 写法解析到同一 target）。父频道缺失/不可见、短 id 不存在、或短 id 属于别的频道，统一 404 `{"error":"Channel not found or not visible"}` 且字节一致；父频道消息存在但没有 thread 时回 404 且 `error` 含 `no thread on message`，`suggestedNextAction` 为可执行的 `raft message read --target '#channel' --around <short>`。`around` 指向不存在的消息时返回空窗口而不是最新页。`dm:@name` 与 `dm:@name:<anchorShort>` 回 200 并带 `consumption_scope:{agent_id,channel_id,channel_type:"dm"|"thread",target}`；普通频道读没有该字段，未知 DM 对端 404。

Per-agent grants：默认（没有自定义 grant 集）允许全部操作。自定义集缺少某个 grant 时，Agent API 与 legacy `/internal/agent/:id/*` 返回同一 403 `{"error":"missing required scope","requiredScope":"<scope>","reason":"missing_scope"}` 且不落库；其他 grant 不受影响，重置回默认后恢复。当前强制点：`channel:join`（`POST /internal/agent-api/channels/:id/join` 与 legacy join）和 `task:write`（`POST /internal/agent-api/tasks` 与 `/internal/agent/:id/tasks`）。`GET /internal/agent-api/tasks?channel=%23name` 需要 `task:read`，返回 `{tasks:[{id,channelId,title,status,taskNumber}]}`；任务创建 body 为 `{channel:"#name",tasks:[{title}]}`，回 `{taskIds}`。

Agent App config：`GET/PATCH /internal/agent-api/apps/:appId/config`（credential `read` 可读，写需 `tasks` capability）。`system.cleaner` 返回 `{appId,revision,schema,defaults,overrides,effective}`（`schema`/`effective` 用 snake_case，默认 enabled=true/threshold_bytes=65536/interval_seconds=3600）；未知 app 404 `RAP_APP_CONFIG_APP_UNKNOWN`。PATCH body `{expectedRevision,set,unset}`：revision 不符 409 `{error:"Config revision is stale; current revision is N",errorCode:"RAP_APP_CONFIG_REVISION_STALE",currentRevision:N}`；成功 revision+1、overrides 合并/删除、effective 为标准覆盖结果、响应不含 `apply`。配置按 agent 隔离，read-only 凭据写回 403。上游的 Computer push 断言依赖 orchestrator stub，按仓库契约不移植。

`POST /internal/agent-api/integrations/token`（agent `read` 凭据）签发内建 audience JWT：body 只接受 `service`（App clientId），任何 `agentId/serverId/audience/issuer/expires_in/scopes/claims` 覆盖字段 400。要求 agent active、仍是该 Server 成员、App 在本 Server 可用（server_local 且 enabled、allowedScopes 含 openid+profile）、agent 对该 App 的 grant 未撤销。成功 200 `{access_token,audience,expires_in:300}` + `Cache-Control: no-store`；JWT header `typ:"at+jwt"`/`alg:"ES256"`/`kid` 与 scoped JWKS 匹配，claims 含 `iss:<origin>/oidc/<slug>`、`aud`、`sub`、`server_id`、`server_slug`、`type:"agent"`、`token_use:"agent_access"`、`login:"raft-agent-<id>"`（47 字符）、`preferred_username`、`iat/nbf/exp`（exp=iat+300）、`jti`，无 email。该 JWT 不能访问 `/api/oauth/userinfo`（401），两次签发 token 不同。

Agent attachment 下载：`GET /internal/agent-api/attachments/:id`（`read` capability）与 `GET .../:id/url`。可见附件下载回 200 字节（`Content-Type` 为附件 MIME，`Cache-Control: private, no-store`）；URL 路由用存储 presign 生成 5 分钟 URL，回 `{url,expiresAt,filename,mimeType}`，签名参数为 storage key（`serverId/<id>.<ext>`）、`expiresIn:300`、`attachment; filename="..."; filename*=UTF-8''...`、MIME。缺失/畸形/不可见附件两条路由都回同一 404 `{error:"Attachment is unavailable. <next action>",code:"ATTACHMENT_UNAVAILABLE",suggestedNextAction:...}`，且不触达 presign；send-only 凭据两条路由都 403。存储不支持 presign 时 URL 路由 409 `download_url_unavailable`，下载仍流式返回字节。

`GET /internal/agent-api/inbox/conversations`（agent `read`）：从真实频道/DM/thread-follow 数据构建 offered 会话，按全局 `activity_seq` 降序。返回 `{view,items,totals:{conversations,dms,mentions},hasMore,nextBeforeSeq}`；item 为 `{target,kind,unread,mentions,lastReadSeq,activitySeq,latestSenderName,latestAt}`。target：频道 `#name`、DM `dm:@<peer>`、thread `#parent:<parentShort>` / `dm:@<peer>:<parentShort>`，Joint thread 用本地父频道名 + canonical parent short。`limit` 1–100（默认 20）、`before_seq` 正整数、`view` 仅 `unread|mentions`，非法 400。`view=mentions` 只留 `mentions>0`；totals 基于全部 offered 会话。无可寻址人类对端的 DM 不列出也不计数；inbox 后端不可用时 503 `INBOX_UNAVAILABLE`。

`GET /api/servers/:id/apps`：composer resource references 未启用时 404；启用后所有成员拿到精确的两项 `{appId,displayName}`：`system.cleaner/Memory Cleaner`、`system.reminder/Reminder`，内部 `system.canary` 不出现，行内不带额外字段。`GET /api/servers/:id/member-graph`：除既有可见性/隐藏目录/自检外，序列化结果不含成员 email，也不含 agent 的 env vars（如 `GRAPH_SECRET`）。

`PATCH /api/servers/:id/notification-settings` 在偏好实际变化时向 `user:<id>` 推 `notification_prefs:updated`，payload 为 `{serverId,scopeId:serverId,prefs:{serverPushMuted,serverPushMentionsOnly,serverPushMode},prefsVersion}`；同值重复 PATCH 不递增版本、不推送。GET/PATCH 仍是按成员隔离，owner 读取自己的默认偏好。

Server 成员/机器实时面：`PATCH /api/servers/:id/members/:memberId` 角色实际变化时向 `server:<id>` 推 `server:member-updated`，payload `{serverId,userId,previousRole,role}`。`DELETE` 成员成功时先推 `server:<id>` `server:member-removed` `{serverId,userId}`，再推 `user:<memberId>` `server:membership-removed` `{serverId}`；被移除成员的 profile 对 owner/admin（或本人）仍可读，带 `membershipStatus:"removed"`。机器 POST/PATCH/DELETE 各自向 `server:<id>` 推 `machine:updated` `{serverId,machineId}`。

`GET /internal/agent-api/context`（`read` capability，否则 403 `capability_not_authorized` + `requiredCapability:"read"`）：返回 `{agent:{id,name,displayName,description,runtime,external,assistantOf:null,serverRole},server:{id,slug,name},credential:{capabilities:[...sorted]},prompt,features:{reminderApp,vaultApp}}`。external agent 的 `prompt` 为 `{audience:"self-hosted-runner",text}`，文本含 handle/displayName/server/role/初始 description 与 `reminders_unsupported_for_external_agents`，不含 `<your-handle>` 占位符；managed agent 的 `prompt` 为 null。features 来自 `reminder_app`/`vault_app` 的 server 规则（缺省 false）。

Agent knowledge search payload（`serializeKnowledgeSearch`）：`{ok:true,query,scope,results:[{slug,title,firstScreen,matchedTerms,correctedTerms:[{term,matched}]}]}`。`matchedTerms` / `correctedTerms` 是 agent 可见的匹配理由；`docVersion`/`docState` 等内部评分字段不进入结果行，投影是显式白名单而非整体展开。

App 出站权限审阅：`GET /api/integrations/marketplace` 列出本 Server 已发布的第三方 App，行内带 `appNotificationPendingGroups`、`appNotificationPendingRevisionId`、`canReviewAppNotifications`（reviewer allowlist）。`POST /api/integrations/clients/:id/app-notifications/permissions/review` 必须携带 UUID 形式的 `expected_revision_id`；缺失、null、数字、空串或非 UUID 一律 400 且不改变 pending；与当前 pending revision 不符回 409 `permission_revision_stale`；匹配时提交该 revision 的 groups、清空 pending 并回 200 `{ok,groups}`。

PKCE downgrade 防护：`POST /api/oauth/token` 与 `/oidc/<server>/api/oauth/token` 对 `authorization_code`（含 OIDC 非 PKCE code）和 `urn:slock:grant-type:agent_request`，只要请求体出现 `code_verifier`（包括空串、null、数组或任意类型）就回 400 `invalid_grant`，且不消耗 code；真正的非 PKCE 兑换在缺少该参数时仍成功一次，重放按 grant 类型回 409（普通/agent request）或 400（OIDC）。

DM peer kind：`dm:@<name>~agent` / `dm:@<name>~human` 选定同名人类或 agent 的 DM；`dm:@<name>` 在两者都存在时回 409 `DM_TARGET_AMBIGUOUS`（error/suggestedNextAction 同时给出 `~agent` 与 `~human`），未知 kind 回 400 `DM_TARGET_INVALID_PEER_KIND`。history 的 `--around` 只能命中所选 DM 的消息（跨 DM 回 404），thread 后缀同时接受 anchor 短 id 与 thread 自身 id 短 id，且必须位于所选 DM 下。`POST /internal/agent-api/send` 与 `/v2/send` 支持同一 DM 目标解析：歧义 409、坏 kind 400、未知 404，pinned 目标可直接向已有或首个 DM 发送。

Managed MCP agent 错误文案：常见失败码映射为可执行的一句话（reconnect、credentials、stale tool、unavailable、gone），connector/tool 名称先压平为单行、按 80 字符截断并加引号，防止换行或超长文本逃逸；gone 类消息带 `mcp_<id8>_` 前缀提示。运行时工具名为 `mcp_<server8>_<tool>_<fnv1a32>`，同一 connector 的所有工具共享前缀。

Agent audience JWT 内建：`POST /internal/agent-api/integrations/token` 不读取旧的 App/installation `agentJwtEnabled` 列（两者缺省仍为 false，置 null/true 均不影响签发）。App 可用性边界与 Agent Login 一致：App 归属的 Server 可直接签发（即使转换为私有 share 后仍可）；其他 Server 需要该 App 处于 `third_party_global` 且存在 active installation，share link 本身不算安装。installation suspended、App disabled、allowedScopes 缺 openid/profile、installation 被删除都回 403；不可用的私有 App 与未知 App 的状态与 `errorCode` 相同。兼容读 `GET /api/integrations/clients/:id/agent-jwt` 仅 owner/admin 可用（其他成员 403 `Only server owners and admins can read Agent JWT access`），回 `{scope:"app"|"installation",enabled:true,appEnabled:true,effectiveEnabled,canEnable:false,audience,expiresIn:300}` 且 `Cache-Control: private, no-store`；`PUT` 恒回 410 `Agent JWT is built in for every App; there is no setting to change`，不改任何状态、不影响后续签发。

Agent 读位置：`GET /internal/agent-api/events` 每次每个会话最多交回 5 条未读（`sender != agent` 且 seq 高于该会话 cursor），并把这些消息的 cursor 推进到最后一交回的 seq；还有剩余时 `has_more:true`，下一次调用返回余下部分，排空后为空。agent 通过 `/internal/agent-api/send` 发消息时，只有当自身消息之下没有其他发送者的未读消息时 cursor 才前进到自身消息，否则保持不动且那些未读仍会被拉取；agent 自己的消息永不出现在自己的 pull 里。人类通过 `POST /api/messages` 发送时，其读 cursor 总是前进到自身消息（不受下方未读影响）。`/internal/agent-api/send` 现在也接受 `#channel` 目标（含 thread 后缀）。

Computer runner credential mint：`POST /internal/computer/runners/:agentId/credentials`（`sk_computer_*`）只在 Computer 仍绑定到现存 machine 时可用；agent 必须属于同一 Server 且分配到该 machine，否则 404 `agent_missing`。成功回 201 `{credentialId,apiKey,scopes,agentId,agentName,serverId}`，scopes 校验为固定集合（空集 400 `scopes_empty`，未知值 400 `scopes_invalid`），name 最长 200。删除 machine 时 Computer key 立即失效：删除后 `/internal/computer/runners` 与 runner mint 都回 401，且保留 `revokedAt` 收据、把 `machineId` 清空；历史遗留（machine 消失但无收据）同样 401。

Managed MCP 控制面（`/api/mcp/*`）：成员可读 `GET /api/mcp/servers` 与 `GET /api/mcp/agents/:agentId`，owner/admin 才能创建/PATCH/DELETE server 与 `test-configuration`；成员写回 403。创建 201 只回 `credentialHeaderNames`、`hasCredentials`，从不回 header 值或 `encryptedHeaders`；endpoint 必须是公共 HTTPS、无凭据/query/fragment（否则 400 `managed_mcp_endpoint_invalid`，错误体不回显 URL），输出的 `endpointUrl` 也会剥离 query/fragment。`notion` + `oauth` 只接受 `https://mcp.notion.com/mcp`（否则 409 `managed_mcp_auth_invalid`），创建后 `oauthStatus:"disconnected"`。`credentialPatch` 的 upsert/remove 立即反映在 header 名单且不回显值。catalog 带静态 recommendations `notion`/`linear`，未分配时 `assignment:null`。`GET /api/mcp/oauth/callback` 对无效 state 回 400 HTML（`Cache-Control: no-store`、CSP `default-src 'none'`、含 `RAFT`/`MCP was not connected`/`Close window`/结果容器，无定时器）；`client-metadata` 回绝对 `client_id` 与对应 callback redirect。assignment 的批量与单条 PUT 均可由成员执行。上游对 orchestrator reset 的私有注入断言未移植。

消息 randomId 幂等：`POST /api/messages` 带 `randomId` 首次发送后，相同 randomId 的重放无论正文/mention 是否变化都返回**第一条**消息的完整 JSON（id/channelId/content/attachments/mentions/randomId 全部一致），且只落一行；randomId 作用域是发送者 + 原 storage channel，跨频道重放回 409 `random_id_conflict` 且不回显原正文；附件重放要求完全相同的**有序**集合（重排 400 `attachment_replay_conflict`，换 randomId 复用附件 400 `attachment_already_linked`）；`randomId:"invalid"` 等 sentinel 文本按普通字符串接受并回显。并发同 randomId 的两个请求都会 200 且返回同一最终行。消息 JSON 现在带 `mentions:[{type,id,name}]`；DM 中的 mention 仍是 inert，`mentions` 回空数组。上游的 failpoint 并发屏障未移植（并发用真实双请求验收）。

Machine 描述与权限：`PATCH /api/servers/:id/machines/:machineId` 的 `description` 先去首尾空白，空串清为 null；响应回 `{id,name,description}`，`GET /api/servers/:id/machines` 行内同步投影该值。owner/admin 或 machine 的创建者可改；其他成员 403 `Forbidden`；machine 属于别的 Server 时 404。人类成员的 `GET .../machines` 只看到本 Server 的 machine。

双 `RaftServer` 启动门槛：两个真实进程可同时启动（各自 HTTP/daemon-connect/socket.io 端口），都打印 `raft-server ready http=... daemon-connect=... realtime=...`，各自 `/livez` 200、无数据库时 `/health` 503 `database unreachable`。两个进程的内存目录彼此隔离：在 A 注册的账号/Server 无法在 B 登录或读取。测试在两进程均就绪后打印 `two-RaftServer gate complete`。`/health` 的真实 200 仍由 PLAN 的 B2 决策门控制（需要 PostgresNIO + `DATABASE_URL`）。

登录方式管理：`GET /api/auth/identities` 返回 `{identities:[{provider,providerEmail}],passwordConfigured}`（需要登录）。`DELETE /api/auth/identities/:provider` 只作用于当前用户；未登录 401；provider 不存在时幂等回 `unlinked:false`；删除最后一个登录方式且没有已建立的密码凭据时回 409 `{"code":"PASSWORD_CREDENTIAL_REQUIRED","error":"Set a password before disconnecting your final sign-in account."}` 且不删除；并发删除两个最后方式会串行化成一个 200 + 一个 409。`passwordConfigured` 只认 `passwordCredentialEstablishedAt`：仅有占位 hash 的社交账号为 false，旧版真实密码首次登录成功会自愈并建立凭据。`POST /api/auth/reset-password` 用未过期 token 设置密码并建立凭据，之后允许删除最后一个社交登录方式。

OAuth 回调 redirect 安全：`POST /api/oauth/authorize/human` 只在请求的 `returnUrl` 与已登记值完全一致且为安全 URL（HTTPS，或 loopback HTTP，无凭据/fragment）时签发 code；未登记 callback、与登记值不符、或历史遗留的 `javascript:`/`data:` 值一律 400 且响应不含 `code`。`createOAuthClient` 与更新路径（`updateClientReturnUrl`）都拒绝脚本/data URL，错误信息含 `returnUrl`。

错误卫生（black-box）：畸形 `X-Server-Id`/路径 id（非 UUID 或 UUID 后跟中文文本）在 middleware/路由层就是 typed 4xx，不泄漏 pg cast/query/params/表名等内部信息，也不会被吞成 500；`/api/servers/not-a-uuid/members` 回 404 `Server not found`，路径与 header 不一致回 typed 4xx 且无 `internal_server_error`。`/api/messages/context/:id` 的畸形 id 回 400、畸形 `channelId` 回 400；`/api/messages/channel/:id`、成员 profile、public channel/thread、MCP agent、integrations agent/client/share-link/marketplace 的畸形 id 回 404；8 位短 id 在 `context` 上是合法目标并回 200。

频道批量加成员：`POST /api/channels/:id/members/batch` 接受 `{userIds,agentIds}`，先去重并保留顺序；所有用户必须是 Server 成员，否则整批 400 `{"error":"One or more users are not members of this server","code":"users_not_in_server","invalidUserIds":[...]}`，不写入任何成员或系统消息。成功回 `{ok:true,added:{userIds,agentIds},alreadyMembers:{userIds,agentIds}}`；每个新加入的人类/agent 产生一次 `@<name> was added to this channel.` 系统消息，重复调用只列 alreadyMembers、不重复消息。

消息创建 body 边界：`POST /api/messages` 在写库前拒绝非字符串 `channelId`、非法 `attachmentIds` 元素和非布尔 `asTask`（400 `{error}`，不产生消息）。App/Computer 引用在 server gate 关闭时 400 `Computer and App references are not enabled in this server`；gate 开启但 `app:<id>` 未安装时 400 `App reference is not installed in this server`，两者都不落消息。

消息 mention 解析（`POST /api/messages` v1 与 `/api/v2/messages`）：正文里的 `@handle` 与显式 `mentions` 一起解析。v1 直接把每个匹配的人类/agent 记为 mention（同一 handle 可同时命中人类与 agent）；v2 对 0 个或多个匹配的 raw handle 回 `unresolvedMentionHandles:["@handle"]` 且不落 mention，只有唯一匹配才记录。显式 typed mentions 必须能绑定到唯一 handle：同名但不同 target 的两条 typed mention 在写库前 400 `mention_binding_conflict`。隐藏人类目录下，普通成员的 raw/typed 隐藏用户不再可解析（raw 回 unresolved，typed 静默丢弃），但 owner/admin、共享普通频道的成员以及 joint roster 中的 peer 仍可见；可见的非频道成员继续产生 sender-only `pendingMentionActions`。`unresolvedMentionHandles` 只出现在 v2 发送响应，socket 与冷读消息负载不含它。

消息发送的 Server membership 门：当该 Server 已有成员记录、但发送者已不在成员表中时，`POST /api/messages`/`/api/v2/messages` 在解析频道/mention 和写库前回 403 `{"error":"Not a member of this server"}`，不产生消息或 mention。隐藏目录关闭后，typed mention 恢复为普通可见目标（非频道成员仍产生 pending action）。Reaction 的 `reactorNames` 现在优先使用人类 displayName（未设置时回退 name）。

Reaction 权限与实时快照：系统消息 400 `System messages cannot receive reactions`；公开频道非成员 POST/DELETE 403，私有/已删除频道对非成员统一 404（存在性不泄漏）；归档频道 409 `channel_archived`；短 id 只在调用者可见的消息中匹配。Agent 通过 legacy machine key 或 Agent API 的 reaction 与人类反应聚合，`reactorNames` 使用 agent runtime displayName（缺失时回退 name）。每次实际变化把同一份 `{serverId,messageId,viewerVersion,reactedEmojis}` 快照放进 mutation ACK、`GET .../reactions/viewer` 与 `user:<id>` 的 `reaction_viewer:updated` 事件；幂等添加/删除不递增版本；`channel:*` 的 `message:updated` payload 不含 viewer 字段。

Reaction actor 分页：`GET /api/messages/:id/reactions/actors?emoji=&limit=&cursor=` 返回 `{discussion,discussionVersion,actors:[{actorRef:{kind,id}}],nextCursor}`；按 kind/id 排序后分页，`nextCursor` 绑定 principal/server/message/emoji/discussionVersion/visibilityHash。cursor 被其他 principal、其他 message、其他 emoji 或 peer Server 复用一律 400 `invalid_reaction_actors_cursor`；人类/agent 反应任何实际增删都递增 discussionVersion，旧 cursor 回 409 `reaction_discussion_version_changed` + `currentDiscussionVersion` + `rebaselineRequired:true`。隐藏人类目录在**分页前**过滤 actor，隐藏者不占页边界；目录授权变化后旧 cursor 回 409 `reaction_actor_visibility_changed`。私有/已删除消息 404、归档 409、短 id 冲突 400、非法 emoji/cursor 各自 typed 400；joint 讨论的 `discussion.root/parentScope` 使用调用者本地 Server 与本地 projection。

Message context / permalink：`GET /api/messages/context/:id?channelId=` 支持 8 位短 id；公开频道即使调用者未加入也能解析目标消息（返回 `channelId/targetMessageId/messages`），DM 参与者可在 DM 内解析。父频道上下文里的 thread 回复会 canonicalize 为 `{kind:"thread",channelId:parent,messageId:reply,threadParentMessageId,threadChannelId}`，消息行使用 thread channel；thread channel 自身短 id 作为引用时解析回父消息上下文。Joint 频道使用调用者本地 projection 的 `channelId` 输出消息，canonical 存储对非本地 joint 成员保持 404。

Joint thread permalink：调用者用本地父频道 + 回复短 id 查询 context 时，若回复存于 canonical thread、且本地 Server 有对应 local thread projection，返回的 `channelId` 是本地 thread，`canonicalTarget` 为 `{kind:"thread",channelId:本地父频道,messageId:回复,threadParentMessageId,threadChannelId:本地thread}`；直接以本地 thread 作为 `channelId` 也能解析同一回复。Message search：`sort=recent` 按 createdAt 降序，默认 relevance 按词频；未知 sort 400。CJK 查询按字符 token，严格全匹配为空时使用 relaxed 一页兜底（`hasMore:false`）。支持仅过滤（channelId/senderId/senderType/mentionTarget=self）且无 query 时按 recent；私有频道对非成员不可见（显式 channelId 也 404），已删除频道/线程被排除，归档频道仍可搜索并带 `channelArchivedAt`。

Message forward：`POST /api/messages/forward` 单目标时回 200 + `X-Raft-Forward-Outcome: success|idempotent_replay`，正文含 `actionMetadata:{kind:"forwarded-bundle",forwardedItems:[...]}`；items 按 thread-parent 优先、再 createdAt 升序，保留 `contentSnapshot`、`sourceTargetSnapshot`（label/labelVisibility）、attachment snapshots（新 id、无原 object/url），源附件策略 `excluded|projected`；相同 randomId 重放返回同一 message 与同一投影附件 id，内容变化 409 `idempotency_conflict`。批量 `destinationChannelIds`（最多 10，去重）需 UUID `requestId`；逐目标回 `results:[{destinationChannelId,status,message|code,error}]`，不可见目标 `destination_unavailable`，冲突 `request_conflict`，header 为 `success|idempotent_replay|partial_failure|all_failed`；重试与子集重试复用已提交消息。thread 源通过父频道读权限：回复的 target 为 thread，带 `sourceThreadId` 与 `parentChannelId`，父消息带 `sourceIsThreadParent:true`；thread 回复与父频道 sibling 混合回 400 `cross_source_bundle`。

Forward provenance：私有 thread/私有频道来源即使在创建者响应中也只给 `sourceTargetId:null`、无 thread/parent 字段、`label:""`、`labelVisibility:"restricted"`；无源频道权限的 destination viewer 在冷读中拿到全部源指针为 null、附件仍可读、`provenanceState:"original_unavailable"`。短 id 源在 server-wide 解析前 400；system/非普通消息 400 `unsupported_source_message`；再次转发已转发消息 400 `forwarded_source_not_supported`。

Forward joint：向 joint 目标转发时响应 `channelId`/`destinationTargetId` 是调用者本地 projection，消息存 canonical；host 本地列表保留 public 源 provenance，guest 本地列表（含同一 owner 通过 guest Server 读取）把源指针全部 scrub 为 null、label 空、`restricted`、`original_unavailable`，context/sync 同规则。以 joint canonical 消息为源转发时 item 的 `sourceTargetSnapshot.type:"joint"`、指针 null、label 空、`restricted`，`provenanceState:"available"`；host 与 guest 都可转发到各自本地普通目标。

Forward source×destination 矩阵：channel/private/DM/joint 四种源 × channel/private/DM/joint 四种目标全部可转发；响应 `channelId`/`destinationTargetId` 为目标本地 id，item 的 `sourceTargetSnapshot.type` 对应源类型，public 源 label 为 `#name` 且 `labelVisibility:"public"`，private/DM/joint 源 label 空且 `restricted`。`POST /api/messages` 的 `channelId` 不属于当前 `X-Server-Id` 时回 404 `Channel not found`，不写消息。

Servers runtime 组：`GET .../runtime-options` 需要 owner/admin 或 machine 创建者；member/attacher 不因 Computer attach 获得该权限。`GET .../runtime-models/:runtime` 返回 `{kind:"live",value:{models,default},models,default}`，权限同上。`POST .../runtimes/rescan` 离线 409 `Computer is offline`，在线且授权 200 `{requested:true}`。`GET .../runtime-account-usage/:provider` 仅 owner/admin 或 Computer 的 attaching human；未知 provider 404；响应 `Cache-Control: private, no-store`，`state: missing|fresh|stale`。`POST .../refresh`：非 manual 202 `requested`，60s 内重复 202 `cooldown`；manual 在线且拿到快照 200 `fresh`，超时 200 `timeout`，离线 202 `computer_offline`。

Machine delete 与 runtime profiles：存在指向该 machine 且仍关联 active（未删除）agent 的 runtime profile 时，`DELETE /api/servers/:id/machines/:machineId` 回 409 `MACHINE_HAS_ACTIVE_RUNTIME_PROFILE`，错误文本含 `runtime profiles still reference active agents` 且 machine 保留；agent 已删除或 profile 已标记 migration 完成后的 stale source 会被清理，随后删除成功。

Runtime form v2-only：pi/opencode/gemini/codex/grok/antigravity 只在 v2 路由可见；v1 `runtime-form-definitions`/option-source 对它们回 404 `unknown_form_runtime`（pointer `/runtimeId`）。Pi 的 v2 provider source 回 `{defaultValue:"configured"}`；Codex/Grok 的 v2 model source 带 `optionSource.status: ready|unavailable` 与被探测模型。Machine delete 在存在 sourceMachineId=machine 且 state 非终态的 migration 时回 409 `MACHINE_HAS_ACTIVE_MIGRATION`；完成后 stale source profile 可清理并删除。

Machine list 投影：`GET /api/servers/:id/machines` 顶层带 `latestComputerVersion`/`latestComputerReleaseNotes`；每台 machine 带 `computerUpgradeAvailable` 与 `computerBroadcastPolicy`。无 Computer 的 raw daemon 两者为 null；有 Computer 但无 policy 行时 `computerUpgradeAvailable:false` 且 policy 为 `{eligibility:"ineligible",targetVersion:null,policyRevision:null,reasonCode:"policy_row_missing"}`；有 eligible policy 时 upgrade true 并原样投影 eligibility/targetVersion/targetRole/migrationClass/policyRevision/reasonCode。

Machine delete / migration history 矩阵：`DELETE /api/servers/:id/machines/:machineId` 仅在存在该 machine 作为 source 的非终态 migration 时回 409 `MACHINE_HAS_ACTIVE_MIGRATION`。Runtime profile 仍指向该 machine 且关联 active agent 时，需要一条 `completed` migration 且其 `targetMachineId` 等于 agent 当前 assignment、且 profile 无 pending release notice，才清理 profile 并删除；否则 409 `{error:"Cannot delete computer while runtime profiles still reference active agents. Remove or migrate related agents first.",code:"MACHINE_HAS_ACTIVE_RUNTIME_PROFILE"}`。带 pending release notice 的 stale source profile 会阻止删除并完整保留 notice。profile 已迁到 target、仅 `pendingBeforeMachineId` 指向 source 时，删除 source 只清空该 pending-before 引用，保留 target/baseline/pendingAfter/pendingKind。已删除 agent 的 profile 直接清理；terminal migration（如 aborted）在删除后仍完整保留，作为历史。

Thread summary 的 viewer 状态：`GET /api/channels/:id/threads` 每条 summary 带 `followed`。active follow 为 true；done（保留 follow、只标记 done）仍为 true；显式 unfollow 或从未 follow 为 false。`followed` 与 `unreadCount`/`firstUnreadMessageId` 一样按调用者计算，不影响其他 viewer。

Runtime form v2 catalogs：`GET .../runtime-forms/v2/:runtime` 对 pi/opencode/codex/grok 返回发布的完整 v2 definition（协议版本、schemaVersion、requiredClientCapabilities、dataSchema、uiSchema、capabilities、optionSources）。`GET .../runtime-options` 仅在请求带 `X-Raft-Runtime-Form-V2: 1` 时为有 v2 form 的 runtime 行加 `runtimeFormV2:{"protocolVersion":2}`，不发送该头则完全不含此字段，也不含 `formDefinitionRef`。Option source：pi 的 provider/providerModel、kimi/gemini 的 model 为静态定义；antigravity 无 option source（404 `unknown_option_source`）；kimi/pi/opencode/codex/grok/antigravity 的 v1 form/source 路由统一 404 `unknown_form_runtime`。opencode 的 model 源在 Computer probe live 时返回实时选项与 default，非 live 时返回 bundled list（不带 status）。codex/grok 的 model 源带 `option_source.status`：live 无 reason；非 live 为 `fallback|unavailable` + `reason`（missing_config/unsupported 不可重试，probe_timeout/probe_failed/machine_offline/no_models 可重试）；`refresh=1` 强制重新 probe；Computer 不可路由时直接 `machine_offline` 且不 probe。codex bundled list 保留每模型 reasoning efforts。

Runtime form 续：v2 form 目录新增 claude/cursor/kimi-sdk（含 optionSources 与 requiredClientCapabilities）。`GET .../runtime-options` 对 v1-capable runtime（builtin/claude/cursor/kimi-sdk）在未 opt-in v2 时带 `formDefinitionRef:{protocolVersion:1,runtimeId,schemaVersion}`；opt-in 时改为 `runtimeFormV2:{protocolVersion:2}` 且无 ref。kimi-sdk：v1 model source 在 missing_config/computer_offline 时返回 managed default `kimi-code/kimi-for-coding`（无 status），no_models/unsupported/其他错误分别 409 `runtime_model_source_no_models`/`runtime_model_source_unsupported`/`runtime_model_source_error`；v2 把前两者标为 `fallback`，其余标为 `unavailable`（`options:[]`），live 为 `status:"live"`。builtin：v2 model source 支持 live/fallback(machine_offline, bundled catalog)/unavailable(probe_timeout, `optionsByValue:{}`)，无 catalog authority 时 409 `builtin_catalog_capability_required`；v1 timeout 为 409 `builtin_catalog_unavailable`。claude/cursor model source 走同一 probe 并携带 live/fallback 状态；claude provider 为静态定义。

Locked module groups（此前已实现，本轮按可移植用例完成审计并标记 locked）：

- `messagesThreadSummaries.api`：`GET /api/messages/channel/:id` 与 context 在同一响应携带 `threadSummariesByParentMessageId`，只覆盖当页/当前窗口的 parent；无 thread parent 时为空对象；私有频道非成员仍被 403/404 拒绝。
- `servers.joinCommunity.api`：`POST /api/servers/join-community` 默认 `community`、可指定 `community-cn`；未知 slug 400 unsupported，已是成员 400 already，未 seed 404 not available，未认证 401/403。
- `deviceAuth.api`：gate 关闭返回 404，未设置默认开启；`authorize` 在 APP_URL 缺失时 503 `DEVICE_LOGIN_URL_UNAVAILABLE`；token 轮询 pending/approved/consumed/access_denied 与未知 code 的统一错误；approve 只能消费一次。
- `releaseNotes.api`：公开列表匿名为 `{items,nextCursor}` 且校验 limit/cursor；published/retracted/draft 投影；entries 只取 currentRevision 且按 ordinal；detail 对非法 id 400、未知 404、retracted stub 隐藏 entries。DB trigger 不可变性为不可移植排除项。
- `push.api`：APNs/FCM 注册 tuple 校验与按 installation/provider upsert；delivery status 按 server 报告 FCM 可用性；family revoke 无认证、30 天内幂等、过期后 terminal；在线 logout 标记 family 为 logout；web push 仅接受公开 HTTPS endpoint。

Thread 打开路径：`POST /api/channels/:id/threads` 缺 body 或 `parentMessageId` 时 400 `{"error":"parentMessageId is required"}`；parent 消息不属于该频道时 404 `{"error":"Parent message not found"}`。只带 parent 创建空 thread 不自动 follow 调用者（响应 `replyCount:0`、`lastReplyAt:null`、`participantIds:[]`）。带第一条回复时 follow 发送者与 parent 作者（如作者仍是该 server 成员且不是 system）。thread 新消息会清除所有 follower 的 done 状态，使 `/api/channels/threads/followed` 重新出现该 thread。

Followed thread 分页：`GET /api/channels/threads/followed` 默认返回全部 follow 且无 `next`；`limit=1..200` 时按 parent message createdAt 降序分页，带 `next`（末页 `null`），cursor 形如 `v1:<offset>`，非法 cursor 或 cursor 无 limit、limit 越界均 400。行新增 `parentChannelId`、`parentMessageCreatedAt`、`firstUnreadMessageId`、`hasMention`；`unreadOnly=1/true` 只返回未读 thread。Unread summary：`GET /api/channels/unread?summary=1` 的 `channels` 只含未读 scope，thread entry 带 `parentChannelId/parentMessageId`；`threadUnread` 按 parent channel 折叠未读 thread 数（count 为未读 thread 数，不是消息数）与 `hasMention`；done/unfollowed/zero-unread thread 不出现。

Agent credential 管理：`POST/GET/DELETE /api/agents/:id/credentials` 不需要 `X-Server-Id`。owner/admin 或 agent 的人类 creator 可 mint/list/revoke；普通 member 403 `{code:"insufficient_role",error:"issueAgentCredentials requires human creator authority"}`；非成员、未知 agent、软删除 agent 统一 404 `{code:"agent_missing",error:"Agent not found"}`。mint 回 201 `{credentialId,apiKey,agentId,serverId,scopes}` 且 `Cache-Control: no-store`，apiKey 立即可用于 `/internal/agent-api/`；list 同样 no-store，只回 `id/maskedToken/name/scopes/createdAt/lastUsedAt/revokedAt`；revoke 幂等 204，撤销后 token 立即 401。

Timezone observation：`POST /api/auth/me/timezone-observation` 需要认证，非法/空/超长/带额外字段的 body 400；首次写入建立 first 与 last，后续只更新 first 保持 + last 更新。`US/Pacific` 等别名按 canonical IANA zone 存储（`America/Los_Angeles`）。`GET /api/auth/me` 对只有 first 的 legacy 行回退 last=first（不伪造持久化 last）；下一次 observation 更新 last 后 /me 反映新值。

`GET /api/servers/unread-summary` 的 `activityUnreadCount` 与 `GET /api/channels/inbox?filter=all` 的 `totalUnreadCount` 在同一 server 上相等，且不随 inbox `limit` 改变；caught-up server 返回存在的 0，非成员不返回 entry；mute 不改变计数。Service 级 computeActivityUnreadCounts 与 canonical fixture 不是 HTTP 可达断言，列为排除项。

Thread 作用域与去重：同一 parent 存在历史重复 thread 时，summary 与 `GET /channels/:id/threads/:messageId` 选 canonical（最新回复时间优先，其次回复数，再创建顺序/id）。Thread mention auto-follow 受 parent 当前可见性约束：DM/private parent 外的用户与 agent 不会被拉入 follow，public parent 仍按 server 成员。手动 follow/unfollow/done/undone 对 private parent 的非成员统一 404，且不写 follow。public parent 成员被移出时保留其 thread follow；server 成员被移出时仅 prune 其 private/DM parent 的 thread follow。public→private conversion 后，历史 follower 不再看到 thread 的 followed/inbox/unread/sync 内容，且非成员冷读 thread 历史 404；private→public 恢复 channel details、thread info 与历史读取。

Thread follower 管理：`GET /api/channels/threads/followers` 对普通 viewer `canManage:false`，owner/admin 或 parent 作者 `canManage:true`。`DELETE /api/channels/threads/:threadId/followers/agents/:agentId` 仅 owner/admin/parent 作者可执行（其他 member 403）；首次删除回 `{removed:true,undoToken}` 并向 `channel:<threadId>` 发 `thread:followers-updated`，重复删除复用同一 token 且不重复发事件。`POST .../restore` 带当前 `undoToken` 回 `{ok:true,restored:true}` 并恢复 agent；旧 token 回 `{ok:true,restored:false}`，不会覆盖新删除。

Thread info 404 分支：channel 不存在、`X-Server-Id` 与 channel 不符、或 private channel 非成员统一 404 `{"error":"Channel not found or not visible"}`；message 属于该 channel 但没有 thread 时 404 `{"code":"THREAD_NOT_FOUND","error":"No thread found for this message"}`。Inbox Done history：`POST /api/channels/inbox/done` 与 `POST /api/channels/threads/done` 记录 doneAt；`GET /api/channels/inbox/done` 合并 channel+thread 行，支持 `limit/sort=asc/q/channelId`，返回 `{items,hasMore,totalCount:null}`；`POST /api/channels/inbox/undone` 与 `threads/undone` 清除 done 并恢复 Active。`

Thread unfollow 投递：unfollow 后 thread 仍在 Activity All 中作为 residue 行出现（`isFollowing:false`、`unreadCount:0`、`hasMention:false`、`firstUnreadMessageId:null`）；后续普通回复不恢复 follow，后续直接 mention 也不会让非 parent 成员在 `filter=mentions` 看到该 thread。

Deleted-thread Done 兼容：`POST /api/channels/threads/done` 若携带 `throughActivitySeq` 但值为 null/空 → 400 `DONE_FRONTIER_REQUIRED`；thread 已删除时，只有拥有该 thread 的 inbox fact 或 follow 的调用者才 200 `{ok:true}`（并把 read cursor 停在自有 evidence），其他成员 404；不存在的 id 404；显式合法 frontier 也 200 且不改变自有边界。

`channels.threads.api` 锁定说明：HTTP/frame 可移植用例已覆盖 thread create/summary/canonical dedup/info 404/follow/unfollow/done/undone/roster/follower undo/mention scope/conversion prune/member removal/inbox Done/unread fold/pagination/unfollow residue/deleted-thread Done。排除项：tracer/query-shape/RW 诊断（3–10、16 的 history trace、17、42 trace、48）、DB 并发 open（19）、stale socket delivery（40、43）、durable Agent Activity 行与 service delivery helper（1）、deleted-thread residue 的 DB cursor/counter/service 断言（46）。

Agent migration HTTP 面：`GET /api/agents/:id/migration` 对有 hosted migration 的 agent 返回 `{migration:{migrationRef,state,revision,targetKind:"hosted",targetMachineId,sanitized transport fields}}`，无记录返回 `{migration:null}`；无 history/migrationId/transferSummary/grantKey/manifest/token hash。`POST /api/agents/:id/migration/cancel` 由 owner/admin/creator 执行；body 必须携带 `migrationRef`（`mig_`+22）与正整数 `expectedRevision`，携带 `migrationId` 或非法 ref 400 `MIGRATION_REF_INVALID`，非法 revision 400 `MIGRATION_REVISION_INVALID`，找不到 404 `MIGRATION_NOT_FOUND`，revision 不匹配 409 `MIGRATION_REVISION_STALE`，终态 409 `MIGRATION_NOT_CANCELABLE`；成功回 200 `migration.state:"canceled_pre_flip"`、revision+1、cancelReason/cancelDispatchAttempts=1/cancelLastDispatchAt，取消字段保持 null。

Machine migration cancel：`POST /api/agents/:id/migration/cancel` 对 machine migration 同样要求 `migrationRef` + 正整数 `expectedRevision`；owner/admin/creator 通过后状态置 `canceled_pre_flip`、revision+1，并向 source 与 target Computer 各派发一次冻结的 `transportGeneration`（role=source/target、stopAgent=false），响应 `cancelDispatchAttempts:1`、`cancelLastDispatchAt`、`cancelErrorCode:null`。`GET /api/agents/:id/migration` 对 machine migration 返回 `targetKind:"computer"`、真实 `targetMachineId` 与同一 sanitized 字段；无记录仍 `{migration:null}`。

Machine migration start：`POST /api/agents/:id/migrate`（`targetComputer`）在 owner/admin/creator 下依次检查 active migration、source machine、migration/v3 capability（source/target/both → 422 `MIGRATION_RESUMABLE_CAPABILITY_REQUIRED`）、runtime support（422 `COMPUTER_CAPABILITY_INSUFFICIENT` with failures）、target online（409 `TARGET_COMPUTER_OFFLINE`）、target runtime detection pending/incomplete（409 `TARGET_RUNTIME_DETECTION_PENDING`）、Pro plan（403 `MIGRATION_PRO_PLAN_REQUIRED`）、transport provisioning（422 `MIGRATION_TRANSPORT_PROVISION_FAILED`）。成功创建 `provisioning` machine migration，返回 migrationRef/source/target/deadlines，并向 source/target 派发 upload/download lease；失败路径不创建 migration 状态或 lease。`markMachineMigrationTransportLost` 把状态置 `failed`，status 暴露 failureReason/transportErrorCode/transportErrorMessage/transportLostAt/transportTeardownAt，且始终不暴露 manifest/token hash/transferSummary。

Migration transport chunk 面：`POST/GET /internal/computer/agent-migrations/by-id/:ref/resumable/control` 用 Computer 凭据注册/读取 control manifest；超过 16KB → 413 `migration_control_manifest_too_large`，结构非法 → 400 `migration_control_manifest_invalid`，同 generation 不同 manifest → 409 `migration_control_manifest_conflict`，未注册读取 → 409 `migration_control_manifest_missing`。`POST .../chunks/:index/receipt` 校验 index 与 manifest sha256：不存在 index → 400 `migration_streamed_chunk_invalid`，digest 不匹配 → 409 `migration_chunk_receipt_mismatch`。`GET .../chunks` 回 chunks/received/missing；`POST .../upload-complete` 在缺 chunk 时 409 `migration_chunks_missing`（带 missing），完整后状态置 `transfer_complete`。

Migration target import：`GET /internal/computer/agent-migrations/by-id/:ref` 用 target Computer 凭据返回 `migrationRef/agentId/state/migrationGeneration/sourceMachineId/targetMachineId/canDriveTargetImport`。`start-transfer` 从 `ready` → `in_transit`，`flip-machine` 从 `in_transit` → `arriving`（并把 agent machine 指向 target），`arrived` 从 `arriving` → `completed`；每步校验 `migrationGeneration`，缺失 400 `migration_generation_required`，过期 409 `migration_generation_stale`，状态不符 409 `migration_not_ready`，非法 reportPath/reportSha256 400。`transport-lost` 由 source/target Computer 发送，记录 errorCode/message 并置 `failed`。

Migration cancel-ack / quiesce：`POST .../cancel-ack` 必须带 `migrationRef/transportGeneration/cancelGeneration/role/outcome`，缺失 400 `migration_cancel_ack_input_required`；Computer 必须匹配 role 对应 machine（否则 404）；transport generation 过期 409 `migration_generation_stale`，cancel generation 过期 409 `migration_cancel_generation_stale`；`canceled_post_flip` 的 target `cleaned` ack 409 `migration_cancel_outcome_mismatch`；成功回 `{ok:true,migration:{migrationRef,state,revision,disposition}}`。`resumable/source-quiesced` 需 `receipt` 对象（否则 400 `migration_source_quiesce_receipt_required`），成功回 migrationGeneration/leaseId；`resumable/source-progress` 回 `{ok:true,advanced:true,prepDeadlineAt}`。

Inbox firstMention：`firstMentionMessageId` 取该 scope 中 seq 大于当前 read cursor 的最早 notifiable/notified 用户 mention（不是 firstUnreadMessageId）；读过后推进到下一条或 null。mention-only 行（用户未加入但收到 public mention）以 mention 为 anchor，`unreadCount:0`、`hasMention:true`，即使已读也保留 `firstMentionMessageId`。

read_receipts_v0：server gate 开启后，channel detail 只暴露 agent peers 的 `peerReadStates:[{peerKind:"agent",peerId,maxReadSeq}]`，永不暴露人类 read state；超过 50 个 agent peers 时改为 `peerReadSummary:{peerCount,readCountAtSeq:[{seq,count}]}`。Agent history 读取推进 cursor 时向 `channel:<id>` 发 `scope_read:updated`（`scopeId/peerKind:"agent"/peerId/maxReadSeq`），非推进读取不发；人类 read/mark-unread 不发该事件。DM 中的 agent peer 同样 hydrate。

threads/done 拒绝语义：不存在、跨 server、无访问的 thread/channel、非法 id 全部 404 `{"error":"Inbox scope not found"}` 且 body 字节一致；一旦 caller 能看到该 channel 但不是 thread，回 400 `{code:"NOT_A_THREAD"}`。deleted thread 的 caller-owned evidence（inbox fact、follow 或 read cursor）仍可 200。task #48 read-all：ex-member/cursor 或 inbox fact residue 可 200 退休，cursor 只推进到 receiver-owned fact seq（不读 live frontier）；无 residue 的 stranger、缺失 id、跨 server channel 统一 404 `{"error":"Channel not found"}`；replay 幂等 200，receipt 仅含 ok/seq/readStateVersion。

Channel 存在性 probe：`GET /channels/:id/files`、`GET/POST /channels/:id/threads`、`GET /channels/:id/threads/:msg`、`GET /messages/channel/:id`、`GET /messages/sync?channel_id=` 对无访问的 private channel 与不存在的 id 统一 404 且 body 字节一致；对拥有 receiver-owned residue（inbox fact、read cursor 或显式 residue 标记）但已失去访问的调用者统一 403 `{"error":"Forbidden"}`，不泄露 live frontier。thread follow 视为 thread 访问权。

Inbox row 投影：DM scope 的 `kind` 为 `"dm"`，channel/private 为 `"channel"` 且带 `channelType`；thread 行带 `parentChannelId` 与 `parentChannelType`；private channel/DM/private-parent thread 在 `filter=all` 与 `filter=mentions` 中正常出现。follow/done/undone/unfollow 只读写 thread_follows；parent membership 本身不会让 thread 出现在 followed list，unfollow 也不移除 parent membership。

Attachment 单 id 读取矩阵：`GET /api/attachments/:id`、`/url`、`/html-preview-url` 对非 UUID 回 400 `{code:"invalid_attachment_id"}`；缺 `X-Server-Id` 400；Server 有成员表但调用者非成员 403；跨 Server 或不存在 UUID 统一 404 `{"error":"Attachment not found"}`；retired 用户 401。合成无成员表夹具保持旧的可读行为。

Attachment upload：`POST /api/attachments/upload` 接受 multipart `channelId` + 多个 `files`（也接受单个 `file`）。`ATTACHMENT_UPLOAD_ENABLED=false/0/off` → 503 `{error:"File uploads are disabled on this server",errorCode:"ATTACHMENT_UPLOAD_DISABLED"}`；空文件 400 `{"error":"Empty files are not allowed"}`；Free 单文件上限 50MB、Pro 200MB，超限 413 `{error:"Max 50MB per file",errorCode:"ATTACHMENT_TOO_LARGE",maxBytes}`；最多 10 个文件；成功回 `{attachments:[{id,filename}]}`，每次上传生成独立 projection id。

Attachment URL TTL：`GET /api/attachments/:id/url` 默认 300 秒；`disposition=inline` 且附件 mime 为 video/* 或 audio/*、且无 `download=1` 时为 3600 秒；其余（含 PDF、`disposition=attachment`、`download=1`）保持 300 秒。响应 `expiresAt` 与签名 TTL 一致；CDN 不用于原文件下载（presign 由附件存储路由决定）。

HTML preview token：`GET /api/attachments/:id/html-preview-url` 返回带 `previewToken`（HMAC-SHA256，绑定 attachmentId/serverId/actor、audience/type=`attachment-html-preview`、300s exp）与 `serverId` 的 URL，不携带用户 bearer。`GET /api/attachments/:id/html-preview` 校验 token 的 scope/expiry/audience/type，跨附件复用或过期/错 audience/type → 401；`token=` 用户 bearer query → 403；成功返回 `text/html`、`Content-Security-Policy: frame-ancestors 'self' <APP_URL>`、无 `X-Frame-Options`、`Cache-Control: private, no-store`。预览 token 不能授权普通 metadata/url/html-preview-url（401）。

Attachment query-token 两跳：`GET /api/attachments/:id/url?serverId=&token=` 无 Authorization 时用 query token 认证并返回携带同一 `token` 与 `serverId` 的流式 URL，`expiresAt:null`；hop2 `GET /api/attachments/:id?token=&serverId=` 认证后对缺失存储对象回 404（不是 401/400/403）。无效 token 401。`GET /api/attachments/:id` 也接受 `sk_computer_*` 凭据：按其 linked machine 的 server 鉴权；未指定 X-Server-Id 时使用该 server，指定其他 server 403；同 server 返回 attachment metadata，缺失/跨 server 404。

Attachment joint/legacy 可见性：`GET /api/attachments/:id` 与 `/url` 对已链接消息的附件按消息所在 channel 判定可见性；附件上传 channel 不再决定访问。joint canonical channel 的附件通过调用者 server 的 sibling projection 解析，只有该 projection 的成员可见；未链接的 draft 附件继续 cloaked（404）。public channel 消息即使附件行原本属于 private channel 也可见；反向则隐藏。

Attachment agent upload：`POST /internal/agent/:agentId/upload`（multipart `channelId` + `file`）使用 machine API key 鉴权，要求 agent 已分配到该 machine、agent 在 channel 内；`ATTACHMENT_UPLOAD_ENABLED=false/0/off` → 503 `ATTACHMENT_UPLOAD_DISABLED`；空文件 400 `Empty files are not allowed`；Free 50MB / Pro 200MB 上限，超限 413 `ATTACHMENT_TOO_LARGE`。

Attachment auth：`/api/attachments/:id` 与 `/url` 对 revoked access token（bearer 或 query token）与 retired user 均回 401，且不会到达 storage/presign。URL 的原文件 presign 不受 `CDN_BASE_URL` 影响。

`GET /api/servers/:id/machines` 现在每行带 `isComputer`、`computerAttachedByCurrentUser`、`agentCount`、`creator`（仍在 server 的创建者：type/id/name/displayName/avatarUrl/gravatarHash）与原始 `runtimes`；不暴露 `computerAttachedByUserId`。creator 已离开 server 时为 null。

Grok runtime 门：`grok_runtime_v0` 关闭时 `runtime-options` 不返回 grok 行；开启后返回，且 `runtime-models/grok` 仍可探测。machine capability 本身不被过滤。

`GET .../runtime-models/:runtime` 用 Computer probe 返回 `{kind:"live",value,models,default}` 或 `missing_config`（带 recovery）、`no_models`、`unsupported`、`error`（retryable，可选 code）；平铺 models 结果也支持。

Email invite：`POST /api/servers/:id/invites` 持久化 pending invite；`GET /api/auth/invite-info?token=` 与 `POST /api/auth/accept-invite` 同时支持 join link 与 email invite token。Pro seat 满时 member invite 400，guest invite 仍可创建，join link 仍可创建；接受后按 invite role 加入。

`DELETE /api/servers/:id` 向 `server:<id>` 发 `server:deleted`，并向每个成员 `user:<id>` 发 `server:membership-removed`（payload 均含 serverId）。

升级门：server gate 关闭时 machine list 的 `computerBroadcastPolicy` 为 `no_broadcast/broadcast_disabled` 且 targetVersion null；`POST .../computer/upgrade` 403 `remote_upgrade_disabled`；`POST .../computer-lifecycle-operations` upgrade 409 带 no_broadcast policy。

Builtin runtime form：v1 `runtime-form-definitions/builtin?schemaVersion=builtin-pi.create.v3` 逐字返回 released fixture（providerId/apiKey/model required，apiKey writeOnly，capabilities/optionSources 固定）。v2 `/runtime-forms/v2/builtin` 返回 providerId(select)/apiKey(password)/model(dependent_select)/supportsImageInput(boolean) 字段，`Accept-Language: zh-CN` 时 providerId label 为 `提供方` 并带 `Content-Language`/`Vary`。v2 provider source 与 v1 相同；v1 model source 仍是 dependent_select。

Lifecycle upgrade：`targetVersion` 缺省时用 `latestComputerReleaseForTesting` 解析最新版本并回 201；无可用 release 仍 409 `computer_upgrade_unavailable`。`/computer/upgrade` 通过 sender seam 投递，投递失败回 409 `computer_offline`。

Agent API id-less upload：`POST /internal/agent-api/upload`（multipart `channelId` + `file`）用 agent credential（`send`/`write`）绑定 runner 身份，不依赖路径里的 agent id；校验 channel 可见、空文件、Free 50MB / Pro 200MB 与 `ATTACHMENT_UPLOAD_ENABLED`，回单对象 `{id,filename,mimeType,sizeBytes,thumbnailUrl}`。上传后 `GET /internal/agent-api/attachments/:id` 可在同一 credential 下流式读取，带 `private, no-store`。

Agent API profile：`GET /internal/agent-api/profile` 无 target 时返回绑定 agent 的 name/displayName/description/avatarUrl；`?target=@handle` 需 `read` scope，可查同 server 可见的 human/agent，隐藏目录下要求共享 channel，否则 404；无 read → 403 `capability_not_authorized`。`POST /internal/agent-api/profile` 更新后回 `{ok,agentId,displayName,description}` 并向 `server:<id>` 发 `agent:updated`。

Agent API search：`GET /internal/agent-api/search?q=&channel=#name&sender=handle&sort=recent&limit=` 使用绑定 runner 身份与 `read` scope；结果带 `content/senderName(handle)/senderType/channelName/channelId/parentChannelId/snippet`，`hasMore` 反映截断；只返回 agent 可见的 public/私有/thread 消息，隐藏 private 不出现。

Agent status activity：`POST /internal/agent-api/activity`（agent `read` credential）按 `{schema,events}` 接收事件。status 只允许 working/thinking/online/error/offline（非法 400 `status_invalid`）；detail 必须是字符串且 ≤200（否则 400 `detail_invalid`/`detail_too_long`）；缺 eventId/occurredAt 计入 rejectedCount。重复 eventId（跨请求或批内）计入 rejectedCount；未来 occurredAt clamp 到接收时间；latest occurredAt 胜出。标准 status 标记 agent 已 adoption；adoption 后 hook 事件只记录、不再驱动 live dot。响应 `{ok,acceptedCount,rejectedCount,droppedCount}`。

Agent API task mutations：`POST /internal/agent-api/tasks/claim` 支持 `task_numbers` 与 `message_ids`（短前缀），返回 `{results:[{taskNumber|messageId,success,reason?,messageId?}]}`；自领返回 `already claimed by you`，他领返回 `already claimed`，成功置 assignee=agent、claimedAt、todo→in_progress。`tasks/update-status` 校验 status；普通 agent 的 todo→done/closed/in_review 409，非 assignee 的 in_progress→todo 409；admin agent 可强制；成功回 task JSON。`tasks/delete` 仅 creator 或 admin，否则 403 `task_delete_forbidden`。`tasks/convert` 把消息变成未认领 todo task（creator=agent、messageId=源消息），重复 convert 409。

Agent message resolve：`GET /internal/agent-api/messages/:messageId/resolve` 接受完整 UUID 或 8 位短 id；`read` scope 必需。只匹配 agent 可见消息，0 个 → 404 `{errorCode:"NOT_FOUND"}`，多个可见匹配 → 400 `{errorCode:"AMBIGUOUS_ID"}` 并建议完整 UUID。成功回 `{message:{message_id,channel_id,channel_name,channel_type,sender_type,sender_name,content,created_at}}`；DM 的 channel_name 用 peer 名称，thread 用 parent channel 名称。

Agent threads：`GET /internal/agent-api/threads` 返回绑定 agent 的 active follows（unfollow 的排除、不可见 private/thread 排除），字段 `target/parentChannelRef/parentMessageShortId/followedAt/reason/doneAt`。`POST /internal/agent-api/threads/unfollow` 支持 thread UUID 或 `#channel:shortId`，不可见/错误类型统一 404 `{error:"Thread not found"}`，成功 `{ok:true}` 并 tombstone follow。

Agent task assign：`POST /internal/agent-api/tasks/assign` 用 `@handle` 只在当前 channel 的 agent/human 成员中解析；server 成员但不在 public channel 的人类、缺失/歧义 handle 全部 404 `{code:"assignee_not_assignable"}`，且不改 assignee/revision。成功只设置 assignee/type、清 claimedAt、status 保持 todo。

Agent mention deliveries：`GET /internal/agent-api/messages/:messageId/mention-deliveries` 仅允许该消息的 agent 作者读取；其他 agent、缺失/非法 id 统一 404 `{status:"NOT_JOINABLE"}`。成功回 `{messageId,deliveries:[{targetId,targetHandle,...}]}`，targetHandle 保留发送时作者写的 handle。

Agent integrations discovery/login：`GET /internal/agent-api/integrations` 返回该 server 的 OAuth client 服务（id/clientId/name/description/homepageUrl/agentManifestUrl/agentManifestUrlSource/allowedScopes）与绑定 agent 的 activeLogins。`POST /internal/agent-api/integrations/login` body `{service}` 按 clientId 登录，首次 `status:"logged_in"`，重复 `already_logged_in`；返回 service 投影与 `scopes:["identity","openid","profile"]`，并记录 agent/server/client active login。OAuth client 可携带显式 `agentManifestUrl`，其 source 为 `explicit`。

Agent Marketplace discovery：`GET /internal/agent-api/integrations/marketplace?query=&limit=` 只返回 `third_party_global` 且 enabled/published/humanMarketplaceVisible 的 app；private/hidden/disabled 不枚举。响应 `{surface:"public_marketplace",metadataTrust:"untrusted_app_supplied",query,apps:[{id,clientId,name,description,homepageUrl,allowedScopes,installedOnServer}]}`；query 按字面 substring（%/_/\ 不当通配符），limit 1..50，越界 400；`installedOnServer` 反映该 server 的 active installation。

Joint message resolve：`GET /internal/agent-api/messages/:id/resolve` 对 joint canonical 存储消息通过调用者 server 的 local projection 解析；返回 `channel_id` 为 local projection，`channel_name` 为 local channel name，`channel_type:"channel"`，只在该 projection 可见时出现。

Attachment comments：`POST /api/attachments/:id/comments` 为 human 唯一创建入口，保存 content/anchor（lines）并回 `{message:{id,content,senderType,createdAt,anchor}}`。`GET /internal/agent-api/attachments/:id/comments` 需 read scope，返回 comments 与 viewer：agent 永远 `canComment:false,reason:"agent_descoped"`；`canResolve` 仅在 agent 是 parent-message 作者时为 true，并带 `resolveAction:{type:"reaction",emoji:"✅"}`。parent 作者的 ✅ reaction 使 comment `resolved:true` 并给出 resolvedBy/resolvedAt。`POST` agent 创建恒 403 `agent_comment_create_disabled`；缺失/非法 attachment 404。

Integration login 的 service-aware defaults：client 有显式 allowedScopes 时默认 scopes 为 `["openid"]`；无显式 catalog 时默认 `["identity","openid","profile"]`。显式 `scopes` 必须是默认集合子集，否则 400 `{errorCode:"INVALID_SCOPE"}`；成功只回实际使用/请求的 scopes。

Agent task create 的 `assignee`：在 channel 内解析 agent/human，创建任务后置 claimedById/Type，并回 `assignmentReceipt:{messageId,content,assignee,state:"assigned"}`；receipt 内容包含 `@handle`，并为该 assignee 写一条 `personalMention:true,unreadEligible:true` 的 inbox fact（其他 assignee 不受影响）。

Retired built-in integration：agent integrations inventory/login 过滤 `appType == "slock_builtin"` 行；built-in app 即使 published/visible 也不出现在 services，login 404，且不产生 activeLogin。

Task realtime projection：`PATCH /api/tasks/:taskId/claim` 只向 `channel:<id>` 发 `task:updated`（payload task 含 id/status/claimedById），不重发未变化的 `message:updated`。message-only 行不是 task，claim 回 404 且不广播任何事件。

Integration login 的 installed app：除本 server 的 integration service 外，也按 clientId 解析该 server 的 active installation（third-party/global/private installed app）。首次回 `status:"logged_in"` + `requestId`，不带 `approval`；重复回 `already_logged_in`。未安装的跨 server private app 仍 404。

Integration login 的 uninstalled public app：已发布可见的 third-party global app 在未安装时回 200 `{status:"install_required",nextAction:"install_from_marketplace",service,scopes,installation:{serverSlug,marketplaceUrl,actionCardMessageId:null}}`；marketplaceUrl 含 `marketplace_app=<client record id>`。非法 scope → 400 `INVALID_SCOPE`；未安装的跨 server private app → 404 `Registered service not found`；安装后再次 login → `logged_in`。

### channels.joinCapability.api

公开频道 self-join 在判定 capability 之前先处理幂等成员：

- human `POST /api/channels/:channelId/join`：无 server role 且非成员 → 403 `{"error":"Server role cannot join public channels"}`，不写成员；已是成员 → 200 `{"ok":true}`，成员保持不变。
- agent credential `POST /internal/agent-api/channels/:channelId/join`：无 server role 且非成员 → 403 同上；已是成员 → 200 `{"ok":true}`，不要求 server role。
- legacy machine `POST /internal/agent/:agentId/channels/:channelId/join`：machine key 与 `machineKeys` 均可认证；同样的 already-member 200 与无 role 403。

### appLogin.api

HarmonyOS app login handoff:

- `POST /api/auth/app-login/start` 接受 `returnUri` 仅限 `raft://login/callback`、`raft-debug://login/callback`，否则 400 `return_uri_not_allowed`；`codeChallengeMethod` 仅 S256；challenge 必须是 43 字符 base64url，否则 400 `code_challenge_invalid`；成功 201 `{requestId,loginUrl,expiresAt}`，`loginUrl = <APP_URL>/login/app?request=<id>`。
- `GET /api/auth/app-login/requests/:requestId` 需登录，匿名 401。
- `POST .../approve`：pending → 200 `{redirectUrl:"<returnUri>?requestId=<id>&code=<one-time>"}`；重复/已拒绝 409；过期 410 `{code:"request_expired",redirectUrl:"...&error=expired"}`；未知 404。
- `POST .../deny`：pending → 200 `{redirectUrl:"...&error=access_denied"}`；之后 approve 409。
- `POST /api/auth/app-login/complete`：code 与请求绑定；错误 verifier → 400 `pkce_mismatch` 且不消耗 code；正确 → 200 正常 session（access/refresh token，`/api/auth/me` 可用）；重放 → 410 `code_consumed`；请求过期 → 410 `code_expired`。

### tasks.shapeSurfaces.api

任务形状在 HTTP 表面上的删除/可达性：

- `DELETE /api/tasks/:taskId` 对 v0 orphan、backfilled、v14 三种 canonical 形状都返回 200，且 `GET /api/tasks/channel/:channelId` 只少这一条，不复活。
- backfilled 形状删除时同步清空其 message-side `task_*` 影子列；影子不会在下一次读取时复活。
- 只有 `messages.task_*` 的消息行不是任务：不出现在频道任务列表，`DELETE /api/tasks/:messageId` 回 404。
- agent 任务端点按编号 claim/update-status 不能触达 v0 orphan（无 host message）：claim 结果 `success:false, reason:"task not found"`，update-status 404，且不写 orphan；相邻 backfilled 任务仍可 claim。
- 新增 legacy `/internal/agent/:agentId/tasks/{claim,update-status,delete,convert}`，接受 machine key + 路径 agent id。

### rbacPhase3Relations.api

RBAC Phase 3 精确对象权限：

- Agent creator：admin→member 降级后仍可 patch/stop/reset/credentials/delete 自己创建的 Agent，不能操作他人 Agent；离站（remove 或 leave）后所有精确权限失效（403 `Not a member of this server`，credentials 走 404 `agent_missing`）。
- Machine registrant：降级后仍可 patch/rotate-key/delete 自己的 Machine，不能操作他人 Machine；离站后 PATCH、rotate-key、computer/restart、workspaces、DELETE 全部 403 `Not a member of this server`，行与 description 不变，owner 仍可操作。
- `POST /api/servers/:id/leave` 现在和移除成员一样，对离开者调用 `removeServerMembership`，先发 `server:membership-removed` 再关闭连接。
- S11：离站 creator/registrant 的在线 socket 不再收到 `agent:session`/`machine:status` 服务器房间事件；同一 server 的授权成员仍收到。
- `GET /api/servers/:id/machines/:machineId/workspaces` 对非成员回 403 `Not a member of this server`（此前 404）。

### oauthOfflineSource.api

离线 App 重新发布后的 human login：

- `GET /api/integrations/clients` 返回本 Server 拥有或已安装的 App（含 offline private App），行含 `id/clientId/name/appType/publishStatus`。
- 离线 private third-party App 在无 active installation 时 lookup 404；仅设置 `publish_requested` 仍 404。
- reviewer 置为 `published` 时恢复 owner Server 的 active installation（空 groups），lookup 200；`authorize/human` → code → `oauth/token` → `userinfo` 正常。
- 已撤销的 access token 仍 401，撤销行数不变。
- 手动卸载后 reviewer 置 `unpublish_requested` 再置 `private`，会重建 owner Server 的 installation（空 groups）；本 Server lookup 200，其他 Server 404。

### assistant.api

RFC 074 personal assistant：

- `PUT/DELETE /api/agents/:id/assistant-owner` 仅 creator 可设；`identity_borrowing` flag 关闭 → 403 `assistant_not_enabled`；同一 owner 已有其他 assistant → 409 `assistant_already_set`；agent 仍在普通频道 → 409 `assistant_has_channels`；重复设置幂等；agent credential 调用 → 401。
- 链接同时创建 owner↔assistant DM。`/internal/agent-api/context` 的 `agent.assistantOf` 仅在链接存在、owner 仍是 server 成员、flag 开启时返回 `{userId}`，否则 null。
- `GET /internal/agent-api/assistant/owner-inbox`：返回 owner 可见频道/线程的未读项，排除 DM 与 DM 下的线程；thread 项 `kind:"thread"` 带 `parentChannelId`；不改变 owner 的读状态。
- `GET /internal/agent-api/assistant/owner-messages?channelId=...`：只读 owner 可见的普通频道/线程；DM、DM 线程、不可见 private、未知 id 统一 404 `channel_not_found`；不改变读状态。
- 每次读取都重新校验链接、owner 成员身份与 flag。
- assistant 只能存在于 owner DM：加入普通频道 → 403 `assistant_channel_forbidden`；发送仅允许 `dm:@<owner>`，其他 DM/频道 → 403。

### tasks.orphanCleanup.api

频道/Agent 删除后的任务清理：

- `DELETE /api/channels/:channelId` 软删频道时，非 `done/closed/cancelled` 的 canonical task 自动置 `closed`，写 `completedAt`、`closedAt`，并记录 system `closed` 事件；`done` 保持不变。
- Agent 软删时释放所有以该 agent 为 assignee 的 task 归属（assignee/type/claimedAt 清空），status 不变。
- 频道已删的 orphan task：`PATCH /api/tasks/:id/status` 只接受 `done/closed/cancelled`，其他状态 → 409 `{code:"channel_deleted_terminal_only"}`；`PATCH /api/tasks/:id/claim` → 409。
- orphan task 可被 admin/owner `DELETE /api/tasks/:id`；非 creator 的普通 member → 403。


### B2：`/health` 真实 200

- 无 `DATABASE_URL`：`GET /health` → 503 `{"status":"error","detail":"database unreachable"}`，与内存存储模式一致。
- 有 `DATABASE_URL` 且 Postgres 可达：执行 `SELECT 1`，`GET /health` → 200 `{"status":"ok"}`，带 `X-Robots-Tag: noindex, nofollow` 与 JSON content-type。
- URL 非法、`sslmode` 非 `disable`、连接失败或查询失败：仍 503，错误文本不外泄。
- `DATABASE_URL` 由 `make pg-url` 生成；`make pg-up` 起本地 Postgres，`make test-pg` 跑真实 `SELECT 1`。
- 领域存储仍是内存实现；B2 只接通健康探针。

### agents.api：identity 组

- `GET /api/agents/:id/channels`：只返回 viewer 可见的 channel/private/joint 成员关系；隐藏 private/joint 不出现；DM 不出现；`activityMuted`/`muteFromSeq` 取该 agent 的偏好，viewer 的 mute 不泄漏；`archivedAt` 为 null。
- `POST /api/agents`：同 server 已有 active agent 使用同名 handle → 409 `Agent name is already taken`；保留 handle（all/human(s)/agent(s)/here/idle/busy/system/reminders，大小写不敏感）→ 400 `This username is reserved. Choose another name.`。
- Agent creator 在创建时写入；member 尝试 `PATCH /api/agents/:id/creator` → 404，creator 不变；`GET /api/servers/:id/members/:memberId/profile` 返回 `createdAgents`。
- member 的 viewAgents authority 可读取 `GET /api/agents/:id/runtime-options`（200）。

### agents.api：runtime 校验组

- `POST /api/agents`：`runtimeConfig.provider` 为 custom 且 runtime 为 cursor → 400 `runtimeConfig.provider is not supported for runtime: cursor`。
- 结构化 config 校验：custom model 缺 `name` → 400 `runtimeConfig.model.name is required`；custom provider 缺 `apiKey` → 400 `runtimeConfig.provider.apiKey is required`。
- 已废弃 runtime（kimi/gemini/antigravity/copilot）不能新建：legacy `runtime` 或结构化 `runtimeConfig.runtime` → 400 `Runtime is deprecated and cannot be selected: <runtime>`。
- `PATCH /api/agents/:id` 禁止切换到废弃 runtime；若当前 agent 本身就是该 legacy runtime，则允许继续编辑并保留 runtime/model。


### agents.api：runtime 生命周期组

- `GET /api/agents/:id` 对非 UUID 回 404 `{"error":"Agent not found"}`（不进入查询）；agent 不属于请求头 `X-Server-Id` 指定的 Server 时同样 404，指定正确 Server 时 200。
- `POST /api/agents/:id/start` 的权限是 `controlAgentRuntime`（member/admin/owner）或 human creator：guest → 403 `The `controlAgentRuntime` capability or human creator authority is required to control agents`，未认证 → 401，跨 Server → 404 `Agent not found`。
- `POST /api/agents/:id/start` 未分配 Computer → 409 `{"error":"No machine assigned. Please assign a machine to this agent first.","code":"machine_unassigned"}`；Computer 离线 → 409 `{"error":"Machine is offline","code":"machine_offline","machineAffinityRoute":"owner_missing"}`；在线 → 200 `{"ok":true}`（不再回 202 accepted）。
- `POST /api/agents/:id/stop` 与 `/reset` 对 member 开放；external runtime 的 start/stop/reset 仍 400 `External agents do not use Raft-managed runtime lifecycle`。
- `POST /api/agents/:id/reset`：`mode` 只认 restart/session/full；未知 mode 回落到 session，无 mode 且 `clearWorkspace:true` 等价 full；full 需要 `resetAgentWorkspace`（owner/admin 或 creator），否则 403 且错误文本含 `resetAgentWorkspace`；成功 202 `{"ok":true,"status":"accepted"}`。
- `DELETE /api/agents/:id` 需要 `deleteAgents`（owner/admin）或 human creator，否则 403 `The `deleteAgents` capability or human creator authority is required to delete agents`；`workspace` 只接受 keep/delete，其他值 → 400 `{"error":"workspace must be keep or delete","code":"archive_workspace_choice_invalid"}` 且 agent 不变；`workspace:"delete"` 但 agent 无 Computer、是 external、或已是 hosted → 409 `{"error":"This agent has no workspace on a Computer.","code":"archive_workspace_unavailable"}`；迁移进行中 → 409 `archive_migration_active`。
- `DELETE /api/agents/:id` 成功回 200 `{"ok":true}`，软删 agent、释放其 task 归属、写 archive 行，并向 `server:<id>` 房间广播 `agent:deleted` `{"agentId":...}`；随后 `GET /api/agents/:id` 404。
- `GET /api/agents/archived` 行含 `agentId/machineName/workspaceState`；keep 归档为 `on_computer`，未分配 Computer 时 `machineName` 为 null。

### agentArchive.api

- 归档保留 workspace（`DELETE /api/agents/:id` 无 body 或 `{"workspace":"keep"}`）：archive 行 `workspaceState:"on_computer"`、`machineId`、`machineName` 快照、`pendingOp:null`、`waitingForComputer:false`、`archivedAt`/`archivedByUserId`，并取消该 agent 的 reminders（`GET /api/reminders` 不再列出）；agent 软删后 `GET /api/agents/:id` 404。
- workspace 选择只接受 keep/delete，其他值 → 400 `{"error":"workspace must be keep or delete","code":"archive_workspace_choice_invalid"}`，agent 与 archive 行都不变。
- `{"workspace":"delete"}` 归档：archive 行保持 `workspaceState:"on_computer"`、`pendingOp:"delete"`、`waitingForComputer:true`（Computer 未连接时等待它执行删除）。
- 没有 Computer workspace 的 agent（未分配 machine / external / hosted）：归档 keep 时 `workspaceState:"deleted"`、`machineId:null`、`machineName:null`。
- `GET /api/agents/:id/archive`：editAgents（owner/admin）或 human creator 可读；其他 member / guest → 403 `You cannot manage this archived agent's workspace`；跨 server 或未归档 → 404 `{"error":"Archived agent not found","code":"agent_not_archived"}`。视图字段：`agentId/archivedAt/archivedByUserId/machineId/machineName/workspaceState/pendingOp/waitingForComputer/lastErrorCode/lastErrorAt`。
- `POST /api/agents/:id/archive/workspace`：只接受 `action:"delete"`，否则 400 `{"error":"action must be delete","code":"archive_workspace_action_invalid"}`；workspace 不在 Computer（`workspaceState` 非 `on_computer` 或无 `machineId`）→ 409 `{"error":"The workspace is not on a Computer.","code":"archive_workspace_unavailable"}`；已有待执行 op → 409 `{"error":"Another workspace operation is still running.","code":"archive_op_pending"}`；成功 200 `{"archive":...}` 且 `pendingOp:"delete"`。
- 归档与 workspace op 都向 `server:<id>` 房间广播 `agent:archive:updated` `{agentId}`；归档同时广播 `agent:deleted`。
- `GET /api/agents/archived`：member/admin/owner 200，每行 `agentId/machineName/workspaceState`；guest 403。
- 迁移进行中的 agent 不能归档 → 409 `{"code":"archive_migration_active"}`，agent 未删除且没有 archive 行。
- 归档路由（archive 视图、workspace-files、workspace-files/read、archive/workspace）对非 creator 的 member 一律 403，对 guest 403/404，对指向其他 server 的请求 404。

### agents.api：create 投影与 creator DM 组

- `POST /api/agents` 接受结构化 `runtimeConfig`：补齐 `version:1`、`mode:{kind:"default"}`、`reasoningEffort:null`，保留 `provider`/`model`/`command`；`envVars` 只保留非 `ANTHROPIC_` 键。
- Claude custom provider 派生环境变量：`ANTHROPIC_BASE_URL`/`ANTHROPIC_API_KEY` 取 provider，custom model 的 `ANTHROPIC_CUSTOM_MODEL_OPTION` 取 model name；`PATCH` 只改 `envVars` 时丢弃客户端送来的 `ANTHROPIC_*`，保留存储 provider 派生的值。
- `GET /api/agents` 对非 admin 的普通 member 不返回 `envVars`/`runtimeConfig`（creator 本人可见）；`serverRole` 为 `member`，`GET /api/agents/:id` 同。
- 顶层 `envVars` 在边界解析：非对象 → 400 `envVars must be an object`；非字符串值 → `envVars keys and values must be strings`；非法键 → `Invalid env var key "<key>": must match [A-Za-z_][A-Za-z0-9_]*`；含 NUL → `envVars keys and values must not contain null bytes`；`null`/缺省为无操作，非法值不写入且不改变已存值。
- `POST /api/agents` 为 creator 建立与 agent 的 DM（空会话，重复调用复用同一 id），只对该 creator 的 `GET /api/channels/dm` 可见；同时向 `channel:<dmId>` 与 `user:<creatorId>` 广播 `dm:new` `{channelId}`，并向 `server:<id>` 广播 `agent:created`（不含 `envVars`）。
- `GET /api/channels/dm` 行新增 `peerId`/`peerType`(`agent`|`user`|`self`)/`lastMessageAt`；`POST /api/channels/dm` 接受 `{agentId}`，agent 不在本 server → 404 `Agent not found in this server`，成功复用 canonical DM。
- `PATCH /api/agents/:id` 支持顶层 `displayName`/`model`/`reasoningEffort`/`runtime`：`model` 写成 preset、`reasoningEffort` 写回 config，`runtime` 切换同时更新 runtime id 与 config；非法 `restartMode` → 400 `Invalid restart mode: <value>`；响应回显 `name/displayName/model/runtime/reasoningEffort/runtimeConfig/envVars`。

### rbacPhase2Corrections.api

- `GET /api/servers/:id`：owner/admin/member 得到 member profile（`id/ownerId/name/slug/avatarUrl/plan/translationEnabled/publiclyVisible/publicGuestJoinEnabled`），`plan:"founder"` 与第三方 avatar URL 原样返回。
- 同路由对 guest 只回公开投影：恰好 `avatarUrl/id/name/slug` 四个键，`avatarUrl` 为 null，不含 ownerId/plan/translationEnabled/publiclyVisible/publicGuestJoinEnabled 等管理字段。
- `GET /api/servers/:id/settings` 仅 owner/admin 200，member/guest 403；同一 member/guest 仍可读 `GET /api/servers/:id/notification-settings`，member 仍可读 `GET /api/servers/:id/onboarding-settings`（exact-self 状态与 Server 设置分离）。
- `GET /api/servers/:id/machines` 对 owner/admin/member 200，对 guest 403；guest 作为 Machine registrant 仍可 `PATCH /api/servers/:id/machines/:machineId` 改自己的 Machine（200 + description 回显），对他人 Machine 403。

### internalAgentApi.auth：Marketplace 安装卡组

- 第三方 App 文本按 inert 规则渲染：`</result>`/`</preview>`/`</match>`/`<omit/>` 之类标签转义为 HTML 实体，`@name` 变 `user:name`，超过 4000 字符截断；`/internal/agent-api/integrations/login` 的 `service.name` 与卡片标题/正文都用该渲染结果。
- 未安装的已发布 Marketplace App：`POST /internal/agent-api/integrations/login` 回 200 `{status:"install_required",nextAction:"install_from_marketplace",service,scopes,installation:{serverSlug,serverName,marketplaceUrl,target,actionCardMessageId}}`，`marketplaceUrl` 含 `marketplace_app=<clientRecordId>`，未给 `target` 时 `actionCardMessageId:null` 且不写安装行。
- 带 `target:"#channel"` 时在目标频道写一张 `integration:install_marketplace_app` 动作卡：消息 `actionMetadata.action` 含 `clientId`(record id)、`clientKey`、`clientName`(inert)、`clientNameSha256`(原始名 SHA-256)、`agentId`、`agentName`、`scopes`；`presentation.title` 为 `Install <inert name> on this Server`，`displayItems` 不含 `clientNameSha256`；响应 `installation.target` 回显原始 target 并给出 `actionCardMessageId`。
- `target` 不可见或不存在 → 404 `Install target not found or not visible to this agent`；非 openid 的 scope → 400 `INVALID_SCOPE`；未发布的 private App 仍 404 `Registered service not found`。
- `POST /api/actions/:messageId/execute`：仅该 Server 的 owner/admin 可执行（member 403，其他 Server 的 header 404）；`expectedState` 与卡片状态不符 → 409；执行前重新校验 App（enabled、`third_party_global`、published、human-visible、clientKey、名字 sha 与 agent 名），变更 → 409 `MARKETPLACE_APP_CHANGED`/`AGENT_BINDING_CHANGED` 且不写安装。
- 执行成功 200，`metadata.state:"executed"`、`result.kind:"marketplace-app-installation"` 含 `clientId`(record id)/`clientKey`/`clientName`/`serverId`/`agentId`/`agentName`/`scopes`，只写一行 installation；再次 `expectedState:"executed"` 幂等返回，不再写安装；之后同一 login 请求回 `status:"logged_in"`。

### internalAgentApi.auth：integration app 列表/状态组

- `GET /internal/agent-api/integrations/app`：agent credential 需 `read`；server-admin agent 看到本 Server 全部 user-managed `server_local`/`third_party_global` App，其他 agent 只看到自己是 owner 维护者的 App。
- 行投影：`state:"committed"`、`card:null`、`installationId`、`name/clientKey/createdAt/updatedAt/description/homepageUrl/callbackUrl/agentManifestUrl/scopes/category/dataAccessSummary/logoUrl/appType/publishStatus/enabled`、`authority`(`owner`|`admin`)、`recoveryCommand`（`raft integration app rotate-secret --client <key> ...`）。
- external-registration-bound App（Slack 等 platform 注册，`externalProvider` 非空）不出现在列表，也不可由 status 读取（404），对 admin 和 owner 一致。
- `GET /internal/agent-api/integrations/app/status` 只接受 `client` 或 `card` 其一，二者同时或都缺 → 400 `Exactly one of card or client is required`；未知/无权/隐藏 → 404 `Integration app not found`；成功 `{"app":{...}}`。
- `installationId` 严格按请求 Server 解析：未安装或只在别的 Server 安装 → null；本 Server 有 active installation → 该 installation id（列表与状态一致）。

### internalAgentApi.auth：app 元数据与 services 投影

- `POST /internal/agent-api/integrations/app/update` 接受 `{clientKey, whenToUse}`；只有 App owner agent 或 server-admin agent 可改（否则 404），`clientKey` 缺失 → 400 `INVALID_APP_METADATA`。
- `whenToUse` 校验：≤160 code point、单行（无控制字符）、inline code 之外的裸 `@scope/pkg` 拒绝；拒绝统一 400 `{errorCode:"INVALID_APP_METADATA"}` 且不写库。空串表示清空（读回 null），合法值原样存储。
- `GET /internal/agent-api/integrations` 的 `services[].whenToUse` 为 inert 渲染：裸 `@alice` → `user:alice`，反引号内 `` `@acme/metrics` `` 原样保留。
- `services` 只列 enabled 的非 builtin App：被禁用的 server-local App 不出现（daemon prompt 与 `raft integration list` 都不再看到它）。

### internalAgentApi.auth：register app 卡片组

- `POST /internal/agent-api/integrations/app/prepare`（`mode:"register"`，需 agent credential `send`）：校验 name/returnUrl/target，201 回 `{status:"prepared",actionCardMessageId,action:{type:"integration:register_app",name,clientKey?,homepageUrl?,returnUrl,scopes}}`；未给 `clientKey` 时 action 不含该键。
- 卡片消息 `actionMetadata.presentation`：`title:"Register Connected App <name>"`、`confirmLabel:"Register App"`、`genericApprovalAllowed:true`、`displayItems` 含 `name/clientKey?/returnUrl/scopes`；`warning` 明示请求 agent 成为初始 owner 且卡片不存 client secret。prepare 与历史里都不出现 `raft_secret_`。
- `POST /api/actions/:messageId/execute`：仅 owner/admin；返回 `metadata.result.kind:"integration-app-registration"`、`mode:"register"`、`clientId`、`clientKey`、`clientName`、`scopes`，metadata 不含 secret。
- 执行时创建 `server_local` App：clientKey 为请求值或 `"<slug>-<6 hex>"`（如 `generated-demo-abcdef`），returnUrl/homepageUrl/appType 按卡片写入，请求 agent 成为 App owner 维护者；同一卡片重放（`expectedState:"executed"`）返回既有结果且不重复建 App。
- 目标频道不可见 → 404 `Target channel not found`；缺 name/returnUrl/mode 非 register → 400 `INVALID_APP_METADATA`；clientKey 冲突由创建期校验拒绝（409 `APP_REGISTRATION_REJECTED`）。
- 初始 secret 的一次性 owner 私有 wake 未移植（无 orchestrator 投递通道）；卡片、历史与执行 metadata 一律 secret-free。

### internalAgentApi.auth：manifest 发现回退

- App 未显式声明 `agentManifestUrl` 且 `homepageUrl` 是 https 时，`/internal/agent-api/integrations` 的 `services[]`、`integrations/login` 的 `service`、`activeLogins[]` 以及 Marketplace 公共行都投影 `https://<homepage host>/.well-known/raft-agent-manifest.json`，`agentManifestUrlSource:"well_known"`。
- 显式登记 manifest 时保持原 URL 与 `agentManifestUrlSource:"explicit"`；无 homepage 或非 https 时两者为 null。

### internalAgentApi.send：线程回复目标组

- `POST /internal/agent-api/send` 成功回 `{ok:true,state:"sent",messageId,messageSeq}`（同时保留旧 `id/channelId/content/seq` 字段供既有客户端）。
- `#channel:<suffix>`：suffix 命中已有 thread 的父消息前缀或 thread channel id 前缀时投到该 thread；只命中父频道消息时自动建立 thread（`kind:"thread"`、`parentChannelId`/`parentMessageId`）并投递首条回复；没有任何命中 → 404，错误文本含 `Thread target not found or not replyable` 与 `parent message must exist`。
- 线程目标要求 agent 是父频道成员：公开频道非成员 → 403 `Agent is not a member of the parent channel`；不可见的 private 父频道 → 404（cloak，不泄漏存在性）。
- `dm:@<peer>:<suffix>`：DM 内命中父消息前缀时自动创建 DM thread 并投递；已有空 thread 复用；找不到 → 404 同上错误文本。
- 已存在的空 thread（由父消息 OPEN THREAD 建立）在首条 agent 回复时复用，不新建第二个 thread。

### internalAgentApi.send：幂等与附件校验组

- `idempotencyKey`：同 key 重复发送且 target/content/attachmentIds 全同 → 200 返回原 `messageId`/`messageSeq`，不再写新消息；任一不同 → 409 `{code:"idempotency_key_reused",mismatch:"target"|"content"|"attachments",suggestedNextAction:"...new idempotencyKey..."}`，不回原消息 id。
- `reconcileOnly:true`（v2）：key 未提交 → 200 `{ok:true,state:"not_found",reconciliation:true}` 且不写；已提交 → 200 `{ok:true,state:"committed",messageId,messageSeq,reconciliation:true,receiptComplete:false}`。
- `attachmentIds` 边界：每个元素必须是单个 UUID；非数组或含空格/逗号拼接值 → 400 `{code:"attachment_id_invalid"}`，错误文本 `Not sent: attachmentIds entry <n> is not a single attachment ID. Send one ID per --attachment-id.`，不回显被拒值，也不写消息。
- v1 与 v2 发送都返回统一的 `{ok,state:"sent",messageId,messageSeq}`（同时保留旧 `id/channelId/content/seq`）。

### internalAgentApi.send：mention 解析组

- v1 `POST /internal/agent-api/send`：正文中 `@handle` 命中本 Server 存在但不在目标频道的 agent 时，回 `pendingMentionActions`（sender-only）：`resolutionId` UUID、`messageId`、`targetType:"agent"`、`targetHandle`、`targetAvatarUrl`、`reason:"not_member"`、`availableActions:["notify"]`、`expiresAt` ISO。
- v2 send：无法解析到可见目标的 `@handle` 回 `unresolvedMentionHandles`（带 `@` 前缀），且不出现 `pendingMentionActions`；markdown inline/fenced code 里的 `@` 不计入。
- 隐藏 human directory 开启时，未类型化的 `@handle` 一律记为 unresolved（不泄漏存在性）；typed mentions（`mentions:[{type,id,name}]`）不产生 pending/unresolved。
- 发送者自己的 handle 不计入解析结果。

### internalAgentApi.send：freshness hold 组

- `POST /internal/agent-api/send` 的 freshness gate（SMR-006）在接口启用时运行：带 `seenUpToSeq`、`sendDraft`、`continueAnyway`、`draftReholdCount`、`draftReplacedExisting` 或 `freshnessContextMode:"withheld"` 的发送 opt-in；`SLOCK_ATTESTED_SEND_MODE=force` 时无标记的普通发送也走 gate。接口关闭（off/未知）且请求 opt-in → 403 `{"error":"Send freshness interface is not enabled for this agent."}`；`allowlist` 只对 `SLOCK_ATTESTED_SEND_SERVER_IDS`/`SLOCK_ATTESTED_SEND_AGENT_IDS` 中列出的 server/agent（或 `*`）启用。
- 边界：显式 `seenUpToSeq`（向下取整、≥0）为 model-seen 边界，并与会话内最新一条非本人消息的 seq 取 min；thread 无显式边界时回退到父消息 seq；channel/DM 无边界时边界为 0。只统计本会话中 seq 大于边界、且 sender 不是本 agent 的消息，最新 seq 之前没有新消息则不 hold（`state:"sent"`）。
- inline hold 响应：200 `{ok:true,state:"held",outcome:"held",subtype:"freshness",reason:"newer_messages_available",decision:"syncing_hold",producerFactId:"freshness_decision_fact:<64 hex>",available_actions:["check_messages","send_draft","send_anyway"],heldMessages[≤3 条],newMessageCount,shownMessageCount,omittedMessageCount,seenUpToSeq,seenUpToMessageId,firstShownSeq,mentionAnnotation:{formalMentionCount}}`；`draftReholdCount ≥ 3` 时附 `continueAnywaySuggested:true`；held 响应不带 `pendingMentionActions`；不出现 `neverShownRange`/`neverShownCount`。
- 计数语义：有 model-seen 边界时 `newMessageCount` 是 (边界, 最新] 的真实条数（不是 seq 跨度），`shownMessageCount` 是最后 3 条，`omittedMessageCount` 为差值；无边界（first-touch 或 thread parent）时 `newMessageCount = shownMessageCount = min(条数, 3)`，`omittedMessageCount:0`。
- held 消息信封带会话身份：`channel_id`/`channel_type`/`channel_name`，thread 另带 `parent_channel_id`/`parent_channel_type`/`parent_channel_name`；DM 的 `channel_name` 是 agent 视角的对端名；同时保留 `id`/`message_id`/`channelId`/`seq`/`content`/`sender_id`/`sender_name`/`sender_type`/`createdAt`/`timestamp`。
- 读状态：hold 展示了它统计的全部消息时才把 agent 读游标推进到 `seenUpToSeq`；有 omitted 时游标不动（省略的消息保持未读）；withheld 模式不动游标。
- `freshnessContextMode:"withheld"`（reviewer isolation）：响应恒为 `{state:"held",freshnessContextMode:"withheld",withheldMessageCount}` 三个键，不回显目标/正文/计数/可用动作，且不推进读游标。
- `continue:true` → 400 `--continue is no longer supported. Use normal message send to update a draft, or --send-draft to send the current saved draft.`；`continueAnyway:true` 但无 `sendDraft` → 400 `--send-draft --anyway requires a saved draft`；非 reconcile 且 `content` 为空 → 400 `Content is required`。`continueAnyway:true` 且 `sendDraft:true` 直接提交（sent），不返回 hold 字段。

### internalAgentApi.send：channel card 组

- 只有显式带 `seenCards` 的 v2 发送才检查被动 card。`seenCards.channel` 缺失 → 不检查、响应无 `channelCard`；`null`（本上下文从未见过）→ 仅因 card 返回 200 `{ok:true,state:"held",holdReasons:["channel_card"],heldMessages:[],newMessageCount:0,shownMessageCount:0,omittedMessageCount:0,channelCard}` 且不落库；`null` 以外的字符串（客户端上下文里的 card 版本）与当前版本相同 → 正常发送、响应无 card；版本不同（只见过旧版本）→ 正常发送，响应附 `channelCard` 与 `channelCardChanged:true`。
- card 版本是共享投影器的 `v1:<8hex><8hex>`：对 `[name, visibility, archived === true, 空白折叠后的 description]` 的 JSON 元组做两个独立 FNV-1a 32 位哈希（对 UTF-16 码元）；visibility 为 `joint`/`private`（private、dm）/`public`。`v1:` 前缀表示算法版本。
- card 对象投影：`{id,name,type,description,archived}`；thread 目标用父频道 card（`channelCard.id` 是父频道 id），DM 没有 channel card。
- card hold 与 freshness hold 合并：同一响应 `state:"held"`、`holdReasons:["unread_messages","channel_card"]`，附 `channelCard` 与未被省略的 held context；`continueAnyway:true`（配 `sendDraft`）不被 card 拦下，照常 sent 并带回 `channelCard`（`channelCardChanged` 不出现）。
- withheld（reviewer isolation）忽略 `seenCards`，响应仍只有三个键。

### internalAgentApi.auth：history 读窗口与锚点组

- `GET /internal/agent-api/history` 与 `/internal/agent/<id>/history` 共用实现。`consume` 只接受 `true`/`false`，其他值 → 400 `{errorCode:"INVALID_ARG"}`；`consume=false` 返回当页但不推进读游标、`model_seen_up_to_seq:null`。
- 响应字段：`last_read_seq` 是本次读取**之前**的读游标；`model_seen_up_to_seq` 是本次真正推进到的高水位，未推进时为 `null`；`has_more = has_older || has_newer`。
- 推进门槛：`after` 页只在锚点 ≤ 当前游标时推进；latest/before 页只在页面触达最旧一行、或页内最小 seq ≤ 当前游标时推进（否则更早的未读消息保持未读）。`around` 页从不推进读游标。
- 分页方向语义：`after` 页取锚点之后最早 N 条，`has_older:false`、`has_newer` 由多取一条探测；latest/before 页取锚点之前最近 N 条，`has_older` 由探测、`has_newer:false`。`limit` 默认 20，上限 100。
- `around` 窗口：`beforeCount=(limit-1)/2`，`afterCount=limit-beforeCount-1`，`has_older`/`has_newer` 由窗口两侧是否还有消息决定。
- 锚点解析：`before`/`after` 的纯数字一律是 seq（即使 8 位宽）；`around` 的 8 位十六进制按 short id 优先匹配（多匹配 → 400 `AMBIGUOUS_ID` 且 `suggestedNextAction` 要求用完整 UUID），纯数字是 seq，完整 UUID 精确匹配；形状非法（`around`）→ 400 `INVALID_ARG`，形状合法但不存在 → 404 `NOT_FOUND`，错误文本包含锚点。
- history 消息行：`createdAt` 是消息自身创建时间（ISO8601 毫秒 + `Z`），不出现 `timestamp`；human 发送者带时区时行上带 `senderTimezone`（如 `Asia/Shanghai`），无时区或 agent 发送者为 `null`。human 频道页不投影他人 `senderTimezone`。
- 明确排除：history 目前读 ledger 消息表，而 inbox/events 读另一份消息行，两套 seq 空间尚未统一（DomainStore 收口前无法覆盖「history 浏览推进 unread 但不构成 send freshness 证据」「51 条隐藏间隙」这类跨存储断言）；未移植 `unread=true` 模式、延迟推进（settle）、joint 投影与 forwarded 快照。

### 消息存储收口（DomainStore 第一步）

- 消息行只有一份权威顺序：`humanMessageRows` 在 append 时给每条消息盖一个 server-wide `seq`（跨频道单调递增），所有 channel/thread/DM 读取都用这个 `seq`，不再用「频道内下标 + 1」。human 读游标、agent 读游标、thread summary、inbox、events、history、send freshness 因而共享同一 seq 空间。
- 每次 append 同时镜像一条 ledger 记录（同 id、同 seq、同 createdAt、senderTimezone、senderType、messageType），使 ledger 侧读取（agent history、thread anchor 解析、`/api/messages/channel` 之外的历史接口、mention/staff 查询）能看到真实 HTTP 流量；ledger 自身 `createMessageRecord`/`createChannelMessage` 仍可用于构造测试数据。
- 结果：`POST /api/messages` 的 human 消息、`/internal/agent-api/send` 的 agent 消息、系统消息都同时出现在 agent history 与 human 频道页；`history` 浏览推进读游标但不构成 send freshness 证据；thread 目标可以用 HTTP 发送的父消息 short id 解析。
- `GET /api/servers/unread-summary` 的 `unreadCount`/`activityUnreadCount` 只按 ledger 未读数统计（镜像后与消息行一致），不再把两份存储相加。
- 明确排除：ledger 测试构造的行仍按调用方给的 seq 追加，若与真实流量混在同一频道，排序以各自 seq 为准；Postgres 输出仍未接管（B 阶段后续把该收口迁到 `DomainStore`）。

### internalAgentApi.send / history：exact-seq 证据与 resolve 时区

- `seenExactSeqs`（v2 send）：最多 2500 个去重后的正整数，只保留「大于 attest 边界且不大于会话最新 seq」的值；这些消息视为已被模型精确看过，从 hold 计数、held context 与 mention 计数里排除。没有 `seenUpToSeq` 但有空生效 exact seq 时，边界来源是 `client_seen_exact`（等同 model-seen 证据，`reason` 为 stale boundary；producerFactId 的 `modelSeenSeq` 仍为 0）。
- 生成的边界判定优先级：`seenUpToSeq` → `client_seen`；否则有效 `seenExactSeqs` → `client_seen_exact`；否则 thread 父消息 → `thread_parent`；否则 `none`。requested freshness 也包含非空 `seenExactSeqs`。
- `GET /internal/agent-api/history` 的 `limit` 默认 50（上限 100）。latest 窗口只取最近 50 条时，更早的未读消息保持未读（`has_older:true`、`last_read_seq` 不变、`model_seen_up_to_seq:null`），随后用这 50 条的 exact seq 发送仍会 hold 住被隐藏的那条并只回显它。
- `GET /internal/agent-api/messages/:id/resolve` 的 `message.sender_timezone` 投影 human 发送者的 IANA 时区（无时区为 null）；human 频道页仍不投影他人时区。

### internal.channelMembership.api：agent 自助 join/leave/unfollow 组

- `POST /internal/agent/:agentId/channels/:channelId/join|leave`（machine key + path agent id）与 v2 `/internal/agent-api/channels/:channelId/join|leave` 共用实现。
- join：已加入 → 200 `{"ok":true}`；可见公开频道 → 200 并写一行 system 消息 `@<agent> joined this channel.`（senderId/senderType 为 system），该行对加入者本人 born-read（其 agent 读游标直接推进到该 seq，事件拉取不会把它当未读），其他频道成员仍可见；private → 403 `Private channels require an invitation`，joint → 403 `Joint channels require an invitation`，archived → 409 `channel_archived`；无 Server 角色 → 403 `Server role cannot join public channels`。
- leave：离开自己的常规频道不需要 admin（200 `{"ok":true}`）；虚拟 `#all` 不可离开 → 403，错误文本含 `#all channel`；archived → 409；private/joint 频道在最后一个 human 和 agent 都离开后软删除（从 server info/历史可见性消失）。
- `POST /internal/agent/:agentId/threads/unfollow`（machine key）与 v2 `/internal/agent-api/threads/unfollow` 共用实现，接受 `"#channel:<parentShortId>"` 或完整 thread channel id：只能取消关注 thread，顶层频道目标 → 400 `Target must be a thread`；成功取消后 thread 列表不再包含该 thread，且不会改变父频道成员关系。不可见的 private 父频道下的 thread 仍按 cloak 返回 404 `Thread not found`。
- 明确排除：socket `channel:members-updated` 广播、orchestrator inbox purge/delivery ack、causal actor DB 列、`channel:join` 的 capability 拒绝矩阵中的 spy 断言。

### internal.channelMembership.api：agent 频道/服务器管理组

- `GET /internal/agent/:agentId/server`（machine key）与 `GET /internal/agent-api/server` 共用实现：`runtimeContext` 带 `agentId/runtime/model/reasoningEffort/serverId` 以及当前 machine 的 `machineId/machineName/machineDescription`（未建模字段 hostname/os/daemonVersion/workspacePath 为 null）；`channels[]` 带 `type`（channel/private/joint）与 `joined`，按「公开频道全部可见 + private/joint 仅成员可见 + 排除 archived/deleted/thread/dm」过滤；`agents[]` 带 role/status/activity/activityDetail。
- `POST /internal/agent/:agentId/channels` 与 v2 共用：member 角色即可创建；`name` 去掉前导 `#` 并校验 `[a-z0-9][a-z0-9-]{0,79}`；支持 `description`、`visibility`（public/private）；创建者 agent 自动加入；响应 `{id,name,type,description,joined:true,createdByAgentId}`。无 Server 角色 → 403 精确 payload（`server_role_required`、`requiredCapabilities:["createChannels"]`、`requiredRole:"member"`、`currentRole:null` 与指引文案）。
- `PATCH /internal/agent/:agentId/channels/:channelId` 与 v2 共用：仅 owner/admin；可改 name/description/visibility，响应 `{id,name,description,type}`，并同步 postable 投影与 server info。
- `POST|DELETE /internal/agent/:agentId/channels/:channelId/members` 与 v2 共用：按 handle（可带 `@`）加/移 human 或按名字加/移 agent；加入 human 时写 system 消息 `@<name> was added to this channel.`，该行对执行 agent born-read、对被加入 human 保持未读；移除响应带 `wasMember` 与 attention 说明。
- `PATCH /internal/agent/:agentId/server` 与 v2 共用：仅 owner/admin 可改服务器名，响应 `{ok,id,name}`。
- 明确排除：trace span/event 断言、socket `channel:updated`/`channel:members-updated` 广播、inbox notification fact 的 unreadEligible DB 行、orchestrator 回滚/重试。

### internalAgentApi.auth：agent reaction 组

- `POST|DELETE /internal/agent-api/messages/:messageId/reactions`（legacy machine-key 路由同实现）：消息 id 必须是完整 UUID 或 8 位十六进制 short id，否则 400 `Message id must be a full UUID or 8-character short id`。
- short id 只在调用 agent **可见**的消息里解析：private 非成员消息、以及不可见频道的消息不参与匹配（存在性 cloak → 404 `Message not found`）；多个可见匹配 → 400 `Message short id is ambiguous`（`errorCode:"AMBIGUOUS_ID"`）。
- 可见性：公开频道消息对所有本 Server agent 可见；private/joint 需频道成员；thread 消息在 agent 是父频道成员时可见（不必加入 thread）。
- 响应 `{reactions:[{emoji,count,reactorIds,reactorNames}]}`；重复添加同一 emoji 幂等（count 仍为 1），删除后该 emoji 桶消失；reaction 携带 `reactorType:"agent"` 语义。
- 明确排除：joint 频道 over-limit grace 的 403（需要 joint 计数 schema 与免费服务器额度模型）、reaction actors 游标分页（不在本组断言内）。

### internalAgentApi.send：wake-hints 与 events 消费组

- `GET /internal/agent-api/wake-hints`：内容无关的待处理消息预览。每条 hint 为 `{event_id:"wake-hint:<messageId>",seq,message_id,target,wake_reason:"message_pending"}`（thread 目标为 `#parent:shortId`，DM 为 `dm:@peer`），永不包含正文；`since` 接受非负整数（只返回 seq 更大的）或 `latest`（不额外过滤，仍按读游标取 pending），非法值 → 400 `{"code":"since_invalid"}`；`limit` 限制整批条数并返回 `last_hint_seq` 与 `has_more`。
- wake-hints 是纯 peek：重复调用结果不变、不推进读游标；随后 `GET /internal/agent-api/events` 返回同一批消息的正文与 `seq`，并把对应读游标推进到已交付的最后一条；下一 次 events 返回空、`has_more:false`。
- events 只投影当前仍可见的会话：agent 被移出 private 频道后，此前排队但未交付的 private 消息不再出现（drop 而非延迟投递）。
- 明确排除：orchestrator inbox 桩（`receiveMessages`/`peekPendingMessages`/ack 计数）、task 文本在 drain 时刷新、third-party event hint 的完整语义、mute/mention pierce、follow/父频道访问门槛、external delivery 自动唤醒。

### internalAgentApi.auth：mentions feed 组

- `GET /internal/agent-api/mentions`（credential 需 `mentions` scope，否则 401 `auth_required`）：只返回该 agent 作为目标的 mention 行，且只包含 `notifiableAtSend == true` 或已有 `notifiedAt` 的行——发送时不可通知且从未通知的 outsider/pending 行不会出现在目标侧 feed。
- 行投影为 `{messageId}`，按创建顺序倒序（最新在前）；`limit` 用「多取一条」判定 `has_more`：恰好等于 limit 行时 `has_more:false`，超过时 true。

### internalAgentApi.auth：search 契约组

- `GET /internal/agent-api/search`：`q` 分词匹配（全部命中优先，不足时按部分命中排序），`sort=recent` 按消息 `createdAt` 倒序、否则按相关度再按时间；`limit` 默认 20、上限 100，`hasMore` 由多取一条判定。
- 每行投影：`{id,content,senderName,senderType,senderId,channelId,channelName,parentChannelId,snippet}`；`senderName` 对 human 用 displayName（无则 name），对 agent 用 displayName/name；thread 行的 `channelId` 是 thread、`parentChannelId` 是父频道。
- 可见性与 history 一致：公开频道、agent 所属 private/joint、以及父频道可由该 agent 读取的 thread 回复；不可见 private 的行（含正文）不出现。
- `sender` 先做成员目录解析：解析不到与「存在但被隐藏」返回同一 404 `{errorCode:"member_not_found"}`，因此 member 角色 agent 在隐藏 human 目录开启时无法枚举 human handle；`sender` 命中后按 senderId 过滤。
- 明确排除：trace span/`server.db.query` 断言、sender 别名/多重身份等其它查询参数矩阵。

### internalAgentApi.auth：message resolve / channel-members / thread list 组

- `GET /internal/agent-api/messages/:id/resolve` 与 resolver 一致：接受完整 UUID 或 8 位 short id，只在调用 agent 可见的消息里解析（不可见 private 的碰撞 → 404 `{errorCode:"NOT_FOUND", error:"Message not found: <ref>"}`，可见唯一匹配才 200）；返回 `{message:{message_id,channel_id,channel_name,channel_type,sender_type,sender_name,content,created_at,sender_timezone}}`；DM 的 `channel_type:"dm"` 且 `channel_name` 是 agent 视角对端名；credential 需 `read`，否则 403 `capability_not_authorized`。
- DM 成员身份包括 postable `memberIds`（此前只认 channelAgent/channel-agent 记录），因此 agent 可 resolve 自己 DM 里的消息。
- `GET /internal/agent-api/channel-members?channel=...`（legacy `/internal/agent/:id/channel-members` 同实现）：返回 `{channel:{ref,type},humans:[{id,name,role}],agents:[{id,name,status:"active"}]}`；thread 引用解析到父频道 roster，type 为 thread；支持 credential 与 machine key（含 `registerMachineForAgent` 的 legacy key）。
- `GET /internal/agent-api/threads`：只返回该 agent 未取消关注、且其可见的 followed thread；每行 `{target,threadChannelId,parentChannelRef,parentMessageId,parentMessageShortId,followedAt,reason,doneAt}`，按 followedAt 倒序；别的 agent 的 follow 与不可见 private 父频道下的 follow 不出现。

### agentRuntimeProviders.api：hosted provider 可用性门

- `GET /api/agent-runtime-providers/antiproton`：仅本 Server owner/admin（member → 403）；未知 kind → 404；响应恒为 `{kind:"antiproton",available}`，不暴露部署 token 或 provider base URL。旧的 PUT/DELETE 配置路由保持 404。
- 可用性 = 部署级配置（`ANTIPROTON_PROVISIONING_TOKEN` 非空）+ 本 Server 的 hosted runtime flag 同时成立；跨 Server 隔离（B 未开 flag 时即使 token 存在也不可用）。
- `POST /api/agents` 带 `provider:"antiproton"`：仅 `external:true`（否则 400 `provider is only for external agents`）；flag 未开 → 403 `{"code":"agent_runtime_provider_disabled"}`；flag 已开但部署未配置 → 409 `{"code":"agent_runtime_provider_not_configured"}`；通过后创建 agent 并返回 `hostedRuntime:{kind:"antiproton",state:"provisioning"}`（本移植版不发 provider HTTP 请求）。
- 明确排除：fake provider 的 provisioning/edit/delete/import/connector/spend/cindy 等需要真实 provider transport 的组，以及 rollout 降级/杀开关的 worker 行为。

### channels.api：message-display-settings 组

- `GET/PATCH /api/channels/:id/message-display-settings`：GET 默认 `{collapseLongMessages:true,prefsVersion:0}`；PATCH 只接受布尔 `collapseLongMessages`（非布尔 → 400 `collapseLongMessages must be a boolean`），响应 `{collapseLongMessages,prefsVersion}`。
- 每用户偏好：同值 PATCH 不 bump `prefsVersion`；改值 bump 一次；不同用户互不影响。
- 访问门：本 Server 成员 + 该频道成员（未加入公开频道、非成员 private 一律 404 cloak）；系统 `#all` 对 Server 人类隐式成员可用；thread 目标 → 400 `Display preferences are stored on the parent channel`（在 membership 判断之前）。
- 投影：`GET /api/channels` 行与 `GET /api/channels/:id` 详情都带 `collapseLongMessages` 与 `displayPrefsVersion`（当前用户视角）。
- 明确排除：`message_display_prefs:updated` socket 广播与 trace 断言、功能开关 `topbar_overflow_v0` 的退役配置行为。

### channels.api：unread 计数与可见性守卫组

- `GET /api/channels/unread`：只统计「他人消息」，自己的频道/DM 消息永不计入；无未读的频道不出现在 map 里（不是 0）。
- `POST /api/channels/:id/unread`：把读游标回退到「最新一条他人消息 seq - 1」，即使最新消息是自己发的也持久化，响应 `{channelId,unreadCount,maxReadSeq}`；随后 `/api/channels/unread` 回 1。
- `PATCH /api/channels/:id` 的 `visibility`：`#all` 对 human 与 agent 都拒绝，403 `{"code":"all_channel_visibility_managed_separately"}`，错误文本指引「Only a human can do it, from channel settings or server settings」；agent 频道更新同样受此守卫。`#all` 的隐藏/恢复只走 human 的 `/api/channels/system/all/hide|restore`，且可逆。
- 普通频道改 visibility 需要「owner/admin 能力 + 当前是该频道成员」：非成员（human 或 agent）→ 403 `{"code":"channel_membership_required"}`；普通 member 即使已加入也因缺 changeChannelVisibility 被 403；server owner 加入后可 private↔public 往返。
- DM 创建（human 与 agent 对端）现在注册 postable 会话与双方成员身份，人类 DM 可直接收发消息。

### channels.api：read-all 委派组

- `POST /api/channels/:id/read-all` 支持 kinded receiver：`{"receiver":{"kind":"agent","id":...}}` 把该频道的 agent 读游标推进到频道最新 seq，返回 `{ok:true,seq,readStateVersion}`（首次推进 version 1）；授权 = 调用者 owner/admin 或该 agent 的 creator，且 agent 必须是该频道成员；human 调用者的读状态完全不改。
- 委派在「调用者是否频道成员」兜底之前判定：owner 即使不在 private 频道也能委派；非授权 member → 403 且零写入；`kind:"human"` 的 receiver（或任何非 agent 值）→ 403，不会回退到调用者或目标 human。
- 不带 receiver 的 `read-all` 仍推进调用者自己的作用域（详情 `maxReadSeq` 到最新 seq）。
- 明确排除：socket `scope_read:updated`/user-room 事件与 trace 断言、agent 读状态的持久 DB 行断言。

### 读游标收口（DomainStore 第二步）

- human 读游标只有一份：ledger 的 per-user 频道读前沿（`channelReadCursors`）。目录层不再维护并行游标表。
- 发送自己的消息即视为读到它：发送方游标推进到该消息 seq（不会把自己消息算成未读）；`humanReadCursor` 查询、`/api/channels/:id` 的 `maxReadSeq`、`/api/channels/unread` 与 `/read` 路由读写的是同一份游标，因此互相一致。
- 验收：自己的消息发送后 cursor == `maxReadSeq`；他人消息产生未读 1；`/read` 推进后 unread map 中消失。
- 明确排除：迁移到 Postgres 的游标持久化（DomainStore 后续阶段）、按 `readStateVersion` 的乐观并发在 DB 层的语义。

### internalAgentApi.send：agent 频道 mute / 定向投递组

- agent-receiver mute 按 `channelId + agentId` 存储：`POST /internal/agent-api/channels/:id/mute|unmute`（credential 需频道成员，非成员 403）。mute 响应 `{activityMuted:true,muteFromSeq:<订阅时最新消息 seq + 1>,attention:{state:"muted",unmuteCommand:"raft channel unmute #name",unmuteApi:"POST /internal/agent-api/channels/<id>/unmute",stillArrives:[...@mentions...],threadBoundary:"Channel mute suppresses ordinary Activity from this channel only. Threads you follow keep delivering independently until you unfollow them.",catchUp:"...history..."}}`；unmute 响应 `{activityMuted:false,muteFromSeq:null,attention:{state:"unmuted",muteCommand:"raft channel mute #name"}}`。
- `GET /internal/agent-api/server` 的频道行投影该 agent 自己的 mute：`activityMuted` 与 `muteFromSeq`（未 mute 为 false/null；human 的 mute 状态不影响 agent self-read）。
- 投递：`/internal/agent-api/events` 与 `/wake-hints` 跳过 mute 边界之后的普通消息，但命中 @该 agent 的消息穿透；mute 之前的历史 backlog 仍投递。unmute 只恢复后续投递，被抑制的旧消息通过 history 补看（不重放）。
- freshness SMR-006：muted 普通消息不触发 hold（state 仍 `sent`），@mention 穿透消息进入 held 上下文（`newMessageCount`/`heldMessages` 只计穿透消息，muted 普通行不出现）。
- 明确排除：human receiver mute 与 agent mute 的统一存储（human 侧仍走 per-user notification prefs）、attention_hint_accepted trace 计数、线程 mute 继承父频道（mute 只作用于该频道本身，followed thread 独立投递）。

### auth.api：账号与会话核心组

- `POST /api/auth/register`：reserved handle（如 `Reminders`）→ 400 error 含 "reserved" 且不建账号；缺 `acceptTerms` → 422 `{"error":"LEGAL_ACCEPTANCE_REQUIRED","legal":{termsVersion,privacyVersion,termsUrl,privacyUrl}}` 且不建账号；`termsVersion`/`privacyVersion` 与当前版本不符 → 409 `{"error":"TERMS_CHANGED","legal":...}` 且不建账号；通过后建账号并记录 append-only legal acceptance（当前版本、source `signup`）。
- `POST /api/auth/login`：错误凭据 → 401 精确 `{"code":"AUTH_INVALID_CREDENTIALS","error":"Invalid email or password"}`；`email`/`password` 不是字符串（嵌套对象）→ 400 `{"code":"email_login_body_invalid","issues":[{"path":"email"|"password",...}]}`，在创建会话之前失败。
- `PATCH /api/auth/me`：当前密码错误 → 401 精确 `{"code":"AUTH_CURRENT_PASSWORD_INCORRECT","error":"Current password is incorrect"}`。
- `displayLanguage`：支持 tag 归一化持久化（`zh-Hans`→`zh-cn`、`en-US`→`en`）；未发布的 UI locale（`fr-FR`、`zh-TW`）→ 400 且保留旧值；显式 `null` 清空偏好。
- `shareUsageData`：初始 null；`true/false/null` 往返并回读一致；非布尔 → 400。
- `GET /api/auth/me` 的 `gravatarHash` 是 email 去空白小写后的 SHA-256 hex。

### agents.api：身份与发现组

- `GET /api/agents/:id` 非 UUID → 404 精确 `{"error":"Agent not found"}`（无 code）。
- `POST /api/agents`：reserved mention-like handle（all/human/agent/here/idle/busy/system/reminders，大小写不敏感）→ 400 error 含 `is reserved. Choose another name.`；同 Server 活跃 agent 重名 → 409 error 含 "already taken"。
- creator 创建时绑定：`creator:{type:"human",id}`；`PATCH /api/agents/:id/creator` 不存在 → 404，creator 不变。
- `GET /api/agents/:id/runtime-options` 由 member 的 viewAgents 能力满足（不要求 owner/admin），返回 200。
- `GET /api/agents/:id/agent-dms`：只列 agent-to-agent DM（人类 DM 不出现），行 `{id,peerId,peerName,lastMessagePreview}`；preview 跳过尾部 system 消息。
- `GET /api/agents/:id/channels`：只列该 agent 的显式频道成员（不含虚拟 #all、thread、DM）；private/joint 需要 viewer 也在该频道；行含 `{id,name,description,type,createdAt,archivedAt,activityMuted,muteFromSeq}`，mute 是 agent receiver 自身状态（viewer 的 mute 不泄漏）。
- agent mute 状态与 human 共用 receiver-keyed notification prefs 存储（`channelId + receiverId`），mute 路由写入带订阅边界 `muteFromSeq`。

### agents.api：agent server role 变更组

- `PATCH /api/agents/:id` 支持 `serverRole`（`member`/`admin`）：目标 `owner` → 400（agent 永不可为 owner）；普通 member 调用 → 403；owner 可 promote/demote；admin 只能 promote 自己创建的 agent，不能 demote admin（403 → 需 owner）。
- 合法变更立即生效并回显 `serverRole`（PATCH 响应与 `GET /api/agents/:id` 的 `serverRole` 均为真实角色，不再硬编码 member）。
- 每次真实角色变更向「操作者与 agent 的 DM」写入系统消息：`@<actor> changed @<agent>'s server role from <old> to <new>.`，subtype `agent.server_role_changed`；非法/被拒/空操作（同角色）不写消息。DM 不存在时自动创建并挂接双方。
- 明确排除：`resetAgent`/orchestrator 调用参数（session reset 模式、codex model switch 强制 session 等）与 DB sessionId 行断言——它们是 spy/DB 断言而非 HTTP/JSON 契约。

### agents.api：external agent 运行时守卫组

- external agent 的 profile 字段（description 等）仍可 PATCH；但 Raft 管理的 runtime 字段（`runtime`/`runtimeConfig`/`model`/`reasoningEffort`/`envVars`）→ 400 精确 `{"error":"External agent runtime fields are immutable"}`。
- external agent 的 `POST /api/agents/:id/start|stop|reset` → 400 精确 `{"error":"External agents do not use Raft-managed runtime lifecycle"}`，不触发 orchestrator 生命周期。
- `POST /api/agents/:id/assign-machine` → 400 精确 `{"error":"External agents cannot be assigned to a Computer"}`。
- `DELETE /api/agents/:id` → 200 软删除；随后 `GET` 404，`GET /api/agents/archived` 的 `agents[{agentId,...}]` 包含该 agent。
- 明确排除：orchestrator start/stop/reset 调用标志与 `evictCache` 断言、DB `deletedAt` 行断言（以 HTTP 可观察行为替代）。

### internal.search.api：legacy 机器钥搜索组

- `GET /internal/agent/:id/search`（machine key + path agent id）在可见消息中做 token 搜索；`sender` 支持 `@handle`/handle 引用：按 Server 成员 human（name/displayName）与活跃 agent name 解析，不可见或不存在 → 404 `{"error":"Member not found","errorCode":"member_not_found"}`，同一 handle 同时命中 human 与 agent → 409 `{"error":"Member handle is ambiguous","errorCode":"ambiguous_member_ref"}`。
- 结果行保留 `id/senderId/senderType/channelId/parentChannelId/content/snippet/channelArchivedAt`，并新增 `senderName`、`channelType`、`channelName`、`threadId`、`parentMessageId`、`parentMessageContent`：thread 回复的 `channelId`/`threadId` 是 thread、`channelType:"thread"`、`parentMessageId`/`parentMessageContent` 指向父消息。
- `after`/`before` 时间过滤必须是带时区偏移的 ISO-8601（`Z` 或 `+08:00`）；缺失偏移 → 400 `{"errorCode":"INVALID_DATE_FILTER"}`，错误文本包含 "missing a timezone offset"、"+08:00"、"raft CLI"；带偏移按绝对时刻比较（after 严格大于、before 严格小于）。
- `sort=recent` 按 createdAt 倒序；`sender` 过滤在 hidden human directory 下对 member agent 隐藏 human handle。
- 明确排除：trace span/`messages.search` query 断言、task 最新投影字段、CLI e2e。

### computerAttach.api：Computer attach 组

- `POST /api/computer/attach` 默认挂载；环境 `SLOCK_DEVICE_LOGIN_ENABLED=false`（或测试 seam 关闭）→ 404（等同未挂载）。未认证 → 401。
- body 必须 `serverSlug`（`serverId` 不再接受）→ 缺失 400 `{"code":"server_slug_required"}`；slug 解析不到、或调用者非 Server 成员 → 统一 403 `{"code":"not_authorized"}`（零枚举）；已加入的普通 member → 403 `{"code":"requires_admin"}`；owner/admin → 201。
- 201 响应 `{apiKey:"sk_computer_*", serverMachineId, machineId, serverId, serverSlug, name, resumed:false}`；同 (server,user,name) 再次 attach → 409 `{"code":"COMPUTER_NAME_COLLISION"}` 且不轮换已有凭据；不同 name 生成新的 Computer。
- `POST /internal/computer/preflight`（`sk_computer_*` Bearer）→ 200 `{ok:true,serverId,serverSlug,principal:{kind:"computer",id,name}}`；未知/已撤销凭据 → 401。
- UUID 形状的 `serverSlug` 只按 slug 解析，绝不当作 serverId 别名（→ 403）。
- 明确排除：mobile-download email journey 行断言、`computers.machineId` DB 行断言、既有 machines 表联动细节（以 HTTP 行为验收）。

### computerLegacyMachines.api：daemon adoption roster 组

- `GET /api/computer/legacy-machines?serverSlug=`：默认挂载；gate 关闭 → 404；未认证 → 401 `auth_required`；缺 `serverSlug` → 400 `server_slug_required`；未知/已删除/非成员 Server 全部返回**同一** 403 `not_authorized`（cloak 对称，不可枚举）。
- 200 响应 `{serverId,serverSlug,entries:[...]}`，entries 仅限调用者在该 Server 的 machines；行含 `daemonId`、`machineName`、`hostname`、`lastSeenAt`、`hasFingerprint`、`legacyKeyMigratedAt`；默认只含已有 fingerprint 的行并带 `apiKeyFingerprint`（`sha256:<hex>`），NULL fingerprint 行默认排除。
- `includeAll=1`：包含 NULL fingerprint 行，但整批省略 `apiKeyFingerprint` 键（不泄露任何指纹字节）；已 adopted 行（legacyKeyMigratedAt 非空）照常包含以支持中断恢复。
- SECRET REDLINE：响应永不含 `apiKeyHash`/`apiKeyPrefix`/原始 apiKey 或 machine key。

### computerAttach.api：attach ↔ adoption roster 联动

- 一次成功的 `/api/computer/attach` 会注册 machine 并进入 `GET /api/computer/legacy-machines?serverSlug=...&includeAll=1` 的 entries：`daemonId` 等于 attach 返回的 `serverMachineId`，`machineName` 为请求 name，`hasFingerprint:false`（daemon 握手前无指纹）；默认（不带 includeAll）该行因无指纹而不出现。

### computerRevocation.api：machine 删除即撤销 Computer 凭据

- `DELETE /api/servers/:id/machines/:machineId`（owner/admin 或 machine 所有者；活跃 migration → 409）在删除 machine 前先写撤销回执：关联 computers 的 `revokedAt` 置为当前时间且 `machineId` 清空。
- 被撤销的 `sk_computer_*` 之后的 `/internal/computer/runners` → 401，不能为新 agent mint 凭据；`computerRecordForTesting` 可见 `revokedAt != nil`、`machineId == nil`。

### computerAttach.api：默认 roster 排除未握手 Computer

- 刚 attach 的 Computer（`hasFingerprint:false`）在默认 `GET /api/computer/legacy-machines?serverSlug=` 中不出现；只有 `includeAll=1` 才展示该行。这样 default roster 始终只给 daemon 可迁移的、已有指纹的历史 machine。

### computerRevocation.api：machine 删除的鉴权前置

- `DELETE /api/servers/:id/machines/:machineId` 未认证 → 401；未知/machine 不属于该 Server → 404；两者都在任何撤销动作之前失败（computer 凭据的 `revokedAt` 保持 null）。

### computerRevocation.api：runner 表面的未认证拒绝

- `GET /internal/computer/runners` 未带 Bearer → 401（与已撤销/未链接电脑凭据同一拒绝面），不泄露任何 runner 信息。

### computerLegacyMachines.api：includeAll 的显式默认值

- `includeAll=0` 与缺省等价：仍只返回已有 fingerprint 的行（并带 `apiKeyFingerprint`）；只有 `includeAll=1` 才切换到省略指纹键的完整名册。

### computerAdopt.api：legacy daemon 采用组

- `POST /api/computer/adopt-legacy` 与 attach/roster 共用同一 gate：关闭 → 404；未认证 → 401 `auth_required`；缺 serverSlug 以外的身份字段时按下方规则拒绝。
- 三种身份择一：原始 `legacyApiKey`、roster 身份（`serverSlug` + `legacyMachineId` + `apiKeyFingerprint`）、daemon 身份（`serverSlug` + `daemonId`）；三者都没有 → 400 `legacy_api_key_required`；`name` 若存在必须是非空且 ≤200 字符的字符串，否则 400 `name_invalid`。
- 原始 key 采用：只接受 `sk_machine_*` / `sk_daemon_*` 前缀（旧 daemon 两种前缀都在野外存在），未知 key 或非 machine 前缀 → 401 `legacy_key_invalid`；调用者非该 machine Server 成员 → 403 `not_authorized`；不是行创建者的普通 member → 403 `requires_admin`（持有 key 本身不等于 manageMachines 权限）；成功 → 201 `{apiKey:"sk_computer_*", computerId, machineId, serverId, resumed:false}`，machine 行的 `legacyKeyMigratedAt` 置位；同一原始 key 重放 → 409 `legacy_machine_key_migrated`。
- roster 身份采用：fingerprint 必须是 16 位十六进制，否则 401 `legacy_key_invalid`；身份是 user-scoped（行的 userId 必须等于调用者，选中他人行返回同一 401，不可探测 roster）；Server 缺失或非成员 → 403 `not_authorized`；已 adopted 且存在活跃 Computer → 201 `resumed:true` 并轮换 `sk_computer_*`（旧 Computer 凭据立即失效），已 adopted 但无 Computer → 409 `legacy_machine_key_migrated`。
- daemon 身份采用：owner/admin（`registerMachines`）可采用他人在该 Server 的行；行不存在时 owner/admin 得到 404 `legacy_machine_not_found`，非管理者得到 403 `requires_admin`（不泄露行身份）；行创建者即使只是普通 member 也可采用自己的行；采用后同样支持 resume + 凭据轮换。
- 并发同一原始 key：恰好一个 201、另一个 409 —— mark 与建/轮换在同一临界区原子完成。
- 采用成功立即失效 legacy key：`/daemon/connect` 握手对已 adopted 的 `sk_machine_*` 回 401 + `Slock-Reason: legacy_machine_key_migrated`，无 TTL 窗口；上游该断言打在 `/internal/machine/*`，该机器 HTTP 表面尚未移植，故在 connect 握手上锁定同一拒绝语义。
- 明确排除：`legacy_key_migrated_at` / computers 行 DB 断言、`fenceMachinePrincipalConnections` 进程内 spy、Express 未挂载时的 HTML 404 body（以 404 状态 + 统一 JSON `not_found` 约定验收）。

### computerLegacyMachines.api：fingerprint 线格式纠正

- `apiKeyFingerprint` 的线上格式是 `sha256(apiKey)` 十六进制的前 16 个字符（与 daemon 本地 `owner.json` 的交集键一致），不是 `sha256:<64hex>`；roster 默认响应与 adopt-legacy 的 roster 身份使用同一值。

### internalComputer.preflight：route-auth registry 自述组

- `POST /internal/computer/preflight`（`sk_computer_*` Bearer）→ 200，body 含 `ok:true`、非空 `surfaceVersion`、`claimedPrefixes`、排序去重的 `registeredPrincipals`、`computerSurface`（每项 `{method,path,principal}`），以及既有的 `serverId`、`serverSlug`、`principal`。
- `computerSurface` 由 **live router** 派生：遍历已注册路由，按声明前缀映射 principal（`/internal/computer/` → `sk_computer`，`/internal/agent/`、`/internal/agent-api/` → `sk_agent`），不是并行的常量表；通配 catch-all 不进入清单；清单按 path、method 稳定排序；preflight 自身出现在清单里（证明投影读的是真实路由表）。
- 只读：同一凭据两次调用的 body 完全一致，且不 mint 任何 agent credential。
- 错误 principal（例如 `sk_agent_*` Bearer）→ 401 `{"code":"invalid_principal"}`；无 Bearer → 401 `{"code":"auth_required"}`。
- 未注册的 `/internal/computer/*` 兄弟路径（GET/POST/PUT/PATCH/DELETE 任一）带有效 Computer 凭据 → 401 `{"code":"auth_policy_unregistered_path"}`，而不是路由 404；已注册路径不受 catch-all 影响。
- 明确排除：上游把 preflight 与 Express `routeAuthPolicy` 注册表逐项 `deepEqual` 的断言（等价验收改为：清单从 live router 派生、稳定、自述、principal 前缀一致）；DB 行/凭据计数断言改为 inventory 计数 seam。

### internalComputer.runners：Computer runner 控制面组

- `GET /internal/computer/runners`（`sk_computer_*`，且 Computer 已链接 machine）→ 200 `{whitelist:["agentId","name","status","model","runtime"], runners:[...]}`；每行 key 恰为白名单五项，白名单在 server 端投影里强制，agent 记录中的 session/envVars/runtimeConfig 绝不进入响应。
- 默认 scope 是本 Computer 的 machine（`agentMachineIds[agentId] == computer.machineId`）；`?scope=server` 返回该 Computer 所属 Server 的全部 runner（含其他 machine）；跨 Server 始终隔离。
- `model` 从 runtimeConfig 投影（结构化 `model.id` 或字符串），`status` 取 agent 记录状态（默认 `inactive`）。
- `POST /internal/computer/runners/:agentId/stop`：仅本 machine 绑定的 agent → 200 `{agentId}`；其他 machine 或跨 Server 的 agent → 404 `{"code":"agent_missing"}`（与其他 machine 的 mint/revoke 同一拒绝面，不泄露存在性）。
- `DELETE /internal/computer/runners/:agentId/credentials/:credentialId`：同样的 machine 绑定；凭据不属于该 agent → 404 `{"code":"credential_missing"}`；成功 → 200 `{agentId,credentialId,revoked:true}` 并写 `revokedAt`。
- 非 Computer principal（`sk_agent_*`）→ 401/403（registry 前置拒绝，handler 不运行）。
- 明确排除：provider materialization 组（provider connection 密钥材料化/加密、launch config reference-only 语义依赖尚未移植的 provider connection 传输面）。

### mobileDownload：公开移动下载入口组

- `GET /api/mobile-download` 不需要会话：无 Authorization 时仍由 handler 回答（空频道给 404 而不是 401）。
- `?platform=android|ios` 显式指定优先于 User-Agent；无 platform 时按 UA 判定：Android → android，iPhone/iPod/legacy iPad → ios；现代 iPadOS 的 macOS 同串 UA 视为不可分类。
- 不可分类（Mac、现代 iPad、无 UA）→ 302 到 web chooser 的**绝对** URL `${APP_URL}/download`（去尾斜杠），`Cache-Control: private, max-age=300`；不猜平台、不返回错误页。
- iOS → 302 到 TestFlight URL（绝不指向 Hands `.ipa`），`Cache-Control: private, max-age=300`，且不调用 Hands。
- Android → 解析 Hands `latest`：APK 优先于 store bundle（与 assets 顺序无关）；命中 → 302 到 `download_url`，`Cache-Control: private, max-age=min(expires_in,300)`（缺 `expires_in` 时为 0）。
- 空频道 → 404 `{"error":"No build available yet","code":"no_active_release"}`；只有 store bundle → 404 `{"error":"No installable build available yet","code":"no_installable_build"}` 且无 Location；配置错误（404 但 code 非 `no_active_release`、缺 code、缺该平台 asset）→ 502 `{"error":"Mobile download is unavailable","code":"not_configured"}`；传输失败或非 2xx → 502 `code:"upstream_error"`；错误分支都不重定向。
- 明确排除：上游对私有 helper 的单元断言（UA 分类、chooser URL 构造、`lookupLatestAsset` 直调）不作为移植对象——其行为已通过 HTTP 路由断言覆盖；viewport 宽度不参与判定一类纯单元断言没有 HTTP 观测面，按不可移植排除。

### productEvents.api：client 行为事件组

- `GET /api/product-events/config` → `{clientEventsAllowed}`，仅在用户显式 `shareUsageData=true` 时为 true；否则 `POST /api/product-events/batch` 仍返回 202 但 `{"accepted":0}` 且不落任何记录。
- `POST /api/product-events/batch`（`source:"web"`）：只接受注册事件 `activity_open`（白名单属性 `from`）与 `activity_mark`（`action`）；陌生属性整条跳过、未注册事件跳过、时间戳超过 7 天的跳过；同批重复 uuid 只存一次，最近已见 uuid 再提交被丢弃；`app_version` 必须是 `x.y.z`，`client_session_id` 必须是 uuid，否则 400。
- 落库只在 analytics id 下：记录 `to` 事件名、analytics id（首次生成后按用户稳定）、serverId、source、session、appVersion 与投影后的属性；属性里附加由请求派生的 `$browser`/`$browser_version`/`$os`/`$device_type`/`$country`（国家仅接受两位字母代码），原始 User-Agent 与 Raft 用户 id 绝不进入记录。
- onboarding-wizard 组：核心步骤事件按白名单 sanitize 后落库（`latency_ms` 取整、未知键丢弃），未跟踪的推送步骤 400 且不落库；显式 opt-out 或 workspace analytics 关闭时仍 204 但不落库。

### shareArtifacts.api：公开分享截图组

- `POST /api/share-artifacts/message-selection`（用户 Bearer + `X-Server-Id`）：未认证 401；非 Server 成员 403；guest 403 `Guests cannot create share artifacts`（在任何上传校验之前）。
- 上传校验：缺 image 或为空 → 400 `image is required`；超过 10MB → 413 `{error:"Max 10MB per image",errorCode:"SHARE_ARTIFACT_TOO_LARGE",maxBytes}`；非 PNG → 415 `Share artifact must be a PNG image`；缺 `channelId` → 400 `channelId is required`；channel 不在该 Server 或调用者无权访问 → 403 `You do not have access to this channel`。
- 成功 200 `{id, url, imageUrl}`：`url` = 规范化分享页基址（`SHARE_BASE_URL`，缺省 `<SERVER_URL>/share`）+ `/<id>`；`imageUrl` = 配置了 `CDN_BASE_URL` 时 `<cdn>/<serverId>/share-artifacts/<id>.png`，否则 `<serverBase>/share/<id>.png`；两者都去尾斜杠。
- `GET /share/:id`：200 HTML（`Cache-Control: public, max-age=300`、`X-Robots-Tag: noindex, nofollow`），含完整 OG/Twitter 元数据：`og:type=article`、标题/描述、`og:url`（规范分享地址）、`og:image`/`og:image:secure_url`/`og:image:type=image/png`、真实宽高（从 PNG IHDR 读取）、`twitter:card=summary_large_image`、`twitter:title/description/image/alt`；配置 CDN 后元数据只出现规范主机，不出现请求 Host。
- `GET /share/:id.png`：200 原始上传 PNG 字节（`Content-Type: image/png`、`Cache-Control: public, immutable, max-age=31536000`、`Content-Disposition: inline`、`X-Content-Type-Options: nosniff`、`Content-Length`）；即使配置了 CDN，本机路由仍可回退服务。
- 非法 uuid 或未知 id 的页面与图片都是 404 纯文本 `Not found`。
- 明确排除：上传中断时释放上游存储连接（真实对象存储 socket 生命周期）这一条，依赖未移植的对象存储传输层。

### internalAgentApi.registryParity：route-auth policy 失败关闭组

- 声明的 agent principal 前缀（`/internal/agent-api/`、`/internal/agent/`）对未注册路径失败关闭：带有效 agent 凭据 → 401 `{"error":"This internal surface is not registered","code":"auth_policy_unregistered_path"}`，而不是路由 404（避免"路由存在但缺 policy 条目"看起来像未挂载）。
- 同一路径上：machine 凭据 → 401 `invalid_principal`（不是该前缀声明的 principal）；无 Bearer → 401 `auth_required`。
- 已注册路由不受 catch-all 影响；`POST /internal/computer/preflight` 的 `computerSurface` 不因新增通配路由增减（通配不进入声明清单）。
- 明确排除：上游用 TypeScript 契约源码断言"每个 contract 声明路由都注册在 routeAuthPolicy"的源码级校验（不可移植）；其等价可观测面由本组锁定。

### errorResponse.dmTarget：DM 目标解析错误组

- agent send 的 `dm:@<name>` 目标在同名人类与同名 agent 并存时 → 409 `{"code":"DM_TARGET_AMBIGUOUS"}`；error 文本点名 `dm:@<name>~agent`，`suggestedNextAction` 同时给出 `dm:@<name>~agent` 与 `dm:@<name>~human` 两条改法。
- 未知 peer kind（如 `dm:@<name>~bot`）→ 400 `{"code":"DM_TARGET_INVALID_PEER_KIND"}`，`suggestedNextAction` 指示改用 `dm:@<name>~human` 或 `dm:@<name>~agent`。
- 显式 `~agent` / `~human` 目标仍正常解析并发送——上述错误只针对歧义与非法 kind，而不是"找不到"。
- 明确排除：上游 helper 级单元（直接调用 `respondToDmTargetResolutionError`）不作为移植对象；其等价可观测面已由 agent send 路径锁定。

### internalAgentApi.wakeHintStream：SSE 投影组

- `GET /internal/agent-api/wake-hints/stream` 是 peek 的 SSE 投影：先写 `: connected`，随后按 seq 升序回放当前 pending hints（`event: wake-hint`、`id: <seq>`、data 与 peek 行同构：`event_id`/`seq`/`message_id`/`target`/`wake_reason`），再按 tick（测试 50ms / 生产 1s）拉取新 hint；空闲 tick 写 `: heartbeat`。
- 帧里永远没有消息正文（content-free），读取流不推进任何读游标（peek 结果保持不变）——不是 drain。
- `Last-Event-ID`（或 `?since=`）：数字只回放 `seq >` 该值的 hint；`latest` 表示从当前最新开始；非法值在开流前 400 `since_invalid`。
- 错误在开流前以 JSON 返回：无 Bearer 401 `auth_required`、machine 凭据 401（非 agent principal）、凭据/agent 被撤销时流关闭。
- 心跳 tick 自行发现"durable pending 但没有实时唤醒信号"的 hint（本移植没有进程内 emitter，tick 轮询即该兜底路径）。
- 明确排除：外部 agent durable pull 编排的 follow-up pull（outrunning inbox chain 场景）与 trace/span 断言。

### internalComputer.agentMigrationControl.bodyLimit.api：route-scoped JSON body 限制组

- 全局 JSON body 上限 100 KB：`Content-Length` 超过它的 `application/json` 请求在解析前得到 413 JSON `{"code":"request_body_too_large"}`；上传等非 JSON body 不受此限。
- `POST /internal/computer/agent-migrations/by-id/:migrationId/resumable/control` 是唯一提升面：允许 512 KB manifest + 64 KB envelope（共 589,824 bytes），路由级 `maxBodySize` 同步提升，180 KB 与 589,824 bytes 的 body 都能到达 handler（未知 migration 由其自身错误回答，而不是 413）。
- 超过 589,824 bytes → 413 JSON `{"code":"migration_control_body_too_large","limitBytes":589824}`，与 manfiest 自身预算错误（`migration_control_manifest_too_large`）区分。
- 该路由先做 computer 凭据校验再解析超大 body：无 Bearer 或非法 key → 401（secret 不进入 parser），合法凭据的超大 body 才是 413。
- 其余 JSON 路由保持 100 KB 全局限制；形如 control 的 "-other" 兄弟路径不享受提升。
- manifest 预算按 trim 后字节计（transport 空白 padding 不计入 512 KB），对齐上游 576 KB request envelope。

### internalAgentApi.mentionActions：agent 发送者侧组

- `GET /internal/agent-api/mention-actions/pending`：只列出发送者是本 agent、尚未通知、`notifiableAtSend=false`、创建时间在 7 天内、宿主消息与频道仍存在的 mention 行；按 createdAt 倒序，payload `{resolutionId,messageId,channelId,channelName,targetType,targetId,targetHandle,availableActions:["notify"]}`，`limit+1` 探测 `has_more`。
- `POST /internal/agent-api/mention-actions/execute`：`action` 只接受 `notify`/`add`；`resolutionIds`（或 `ids`）去重、trim、最多 100 条；逐 id 返回 typed 结果而不是整批失败。
- `notify`：目标无读权限 → `no_permission/target_lacks_read_access`；成功时写 notified 字段（byType=agent、byId=绑定 agent、action=notify_only），并对同一 message+target 的所有未决行一起标记、返回 `dedupedResolutionIds`；不添加任何成员关系。
- `add`：agent 发送者永远得到 `no_permission/add_requires_human_member_authority` 且不写任何状态；若发送者已不在频道参与者中，先返回 `no_permission/sender_lacks_channel_access`。
- 未知 id、频道不属于该 agent 的 Server、宿主消息已删除 → `not_found`；已删除消息也会从 pending 中消失（级联）。
- notify 对私有 thread 的 cloak：目标非该私有 thread 成员 → `no_permission/target_lacks_read_access` 且不写 notified 字段（不把私有 thread 内容递给非成员）。
- 已 notify-only 的行再次 `add`：仍返回 `no_permission/add_requires_human_member_authority`，行保持 `notify_only` 不变。
- 明确排除：orchestrator 投递 spy（notify 的 queued/drop/handoff 重试语义属于进程内投递动作）、DB 行断言。

### attachmentPreviewBridge.api：HTML 预览注入桥组

- `GET /api/attachments/:id/html-preview`（previewToken）：原始文档未改写地流式输出，`AttachmentPreviewBridge.script`（与上游 `services/attachmentPreviewBridge.ts` 逐字一致）追加在其后；若文档自带 CSP meta 标签，桥插在该标签之前（meta CSP 只约束之后解析的内容）。
- 该响应不带 `Content-Length`（存储大小会截断追加的桥），CSP 头保留 `frame-ancestors 'self'` 并新增 `connect-src 'none'`、`form-action 'none'`、`object-src 'none'`。
- 桥脚本在缺少 `acBridgeNonce` 查询参数时完全惰性，因此普通预览行为不变；脚本只出现在预览响应里，下载/存储对象保持逐字节一致。
- 明确排除：上游对存储流式传输中断（真实对象存储 socket 生命周期）的处理，依赖未移植的存储传输层。

### internalAgentApi.inboxEligibility：单条未读规则组

- 规则：agent 自己造成的系统消息（如它自己 join 产生的 "was added to this channel"）对它 born-read —— wake hints 与 `/events` 拉取都不返回、也不通知；别人的动作造成的同一条系统消息对它保持未读，三个 transport（notice/wake、`/events` 拉取、入站投递）给出一致答案。
- 人类通过 `POST /api/channels/:id/members` 把 agent 加入频道时，会写入一条 `@<agent> was added to this channel.` 系统消息：对执行操作的人类 born-read（推进其读游标），对被加入的 agent 保持未读（wake hints 与 `/events` 都返回）。
- agent 自行 join（内部 agent-api join）产生的通知只对该 agent born-read；其后的普通消息恢复正常的 announce + pull。
- 明确排除：上游最后一条纯单元断言（`isMessageUnreadEligibleForReceiver` 的 noise-subtype 列表与 mention 穿透矩阵）不移植；其行为由上述 HTTP transport 断言覆盖。

### providerConnections.api：连接管理组

- 管理面 gated：server-stage `provider_connections` 规则未开启时，所有 `/api/provider-connections*` 读/写都返回 404 `provider_connections_disabled`（write-only 的 secret 不出现在任何错误体里）；开启后仅 owner/admin 可管理（member 403），且 list/create/rotate/patch 响应永不回显 credential。
- create 只接受 write-only `apiKey`；任何额外 alias（如 `clientSecret`）、把 `apiKey`/`providerId` 放进 metadata-only PATCH 都 400 且不回显 secret；rotate/patch-key 递增 `credentialVersion` 并回到 `unchecked`，只改 name 不变版本。
- 分配面：`GET /:id/agents` 返回 `{agents:[{id,name,displayName,runtime,status,computerName,deleted}]}`，member 403、跨 Server 或未知连接 404、无 secret 泄漏；DELETE `/:id/agents/:agentId` 对 malformed id 400、对仍活跃 Agent 409 `provider_connection_assignment_active`（Agent 编辑器是唯一改 provider 的入口）、已删除 Agent 可 detach。
- 删除连接：仍有活跃分配时 409；软删除的 Agent 不再阻塞，删除连接会一并清掉其分配行。
- 明确排除：case 1 的迁移默认值/launch-server 白名单纯单元断言，以及 case 3 的 `liftWakeBlockForConfigChange` orchestrator 调用 spy（契约排除进程内投递/编排注入）；其可观察结果（rename 不触发、rotate/patch-key 触发 runtime 值变化）依赖该 spy，无 HTTP 面。

### announcements.api：可见性组（部分）

- `GET /api/announcements/active` 只返回 `status == "published"` 且已有 `publishedAt` 的行：draft 永远不出现在任何通道（即使 startsAt 已到），scheduled 在 startsAt 之前不出现。
- 未过期、未 dismiss 的行按 startsAt 升序每次只返回最旧一条；`after=<id>` 继续下一页；最新一条到期后自然回落到下一条未读（这就是 scheduled 窗口排队的行为）。
- 仍待补：targeted audience（`server_id` 查询、冒名成员 404、recipient id 不外泄）、removed admin 路由的 404 全矩阵、失败写入 frontier 游标。

### agentMigrationReceiptDm.api：迁移回执 DM 组

- Computer 迁移完成时写入一条回执到"只有被迁移 agent 是成员"的隐藏 DM，频道名 `migration-receipt-<supportRef>`：agent 侧 `GET /internal/agent-api/inbox/conversations` 以 `dm:@migration-receipt-<supportRef>` 列出它（与真实 DM 同一命名规则），`GET /internal/agent-api/history?channel=dm:@migration-receipt-<ref>` 返回 200，正文含 "Migration completed" 与 supportRef。
- 其他 agent 用同一名字读历史得到中性的 404 `Channel not found or not visible`，响应里不含回执正文；名字解析不命中任何 peer。
- 向回执 DM 发消息是只读拒绝：`/send` 与 `/v2/send` 都返回 409 `code=MIGRATION_RECEIPT_READ_ONLY`，error 含 "one-way notice"、suggestedNextAction 指向 owner's DM，且不落任何消息；其他 agent 发送仍 404。
- 回执 DM 不再被 inbox 隐藏（旧端口测试按"隐藏"固定，现按上游"列出且可读"更新）。

### attachmentComments.api：可见性与门禁组（部分）

- feature flag `attachment_comments_v0` 按 server-stage 规则生效（默认开）：关闭后用 `POST/GET /api/attachments/:id/comments` 与 `GET /api/attachments/comments/counts` 一律先得到 403 `attachment_comments_disabled`，在 malformed-id/body 校验之前；开启时 malformed `:id` 是 400 `invalid_attachment_id`（同样的 400 在关闭时仍是统一 403）。
- `GET /api/attachments/comments/counts?ids=a,b,c`：1-100 个 id（空列表或超限 400），只统计调用者可读的附件，返回 `{counts:{id: n}}`。
- `GET /api/attachments/:id/comments`：不可见/不存在 404（不泄漏），返回按创建时间排序的 `comments[{id,attachmentId,content,anchor,sender{type,id,name},createdAt,reactions}]` 与 `viewer{canComment,reason}`（archived / unlinked / not_member / ok）。
- `POST /api/attachments/:id/comments`：flag → malformed-id → 私有频道 cloak 404 → 未链接 422 `attachment_not_linked` → 归档 409 `channel_archived` → 非成员 403 `not_a_member` → body 校验；成功时写 comment 记录与消息。
- 仍待补：thread 宿主复用/级联、read-only 计费只读态、结构 anchors 词表与上限、mentions 管线、history scoped metadata 与 agent scope quotation。

### announcements.api：targeted audience 组

- `GET /api/announcements/active` 与 `POST /api/announcements/:id/dismiss` 接受至多一个 `server_id`：未提供时 `server_id` 规则只放行无 audience 的公告；非法 UUID 或重复参数 → 400，绝不会退化为全局可见。
- targeted 公告只在 `server_id` 命中且调用者是该 Server 成员时可见（冒名成员得到空列表；dismiss 得到 404），payload 不包含 `audience` 字段。`X-Server-Id` 头作为 `server_id` 的等价来源。
- 每用户 dismissal 独立；重新发布的新公告行会再次出现。发布/admin 路由未挂载：`POST /api/announcements` 与 `/api/admin/announcements*` 一律 404。
- 明确排除：failed-write frontier 的游标推进（DB 写失败前缀，非 HTTP 可观察）、scheduled 内容/时间可编辑的 service 级断言（窗口排队的可观察行为已由过期回落覆盖）、onboarding login family gate（本端口无该 gate，行为恒为放行）。

### attachmentComments.api：thread 宿主与级联组

- 评论是"附件宿主消息 thread"里的普通消息：`POST /api/attachments/:id/comments` 返回 `{message, threadChannelId}`，`message.channelId == threadChannelId != 父频道`；同一宿主消息下的兄弟附件共享同一 thread（复用而非 thread-in-thread）。
- scoped list/counts 仍按附件过滤：同一 thread 里的普通回复不出现在某附件的 comments 里，兄弟附件各自 count。
- 删除评论消息时其 scoped ref 行级联消失（list/counts 同步），对应上游 schema FK 的构造性属性。
- 仍待补：`commentRef`（创建响应/消息列表 enrichment）、`message:updated` live 事件、user-stage flag deny 的 403 行为、anchors 词表/上限、mentions 管线、history scoped metadata、agent scope quotation。

### attachmentComments.api：anchors 与 mentions 组

- anchor 是封闭词表 `lines` / `csv-rows` / `md-section` / `html-region`，客户端 payload 必须是 `{type,data}`；未知 type → 400 `anchor_type_invalid`，`data` 非对象或形状错误 → 400 `anchor_invalid`，整个 payload > 4 KB → 400 `anchor_too_large`（先于逐类型校验）。
- 存储时按已知字段规范重建：extras 丢弃；`lines`/`csv-rows` 要求整数 `start≥1` 且 `end≥start`；`md-section` 要求非空 `headingId` 与 `headingTitle`；`html-region` 要求有限数字、x/y/w/h≥0、viewport/document 尺寸>0，浮点四舍五入为整数；可选短 `quote` 原样保留。list 原样回读规范后的 anchor，无 anchor 的行返回 `null`，被拒绝的 anchor 不产生消息或 ref。
- `mentions` 走共享消息管线：`[{type,id,name}]` 严格校验（type 只能是 user/agent、id 必须是 UUID、name 非空），非法批次 400 `mentions_invalid` 且不写入；合法批次在评论消息上写入 mention 行。

### attachmentComments.api：commentRef 与 user-stage deny 组

- 评论消息带 scoped `commentRef`：`{attachmentId, hostMessageId, hostSource:{type:"channel",routeKind:"channel",channelId,rootThreadChannelId}}`；创建响应里直接可见（供本地立即渲染），thread 消息列表（`GET /api/messages/channel/:id`）对同一行富化同一份 chip。
- flag 评估加入 user stage：user-stage deny 的用户在 list/counts/create 得到 403 `attachment_comments_disabled`，thread 消息列表仍 200 但该行的 `commentRef` 被隐藏（不泄漏 scoped 元数据）。
- 仍待补：`message:updated` live 事件、context/permalink 与 sync 的 commentRef/commentCount 富化、history scoped metadata、agent scope quotation。

### attachmentComments.api：sync / context 投影组

- `GET /api/messages/sync` 与 `GET /api/messages/context/:id` 的消息行现在都带 `attachments[{id,commentCount}]` 与 scoped `commentRef`：启用的查看者在父消息上看到真实 commentCount、在评论行上看到 chip；user-stage deny 的查看者两类投影分别退化为 `commentCount: 0` 与缺失/`null`，不泄漏 scoped 元数据。
- `GET /api/messages/channel/:id` 同样使用带 commentCount 的附件投影（此前只有 id）。
- 仍待补：`message:updated` live 事件（进程内 io spy，按契约排除）、history scoped metadata、agent scope quotation。

### attachmentComments.api：reaction ACK 投影组

- `POST/DELETE /api/messages/:id/reactions` 的 ACK 现在带 scoped 投影：评论消息返回 `commentRef`（无则为 `null`），父消息返回 `attachments[{id,commentCount}]`；user-stage deny 的查看者仍能 reaction，但 `commentRef` 为 `null`、`commentCount` 为 0。
- 该模块的可移植面至此覆盖完毕：flag gate（server/user stage）、malformed 顺序、counts、viewer 状态、私有 cloak、unlinked/archived/非成员边界、host-message thread 复用与级联、anchor 词表/上限、strict mentions、create/listing/sync/context/reaction 的 commentRef 与 commentCount 投影。
- 明确排除：`message:updated` live 事件的 io-spy 断言（契约排除进程内广播 spy）、read-only A3 的 billing 只读态（依赖未移植的 billing 功能面）、agent history/search 的 scope quotation（agent transport epic）、failed-write frontier 游标（DB 写失败前缀）。

### channels.getJoined.api：频道详情 joined/thread/DM 组

- `GET /api/channels/:id` 的 `joined` 按请求者实时计算：regular/private 频道的参与者为 true，未加入的 server member 为 false；`#all`（name "all"）是隐式加入，恒为 true；非 UUID 的 id 返回 404 `{"error":"Channel not found"}` 而不是 500。
- thread 详情：能看到 parent 的 server member 可 hydrate 线程（200，type thread）；私有 parent 对非成员 cloak 成同一 404，不泄漏线程元数据。
- DM 详情：参与者本人看到 `type:"dm"`、`joined:true` 与 `peerType/peerId/peerName`；agent peer 被软删除后详情仍可 hydrate（peer 字段完整），但该 DM 不再出现在 `GET /api/channels/dm` 列表（详情水合不得复活已删除 agent 的 DM）。

### channels.archive.api：freeze 收尾组

- 归档的 thread 继承 parent 的冻结：向 archived parent 下的 thread 发送消息返回 409 `channel_archived`（不只是 thread 频道自身 archived 时）。
- legacy channel-agent 写路由（`POST /channels/:id/agents`、`DELETE /channels/:id/agents/:agentId`）未挂载 → 404；替代的 member 路由仍可用（200）。
- archived 频道的消息仍可搜索：`GET /api/messages/search` 命中行带 `channelArchivedAt`，跳转 `GET /api/messages/context/:id` 返回 200 且 `channelArchived:true`，`channelId` 过滤在 archived 频道上照常工作。
- 明确排除：notificationEvents 的 DB 行断言（archive 幂等不发重复事件、agent archive 的 public-channel app notification 恰好一次）——纯数据库事件表，没有 HTTP/socket 可观察面。

### daemon helpers: historyFormatting / recentDeliveryIds / logger

- `DaemonTextFormatting.formatHistoryMessageLine`：header 依序拼 `seq/msg/time`（UTC 时间戳 `yyyy-MM-dd HH:mm:ssZ`，不可解析时回显原值），可选 `type`、`threadId`、`replyCount`（>0 才出现）；sender 句柄为 `@name` 或 `@name — description`；附件后缀列出 `filename (id:att-id)` 并带 `raft attachment view --id <attachmentId> --output <path>` 提示（`mcp_tool` 风格为 `view_file`），任务后缀 `[task #N status=… assignee=type:id]`。
- `RecentDeliveryIds`：按 age 过期（达到 maxAge 即失效）与 maxEntries 上限淘汰最旧项；重复 remember 会把 id 移到最新端。
- `DaemonLog`：订阅者收到 `{level,line,message}`，line 形如 `yyyy-MM-dd HH:mm:ssZ [INFO] message`；unsubscribe 后不再收到。

### daemon helpers: processEnvPatch / osVariant

- `DaemonProcessEnv.withProcessEnvPatch(patch, removeFirst:)`：在真实进程环境上叠加 agent env，覆盖/删除的键在结束后恢复（原本不存在则删除），叠加期间 `ambient()` 返回未叠加的副本；多次叠加串行执行，跨 await 保持。
- `DaemonOsVariant`：`microsoft-standard`/`wsl2` → wsl2，仅 `microsoft`（如 `4.4.0-19041-Microsoft`）→ wsl1，其余 Linux 内核为 nil；非 linux 平台或内核读取失败返回 nil。
- 明确排除：processEnvPatch 的 3 条 TS 源码守卫用例（扫描 `node:child_process` 调用点必须显式传 env、drivers 必须使用 `ambientProcessEnv()`）——纯源码扫描，本移植没有对应 TS 源码可扫描；其行为已由 `ambient()` 的运行时语义覆盖。

### daemon machineLock

- 每个 machine key 只允许一个 daemon 运行：`machine-<sha256(apiKey) 前16>` 目录下的 `daemon.lock` + `owner.json`（`{pid, token, hostname, startedAt, serverUrl, apiKeyFingerprint, schemaVersion:2, kind, serverId?, serverMachineId?}`）。
- 冲突时抛错并带 `pid/startedAt/host` 描述（`Another Slock daemon is already running ...`）；`owner.json` 已是 pid 0 的陈旧锁可被回收；无 owner 且目录新鲜（<30s）的不完整锁保留并冲突；ledger 里 `SLOCK_HOME`（或 `RAFT_HOME`）决定默认 `machines/` 根目录。
- 干净释放不删除机器身份：把 `owner.json` 的 pid 改写为 0，保留 fingerprint/provenance；managed Computer runner 的 `kind/serverId/serverMachineId` 在释放后仍保留。

### daemon turnSummaryTracker

- `DaemonTurnSummaryTracker` 按 agent 维护 turn：`begin` 打开新 turn（若上一个未结束则以其 `previousOutcome` 收束并返回 summary）；`observe` 折叠 `tool_start`/`tool_end`（工具分类：shell 命令表 → run_checks/version_control/read_file/search/run_command，send/read 等语义映射，`mcp__`/斜杠工具 → mcp），未匹配 callId 的 end 依序消费 unmatched；`noteSendOutcome` 记录 sent（messageId/lastReply）或 held（send_held problem）；`finish` 只产出一次。
- summary 形状与上游一致：`v:1`、startedAt/endedAt（clamp）、outcome、trigger、按首次出现排序的 actions、toolCalls、problems（上限 20，problemCount 为全量）、messagesSent、lastReplyMessageId；`turnOutcomeForActivity` 只在 online+idle / offline+runtime_crashed|runtime_unavailable / offline+其他 detail 时结束 turn。
- `turnTriggerFromMessages`：频道路径 `#name`，thread 路径 `#parent:channelName 的 8 位后缀`，DM 路径 `dm:@sender`，并携带 channelId/sender/messageId。

### daemon launchPhaseTransition

- 两族导出行为 `launch_runtime_readiness_transition` / `launch_activation_delivery_transition`：enter/close 行都带 identity spine（agent_launch_id/agent_id/server_id/machine_id/runtime/driver/launch_source）；wait enter 带 `is_wait_state:true`、封闭 `fence_kind`（readiness: runtime_startup_timeout；activation: none）与可选 `deadline_unix_ms`；close 带封闭 `close_result`，activation close 可带 `delivered_via`（spawn_prompt|stdin）。
- 配对契约：`(agent_launch_id, state_instance_id)` 上一个 enter 恰好一个 close，`transition_seq` 只作排序/审计且不可复用；relaunch 各自独立配对；缺失 launch id 以 `negative_evidence_bucket: missing_launch_id` 表达（enter 与 close 都带）。
- Q8 scrub：断言器拒绝任何包含 prompt/payload/stderr/text/token/secret/credential/api_key/cwd/home/path/endpoint/env 的 attr key（`launch_source`/`span_name` 白名单例外）。

### daemon probeGate

- 同 key 的并发 probe 合并为一次运行并共享结果（不会起第二个进程）；运行结束后同 key 的下一次请求重新开始。
- 不同 key 按 `maxConcurrent` 上限 FIFO 排队（默认无限，daemon 用它避免相同 key 重叠又让不同 runtime 不互相排队）；失败运行把同一个错误抛给所有 joining 调用者，并释放 key 与槽位，之后 key 可立即复用。
- `maxConcurrent` 必须是正整数或 nil（无限），0/负数初始化抛错。

### daemon hostIdentity

- `hostIdHashForServer`：`HMAC-SHA256(key=hardwareId, "raft-host-id-v1:"+serverId)` 的 hex 前 32 位——同一机器同一 server 稳定、不同 server/机器不同、绝不包含原始硬件 ID。
- `normalizeHardwareId`：接受 machine-id / UUID / GUID 形式（大小写与横线不敏感），要求 16-64 hex；空、过短、全零、非 hex 一律 nil。
- 平台发现：Linux 读 `/etc/machine-id`（回退 `/var/lib/dbus/machine-id`）；macOS 从 `ioreg` 的 `IOPlatformUUID` 解析；Windows 从 `reg query` 的 `MachineGuid` 解析；命令失败/未知平台返回 nil。IO 错误可注入（readFile/run），便于测试且不 spawn。

### daemon toolCallOutcome

- tool 调用结局由 daemon 侧计时：`noteToolCallStart` 按 callId 记录起点（重复 id 刷新位置），开放调用上限 256，超出淘汰最旧；`finishToolCall` 忘记该 id，优先用 runtime 自报的 durationMs（负数丢弃并回退 daemon 测量），无 callId 时仅带 ok/exitCode 等已有字段；没有任何信息时返回 nil。

### daemon token usage normalizers（pi / gemini）

- 两族都遵循 value-provenance 纪律：仅提取有限数值、显式 allowlist（不 passthrough 原对象）、mark-absent 不零填——空/缺失 usage 不产生事件，字段存在且为 0 是真实上报的 0，照常发出。
- `PiTokenUsage`：pi-ai `Usage` 顶层 input/output/cacheRead/cacheWrite/cacheWrite1h/reasoning/totalTokens → `*_tokens`，嵌套 `cost` 的 total/input/output/cacheRead/cacheWrite → `totalCostUsd/cost_*_usd`；`message.usage` 为空/非对象/数组 → nil；source=`pi_message_end_usage`。
- `GeminiTokenUsage`：只提取 runtime 契约确认的 `total_tokens`；source=`gemini_result_stats`；null sessionId 归一为缺省。

### daemon windowsPowerShellEnv

- Windows PowerShell 子进程环境会删除所有大小写变体的 `PSModulePath`（PowerShell 7 导出的模块路径会破坏 Windows PowerShell 5.1 启动），让子进程按自己的 edition 初始化；传入 env 不被修改，未传入时从继承环境派生副本。

### daemon feedbackTranscriptWindow

- `assess` 以 reportGeneratedAt 与 tolerance（默认 15 分钟）计算 report window，从 transcript（JSON 或逐行 JSONL，坏行单独跳过）里深度≤12、节点≤100k 地扫描 timestamp/created_at/updated_at/started_at/ended_at 等键，只抽取时间戳、绝不导出内容。
- coverage：report 时间不可解析 → `report_time_invalid`；无时间戳 → `timestamps_unavailable`；最后事件早于 window 起点 → `outside_report_window`；否则 `covered`，并给出 first/last 事件的 ISO 毫秒时间。

### daemon computerMigrationGuard

- 已被 Computer 接管的 legacy machine key 再次启动 raft-daemon 时，`LegacyDaemonKeyAdoptedByComputerError` 拒绝启动并给出精确指引：迁移目标（slug 展示为 `/slug`，否则 serverId）、"do not restart raft-daemon with the migrated key"、以及 supervisor 清理命令。
- detection 命中时使用其 `detail` + `cleanupCommands`；未命中时回退 PM2 / systemd / launchd 三条固定清理命令。末尾总是给出 `raft-computer start|status [/slug]`。

### daemon runtimeProcessBindingFence

- 被替换进程的 output 会被拒绝：同一 process × reason × source 每 10s 窗口只记录一次 trace（`daemon.agent.runtime_binding.rejected`，带 `agent_id/process_instance_id/direction/source/reason/suppressed_count`），其间拒绝只计数；窗口结束后下一次拒绝记录累计的 suppressed_count 并从零重新计数。
- input 拒绝（binding 不匹配）每次 send 都单独记录、不折叠；binding 匹配时放行（本移植的 fence 只做校验与记录，不转接 runtime send）。
- 绑定按 runtime token 建立；validation 依 binding_missing / inactive_process_generation / agent / process / launch / session 不匹配给出原因。

### daemon grokEventNormalizer

- Grok (ACP/JSON-RPC) 通知归一：`agent_message_chunk`/`agent_thought_chunk` → text/thinking（带 runtimeTurn 归属：进行中的 generation 标 active、上一个已完成的标 completed）；非本 session 的通知丢弃。
- 工具：`tool_call_delta_chunk` 按 tool_index/tool_call_id 累积参数并只回 internal_progress；`tool_call` 首次发出 tool_call（name 从 `_meta.x.ai/tool.name`/name/title 取，参数为 rawInput 或累积 JSON），重复只回 progress；`tool_call_update` 的 completed/failed/cancelled 首次发出 tool_output（`grokToolEndOutcome`：completed 为 ok；failed/cancelled 仅在带 exit_code 时 ok 且记录 exitCode），重复或 turn 已结束且未见过该调用则回 progress。
- 轮次：`turn_completed` 按 prompt_id 归属 generation；已完成的 generation 去重（上限 32）；晚到/未知 prompt 不完成新轮；autonomous successor（`task-completed-call-*`）在无活动轮时自建一轮且终态只发一次，有活动 foreground 轮时抑制并保持去重；`finishPrompt` 产出 token_usage telemetry（grok_acp）、error（stop_reason=error/cancelled）与 turn_end，并清空工具状态。
- `pending_interaction`/`interaction_resolved`/未知扩展一律 internal_progress（含 payloadBytes）。

### daemon spawnFailureClassification

- 启动失败只按 typed code 分类，消息文本永不参与判定：`ENOENT` 映射为 `runtime_not_found`，其余未知 code / 无 code → `runtime_spawn_failed`；message 只作为 detail。
- 各 reason 的 userMessage：versionTooOld 原样消息；model_not_found 指名模型（renamed/removed 或 provider 无 key，不引导重装 CLI）；agent_proxy_bind_failed / runner_credential_mint_failed / provider_connection_materialization_failed（http 带状态码、invalid_payload/invalid_environment 各自文案）/ model_not_configured / session_needs_reset / session_runtime_mismatch / runtime_login_required / runtime_config_invalid 均有固定文案；`runtime_not_found` 依 lookup verdict：confirmed miss（`not_on_path`）给安装指引，其余 lookup 结果给 resolver 自己的 path-free 消息，无 verdict 给中性文案。
- lookup verdict 支持 launch 词表与 probe 词表（not_installed→not_on_path、probe_timeout→lookup_timed_out、permission_denied→lookup_permission_denied、probe_failed→lookup_failed），可来自 cause；unsupported_version 无 verdict。
- `startFailureActivity`：detail=userMessage，spawnFailure 仅在 model 类 reason 时携带截断 128 的 model、仅 `runtime_not_found` 时携带 lookupReason。

### daemon runtimeTurnState / deviceClass

- `RuntimeTurnState`：跟踪 Codex turn 生命周期——markTurnStarted 设置当前 turn（并接住 pending 期间的非空输入证据）、noteTurnAccepted 只记 pending（此时不可 steer）、tool boundary 后 gate 住 busy steering 直到 markProgress、markTurnCompleted/reset 清空状态；hasLiveTurn 覆盖 accepted/running，completedTurnIds 上限 16，completedWithoutRuntimeActivity 只在无 activity 且无 token usage 时为真。
- `DeviceClassDetector`：mac 用 `system_profiler` JSON（VirtualMac* → vm；MacBook*/Mac mini/Mac Studio/iMac/Mac Pro 前缀映射），Linux 用 DMI chassis 集合（laptop 8/9/10/14/31/32、desktop 3/4/5/6/7/13/15/16/35/36、server 17/23/28/29）且 hypervisor vendor/type 优先判 vm；WSL、Windows、读取失败均为 nil；只输出类别，不保留原始型号/DMI 字符串。

### daemon runtimeLaunchVersion

- 启动前按 driver 的 launchVersionPolicy 评估 runtime CLI 版本：只 block 精确的 known-bad 版本（版本三元组取首段 `x.y.z`，含前后缀可解析）；低于 tested-good 但不在 known-bad 时 warn 并放行；缺失版本（probe unavailable 或 version 缺失）与不可解析版本分别 warn `version_unavailable`/`version_unparseable`；等于或高于 tested-good 为 compatible；无 policy 的 runtime 为 `not_configured` 字节级不变。
- 每次创建都重新 probe（不缓存），因此就地升级 CLI 后无需重启 daemon 即解锁；`enforce` 在 block 时抛错、warn 时回调警告。

### daemon startupMemoryBlock

- flag 只在 server 端开启时生效：server 未开则 env 无法打开；env 只能关闭（`0`），per-agent env 覆盖 process env；预算默认 4000 tokens（`RAFT_STARTUP_MEMORY_BLOCK_TOKENS` 可覆盖）。
- 读取工作区 `MEMORY.md`：缺失/空/仅空白 → 不注入；预算内（4 bytes/token）→ 全文注入并标 `complete="true"` 与 no-re-read 提示；超预算 → 按行边界头截断，带 `shown="first X.X KB"`、`read the file for the rest` 与准确大小，多字节字符不截断码点。
- `apply`：block 为 nil 时原样返回；否则 block + 双换行 + prompt，promptSource 加 `_with_memory`。
- 明确排除：上游第 8 条（recycle briefing 中 chrome/memory/panel 的排序）依赖尚未移植的 `wakeSessionRecycle`，其断言在 PARITY 记为依赖 epic。

### daemon agentStartPendingDeliveryBuffer

- 负责"wake 已接受、runtime 尚不能收输入"窗口内的消息缓冲：I1 每个 pending key 必须属于当前 start-state 快照（queued/starting/terminal recovery/cooldown），否则 assertInvariants 抛 "pending messages for non-starting agent"。
- I2 exactly-once：rebindWake 把旧 wake append 进 pending（不覆盖，DROP 回归）、drainOnSpawn 返回全部并清空 owner（二次 drain 只给新缓冲，DUP 回归）、cancelStart/cancelAllStarts 清理孤儿、suppressConsumed 按谓词移除已消费消息并返回数量。
- 只暴露 count/snapshot/transition verbs：values 返回副本，外部改动不影响内部。

### daemon agentNoProcessResidency

- 无进程 agent 的业务事实与不变量：I1 active cooldown 必须有 idle restart config；I2 terminal failure 与 idle restart config 互斥；I3 terminal failure 不能同时 running；I4 pending delivery 只能属于 queued/starting/terminal-recovery/cooldown-with-idle；I5 fingerprint fence 必须挂在 running/idle/terminal 证据上，不能单独路由；queued 与 starting 不得重叠。
- `allowedStartPendingSnapshot` 输出 queued/starting/terminalRecovery/cooldown-with-idle 快照。
- `AgentNoProcessResidencyTransitions` 发稳定 enter/close 配对行（span_name=launch_residency_transition、phase=process_residency，state_instance_id=residency_state_instance_id、transition_seq 单调递增）；同 state+launch 重复 enter 为空，切换 state 先发 advanced close 再发新 enter；缺失 launch id 以 `failure_kind`/`negative_evidence_bucket` 表达。

### daemon managedMcpTools

- Pi 的 managed MCP 工具：无 runner credential 时为空；否则以 Bearer 拉取 `/mcp/tools` 冻结目录（runtimeName/serverName/toolName/configVersion/assignmentVersion），每个工具经 `/mcp/call` 代理，body 带 `expectedConfigVersion`/`expectedAssignmentVersion` 作为 fence。
- 快照失败非致命：返回空列表 + 一条 <300 字符的 warning（含 code 与 status）；调用期传输失败统一为 outcome-unknown 文案（不提示重试）；5xx 无 Raft code 同样 unknown，带 code+error 则透传 Raft 文案。
- 远程错误文本 >4000 字符截断并加 `…[truncated]`，空错误命名为 `<runtimeName> failed`；serverName/toolName/description 中的所有换行分隔符压平为单空格，防止伪造 prompt 行。

### daemon agentCredentialProxy.routeFamily

- 代理遥测用的内容无关 route family 分类：internal agent-api pathname → 封闭 family 标签，顺序敏感（attachments/comments 必须先于通用 attachments；threads 与 threads/unfollow 分开；tasks/claim、tasks/update 先于 tasks；inbox/send/events/tasks/attachments/messages/servers/history/search/channel-members/knowledge/profile/integrations/upload/resolve-channel/prepare-action/reminders/channels join|leave 各有 family），未知路径返回 `unknown`。

### daemon agentActivityProducer

- `buildDaemonActivityMessage` 只允许 fact-typed detail kind 过线：未注册/非字符串 detailKind → drop `unknown_activity_detail_kind`；none/daemon_activity/external_activity/slock_action/other 等弱结论 kind → drop `non_fact_activity_detail_kind`，drop 记录 agentId/activity/detailKind/reason/isHeartbeat。
- 成功的 `agent:activity` 帧不携带 `activity`/`activityKind` 结论字段；status entry 会剥掉自身的 activity/activityKind，只保留 kind/detail/detailKind；辅助函数覆盖 drop trace attrs、thinking/text 投影与结束 thinking 的事件集合。

### errorResponse（全局 JSON 错误边界）

- 未捕获的 5xx 路由失败经 `JSONErrorBoundaryMiddleware` 转为净化 JSON：状态 500，header `x-slock-error-id` 与 body `correlationId` 同值，body 恰好 `{error:"Internal server error", code:"internal_server_error", correlationId}`，绝不泄漏 SQL/内部消息。
- 显式 typed 路由响应（如 409 `MACHINE_HAS_ASSIGNED_AGENTS`）不被改写、不带 error id header。
- 明确排除：RisingWave 连接池饱和的 503 + Retry-After 路径（本移植无 RisingWave 依赖）。

### independentAudit.api（设备 token 撤销 + guest 作用域外溢）

- 撤销族（logout）后，该族 access token 不再通过 `authorize`：既不能审批 device 授权，也不能换取新 session；控制组 refresh 仍 401。
- guest 角色的历史/同步作用域只覆盖其显式加入的频道：`GET /api/messages/sync`（省略 channel_id）不得返回 guest 未加入频道的消息；`GET /api/messages/channel/:id` 对非成员的 guest 返回 403。
- 明确排除：legacy machine key 迁移缓存热态用例（依赖 DB 缓存夹具与迁移写路径，本移植未移植该缓存层）。

### guestVisibilityBoundaries.api（HTTP 面）

- guest 角色对未显式加入的 hidden public channel 完全 cloaked：`GET /api/channels/:id`、`/members`、`/agents` 一律 404。
- guest 的 broad sync（省略 channel_id）不包含 hidden channel 的消息；guest 对 hidden channel 的 `read`、`read-all`、`unread` 写操作一律 404（`guestDeniedHiddenChannel` 统一 gate：guest 且非 `channelHumanIds` 成员）。
- 明确排除：三个 socket room 断言（metadata-bearing server-room events、降级为 guest 时断开、撤销 guestVisible 时驱逐 channel room）——socket room 面未移植。

### 删除频道 cloak（guest channel 生命周期前置）

- `DELETE /api/channels/:id` 后，`GET /api/messages/channel/:deletedId` 返回 404；线程深链在其 parent 被删除后同样 404（parent 仍存在且 `deletedAt` 非空时按删除处理），joint 投影线程保持原有成员可见性回退。
- 列表/同步/搜索的删除过滤保持原行为；本切片只补历史深链的可见性判断（`visible` 闭包先检查 `deletedAt`）。
- 已核对：删除频道的搜索命中被排除（结果不包含该 channelId），`GET /api/attachments/:id/url` 在所属频道删除后返回 404（`visibleAttachment` 的 `deletedAt` 检查），删除前仍可正常取 URL。

### Guest Join 门禁（guest channel 生命周期）

- 频道新增 `guestJoinable` 状态（默认 false，含 `setChannelGuestJoinableForTesting` seam）：guest 角色加入 public 频道必须先置位，否则 403；置位后 guest join 无每服务器上限（并行加入均 200）；归档频道 join 仍 409。
- 非 guest 成员加入逻辑不变。
- Guest 设置通过频道 API 暴露：`PATCH /api/channels/:id` 接受 `guestVisible`/`guestJoinable` 布尔（仅 owner/admin，否则 403），响应回显当前两值；启用后 guest 即可 join。
- Guest 频道列表按 `guestVisible` 过滤：`guestVisible=false` 的频道不出现在 guest 的 `/api/channels`；未显式设置的频道保持默认可见（兼容现有行为）。

### Guest 动作卡只读

- guest 可读取频道内的 action-card 摘要消息（carrier 历史包含代表 card 的消息）。
- guest 对 `POST /api/actions/:messageId/execute` 与新增的 `POST /api/actions/:messageId/mark-executed` 一律 403；`mark-executed` 由人类成员调用时把 card 置为 executed 并返回 `{kind:"action-card",state:"executed"}`，guest 不改变 card 状态。
- Guest 归档频道保持只读：归档后离开 active 列表，但 guest 历史仍可读；搜索命中保留 `channelArchivedAt` 只读标记；`join` 返回 409；guest 发帖返回 403（成员发帖仍 409 `channel_archived`）。

### daemon drivers/opencode.modelsAsync

- OpenCode 模型列表的异步探针子进程与同步孪生行为一致：Windows 上同样经 PowerShell 解析可执行文件，按版本选择 `models` 参数（2.x ≥ 2.0.27 带 `--standalone`），listing 子进程使用 5s 预算、`HOME`/`NO_COLOR=1` 环境与 `shell:false`。
- 失败映射一致：非零退出保留 status（无 error），timeout/spawn 失败携带 error；解析失败以 result 返回（status nil + 固定解析文案）而不抛错；`detectOpenCodeModelSource*` 区分 command failure（retryable error）、空成功（no_models）与 live 列表。
- 取消语义：预取消以 ABORT_ERR 拒绝；listing 途中 abort 连同 cleanup 透传，detect 包装不吞掉 abort。

### daemon agentRuntimeInput

- 具体消息渲染：每条消息一行 header（`[target=#parent:thread msg=… time=yyyy-MM-dd HH:mm:ssZ type=human] @name: body`），时间显式 UTC；body/sender_description/attachment 文件名/线程 context 的续行统一加 `  │ ` 前缀，splitlines 的所有分隔符（\n \r \v \f \x1c-\x1e \x85 U+2028 U+2029）都被中和，无法伪造第二条 header。
- 直接提及的 follow 复活提示渲染固定文案与 `raft thread unfollow --target "#parent:hash"`；普通 follow 投递不产生复活提示；thread join context 的 parent/recent 行以 `- [msg=… seq=… time=… type=…] @name:` 形式渲染。

### daemon wakeSessionRecycle

- 配置：仅 server 的 `constructed_wake_context` 可开启；per-agent `env_vars` 覆盖 daemon 进程 env；`RAFT_WAKE_RECYCLE=0` 是本地 kill switch（env 不能强行开启）；阈值默认 128k tokens / 1h。
- 决策：按序 gate → disabled、unsupported_runtime、no_prior_session、explicit_resume_prompt、runtime_profile_control、session_facts_unavailable、cache_possibly_warm（idle ≤ minColdGap）、context_below_threshold（≤ 阈值），全部 fail closed 为 resume(reason)；只有冷 gap + 大 context 才 recycle，且 briefing 为空（无公告/无指令）。
- transcript facts：读取 `~/.claude/projects/-workspace-agent/<sessionId>.jsonl` 尾部，last activity 取最后带 timestamp 的记录，context tokens 取最后 assistant usage 的 input+cache_read+cache_creation；无文件即 unknown。
- cold-idle sweep：按序跳过 disabled/not_idle/unsupported_runtime/no_session/recent_event/session_facts_unavailable/recent_activity（含 subagent sidecar mtime 与 transcript 时钟取 max）/context_below_threshold/no_transcript/background_tasks_unknown/background_tasks_outstanding；outstanding 扫描识别 Monitor/background/task 通知标记，terminal 标记清除后允许。
- 稳定化：`ProbeGate` 限流测试改为按启动信号顺序编排，消除 Task 调度顺序造成的误报。

### daemon drivers/runtimeChild

- runtime child 在 session 接管前被 guard 记录：stdout/stderr chunk、error、exit、close 按到达顺序保存（stdin error 也暂存，从不抛出）；hand-off 只回放一次，之后返回 nil。
- 未在 10s 内接管的 child 被放弃：丢弃已缓存输出、保留 error/exit、记录 warning（含 `not taken over within 10000ms` 与 `errors=<code>`），发 SIGTERM，5s 后仍存活再发 SIGKILL；放弃后到达的输出不再保存，hand-off 得到 `abandoned` 文案而非部分回放。
- 接管前输出超过 4MiB 也放弃（`exceeded`），不截断后伪装成完整回放。

### daemon providerRequestFetch

- provider 请求的被动诊断：等待时发 waiting，收到响应头后发 responding（2xx）或 failed（非 2xx，带 httpStatus）；transport 抛错时 failed，取消时 cancelled；observer 抛错不影响请求；requestId 全程唯一，provider 非法名归一为 `custom`。
- 请求与响应原样透传：保留原始 body/options/signal，返回 transport 的同一响应对象（identity/metadata/未锁定 body 不变，可独立 clone 读取），诊断不含请求或响应正文。

### daemon runtimeAccountUsage/kimiAuth

- Kimi Code OAuth key：默认 host 对（auth.kimi.com + api.kimi.com/coding/v1）映射 `oauth/kimi-code`；其他 host 对按 `{oauthHost,baseUrl}` 的 sha256 前 16 hex 生成 `oauth/kimi-code-env-<digest>`；storage name 拒绝空/以 `.` 开头/含路径分隔符的 key。
- provider-list 投影：仅 `managed:kimi-code` 且 type=kimi 时有效；env `KIMI_CODE_BASE_URL`/`KIMI_CODE_OAUTH_HOST`（兼容 `KIMI_OAUTH_HOST`）覆盖配置；无覆盖且配置 key 匹配时保留配置 storage（非 file 记 `other`）；`KIMI_CODE_HOME` 或 `~/.kimi-code` 树下派生 credentialPath（credentials/<name>.json）与 lockTarget（oauth/<name>）。
- `resolveKimiCodeAuth` 以 `provider list --json` 探针读取并投影，非 JSON 或无名 managed provider 返回 nil；附带 device headers 与 `device_id` 创建逻辑。

### daemon runtimeAccountUsage/kimiCredentialLock

- Kimi 刷新锁：`<target>.lock` 目录哨兵（sentinel 文件 `<target>` 预创建），stale 5s；有界重试（默认 12 次、0.5–1s 退避），拿不到锁返回 unavailable（reason 含 acquire 失败）且绝不运行回调；持锁期间每 max(stale/2,1s) 刷新 mtime，锁目录被删除或被他人以旧 mtime 接管时 handle 标记 compromised（不抛出）；释放后 `.lock` 目录消失，其他进程持锁时 `isHeld` 为 true、本方尝试被判 blocked。

### daemon sessionCompactionFailureLedger

- 每 agent 磁盘账本（`<agentsDir>/<agentId>/.raft/compaction-failures.json`，version/sessionId/model/count/updatedAtMs，绝不含会话内容）：同一 session+model 连续失败累加，达 3 次后 `needsReset` 返回计数（重启后仍生效）；不同 session id（Reset Session）、不同 model 或 `clear`（成功 compaction）后不再拒绝，damaged 文件读作无记录且下次失败从 1 重新计数；agent 之间互相独立。

### daemon apps/reminder/inboxDefinition

- system.reminder 的 due 通知项由 OS mint：itemId=`reminder:<uuid>:<revision>`、retention `until_explicit_ack`、primaryAction `run_command`/`reminder.ack`、actionCli `raft reminder ack --id <id 前 8> --revision <n>`；sourceRef 严格 `{kind:"reminder", id:UUID, revision:正整数}`，多余字段或 app 提供的 action 一律拒绝（invalid_source_ref / invalid_primary_action）。
- 标题预览单行化：控制字符与空白折叠为单空格、trim，超过 120 字符时截断到 119 字符并追加可见 `…`（按 UTF-16 计宽，绝不切断代理对）；空标题为 nil；store 以 itemId 去重并保序。

### daemon agentRuntimeInput.snapshot

- 回合输入文案快照（与 runtime delivery mode 无关）：空 resume 固定文案；unread resume 按 target 列表渲染 `- <target>: N unread` 并附 catch-up 指引（read 每频道最多一次、禁 check、命中直接请求则转入 active handling 等）；inbox notice 渲染 `[Raft inbox notice:` 块（pending/changed target 单复数、每 target first/latest sender/latest msg 行）与读取指引；other-unread 与 bounded-startup 后缀分别在非空时渲染两个前导空行 + 列表 + `raft inbox check` 指引，nil/空数组不输出任何后缀。

### daemon runtimeAccountUsage/kimiTokenRefresh

- Kimi Code token 保持新鲜：阈值 `max(300, expires_in*0.5)`；不在阈值内 fresh，不请求不写盘。需要刷新时在客户端同名锁内 re-read：若他人已轮换则 adopted；否则 `POST <oauthHost>/api/oauth/token`（form: client_id/grant_type/refresh_token，device headers 由 daemon 自称），轮换式响应写回客户端文件形态（2-space JSON + 末尾换行、0600、原子替换），锁释放后不留 `.lock`。
- 拒绝语义：401/403/invalid_grant 不重试、不写、不写 revoked tombstone，报 `rejected:refresh_rejected`；若 100ms 后 re-read 发现 refresh_token 已变则 adopted。429/5xx/网络错误按 3 次退避重试后报 transient(`server`/`network`)，并带 `expired`（刷新前是否已过期）；200 缺 access_token 报 `malformed_response`（不写盘），缺轮换字段报 `rotation_missing`。
- 锁/平台：客户端持锁（真实子进程目录锁）有界失败 `lock_unavailable`（不请求不写）；刷新期间锁被判断过期并被他人接管 → `lock_compromised` 且不写；win32、`KIMI_DISABLE_OAUTH_LOCK=1`、storage≠file 报 `platform_unsupported`；revoked tombstone 仅精确形态识别，`{}`/部分/错型/数组/非 JSON 报 `missing:malformed|unreadable`。
- 已知残余窗口：客户端无锁 login 落在最后一次比较与 rename 之间会被覆盖（`withKnownIssue` 标记，与上游 expected-failure 一致）。

### daemon runtimeTurnTokens

- 单回合 token 计数按 provider 计费口径拆分：`input` 为未缓存输入、`cacheRead`/`cacheWrite` 为缓存部分、`output` 含 reasoning；未上报字段缺省（绝不写 0）。
- 来源映射：`claude_result_usage` 直接取 inputTokens/outputTokens/cachedInputTokens/cacheCreationInputTokens；`pi_message_end_usage` 与 `kimi_turn_step_completed_usage` 按 input/output/cached_read/cache_write 累加；`codex_thread_token_usage_updated` 用 last* 与总量相减得到本轮值（cached input 从 input 中拆出），总量回退（session reset）时不给数字；其他来源（如 gemini 只有 total）跳过而不是猜测。
- trace attrs 输出 `input_tokens`/`output_tokens`/`cache_read_tokens`/`cache_write_tokens`（仅出现的字段）。

### daemon runtimeModelSourceProjection

- `machine:runtime_models:result` 增量载体：live 时同时携带 typed `outcome`（models 补 verified、保留 default 与可选 catalog）与 legacy `models`/`default` 字段；空 live catalog 先归一为 `no_models`（legacy models: []）；非 live 保留 typed outcome（missing_config 可带 recovery；error 带 retryable/code/reason）并按类型写 legacy `error`（missing_config/unsupported/error）或空 models。

### daemon runtimeProgressState

- 派生的 runtime 进度时钟：只有 runtime app event 与显式 internal-progress 刷新 lastEvent 或清除 stale latch（turn start 不清 latch）；stale 时间戳保留首次值；`ageMs` 以「lastEvent 与当前 turn start 取较晚者」为锚（避免长空闲后的首条输入被误判为整段空闲停滞），`lastEventAgeMs` 保持按 lastEvent 字面计算（`last_event_age_*` 遥测口径）；新的 runtime event 会覆盖更早的 turn start 锚。

### daemon runtimeCliVersionTracker

- 记录上次检测到的各 runtime CLI 版本（`<slockHome>/computer/runtime-cli-versions.json`，0600、原子写）：版本按点分数字比较（`codex-cli 0.163.0`、`2.1.301 (Claude Code)` 等前缀后缀不影响）；首次只记录，之后变化产生 change（upgrade/downgrade/changed），downgrade 同时保留 notice（from 为首次下降前的好版本、to 与时间），回到 >= from 时清除；本轮未检测到的 runtime 保留原记录；文件损坏读作空状态。

### daemon passiveAxGate

- RFC 072 §7 passive AX 门禁：server flag 为唯一开启条件；`RAFT_PASSIVE_AX=0/false/off/空串` 在 agent env_vars 或 daemon 进程 env 任一处置 false 即关闭（紧急停止，两侧互不覆盖）；无法解析的值视为无意见；env 不能在没有 server flag 时开启。

### daemon agentStartCoordinator

- agent start 的队列/查找单一边界：同一 agent 重复 enqueue 报 already queued；starting 集合与 queued 集合互斥（starting 中不能再 enqueue、queued 中不能 markStarting）；队列 age 取自不可变的 enqueuedAt（缺失为 0）。
- 泵状态受容量门禁：active starts 达到 maxConcurrentStarts 时 blocked(capacity_full)，release 后对队首 ready；取消操作同时清 queue 与 lookup，`cancelAllQueued` 的 per-item 回调在持锁外执行且观察到清理前深度（避免 NSLock 非重入死锁）。

### daemon activity/activitySink

- 旧版 `agent:activity` 传输：新 fact 盖 clientSeq、producer_fact_id（`daemon_activity:<agent>:<launch|legacy>[:<daemonInstanceId>]:<seq>`）、observedAtMs 与 daemonInstanceId，并记录 `daemon.agent.activity.produced` trace（含 server_id/ap_present/correlation_id/entry_kinds）；非 fact/未知 detail kind 丢弃并记录 `daemon.agent.activity.dropped`（status error），不发帧也不产生 produced trace。
- heartbeat 标记 isHeartbeat 且 fact id 省略 daemonInstanceId 段（legacy 命名空间）；probe reply 携带 probeId、无 observedAtMs；raw send 原样透传调用方 clientSeq（nil 则省略）并带 daemonInstanceId。

### daemon directUploadCapability

- 直传能力：daemon 先向 server `POST /internal/machine/scope-attestation`（Bearer machine key，body scope+可选 metadata）取签名的 machine-scope attestation；再向 worker `POST <createPath>`（body 携带 attestation，不带 server 凭据）创建上传会话；最后按会话给出的 method/url/headers 直接 PUT 字节，server 不在数据面。
- 失败带 hop 标签（attestation/create/put）与 HTTP status，`classify` 不解析文案：有 status 按 4xx/5xx 分类，URLError 记 network，其余 other；server 返回 HTML 413 也按 413 归类。

### daemon providerConnectionLaunch

- 启动期 provider connection materialization：daemon `POST <server>/internal/computer/runners/<agent>/provider-connection`（Bearer daemon key、X-Raft-Client 标识、body 仅 connectionId），严格校验响应形状——顶层键恰为 envVars/providerConnection，projection 键恰为 endpointUrl/providerId/supportsImageInput，providerId 必须在 preset（16 个，如 deepseek→DEEPSEEK_API_KEY、google→GEMINI_API_KEY）或 gateway（openai-compatible/anthropic-compatible）集合内；未知字段报 invalid payload。
- preset 必须 env 恰为一个非空 key、endpointUrl=null 且 supportsImageInput=false；gateway 必须 env 恰为 apiKey/baseUrl 两键、endpointUrl 非空且与 baseUrl env 完全一致；不一致报 invalid environment；HTTP 失败带状态。

### daemon codexToolArgumentParseSignature

- Codex driver 唯一被许可的 stderr 文本签名（task #1127）：同一行同时包含 tracing target `codex_core::tools::router` 与句子 `failed to parse function arguments:` 才判定为工具参数反序列化失败（转成 typed ToolArgumentParseError code）；serde 尾部（类型/值）不参与签名也绝不记录。同 target 的 `write_stdin failed` 或其它 target 的同句都不匹配；按 `\r?\n` 拆 chunk，容忍多行 stderr 但两半必须同行。
- trace 契约 `daemon.agent.tool_argument_parse_failed` 仅允许 agentId/launchId/runtime/model，禁止 stderr/error/arguments/detail/message，防止参数值进入 trace。

### daemon standingPromptRefresh

- resumed session 的 standing prompt 刷新（task #13）：按 agent 在其 workspace `.raft/standing-prompt.json` 记录 sessionId + promptHash（sha256 前 32 hex，仅 id/hash/时间）；hash 前先清空 volatile 字段（`runtimeContext.daemonVersion`、`runtimeProfileControl`，发布/通知不算新 prompt），其它配置变化才算。
- 计划：非 resume 或 runtime 自行重建 prompt → none；无记录或记录属于别的 session → baseline_unknown（只写记录不注入）；hash 相同 → unchanged；不同 → inject 并带 staleForMs（now-recordedAt，最小 0）。注入把完整当前 prompt 以 `<raft-standing-prompt-update>` 块放到首条输入最前并标记替换旧指令，promptSource 追加 `_with_standing_prompt_update`；unchanged 情形原样返回。
- 非移植用例：上游 5 例中「各 driver 的 standingPromptRefreshesOnResume 标志表」依赖未移植的 driver 类，本移植不适用（PARITY 已注明）。

### daemon agentMigrationObjectStoreBundle

- 迁移 bundle 条目计数：严格 250,000 上限（含 export walk 仅计数未入列的 overflow 条目）；超限抛 `AgentMigrationObjectStoreEntryCountLimitError`，message 固定为 `MIGRATION_OBJECT_STORE_ENTRY_COUNT_LIMIT_EXCEEDED:entryCount=<n>:maxEntries=<m>:topPathCounts=<path,count;...>`，最多 3 个 top-level 路径、每段 percent-encode 后最长 96 字符，整体 <500。
- 计数按 workspace 相对路径的顶层目录聚合、降序（同数按路径升序）；secret/token/credential/api-key/.env 形状的路径归并为 `other/`，错误 wire 不泄露明文、主机路径或绝对路径；`bundleTooLargeTopEntries` 同样按字节降序并 redaction。
- workspace 相对路径规范化：拒绝空、`.`、POSIX 绝对、盘符绝对/相对、UNC、任何 `..` 父段与 NUL；反斜杠统一为 `/`，去除 `./` 与空段（`./nested\safe//file.txt` → `nested/safe/file.txt`）。

### daemon workspaces

- 工作区目录解析采用包含性校验（非黑名单）：解析后的目标必须恰好是 dataDir 的一级子目录；`.`/空/`./`/`x/..`/`../x`/嵌套路径一律返回 nil，`agent-1/` 与 `.hidden-agent` 仍被接受。
- 扫描：递归汇总每个工作区目录的 fileCount、总字节与最新 mtime（含子目录自身 mtime），跳过 runtime-outcome outbox；`lastModified` 为带毫秒 ISO8601；displayPath 在用户 home 下显示 `~/…/`，否则绝对路径 + `/`，仅前缀相同不算 home（/home/alice2）。
- 删除只接受合法一级子目录并递归删除；请求 `.`/空串时返回 false 且根目录与所有工作区保持不变。
- initializeWorkspace 建目录、缺省写 MEMORY.md 与 seedFiles（已存在不覆盖）。

### daemon processMemory

- 进程内存采样：启动后 60s 首采、之后每 5 分钟采样并原子写 `<samplePath>`（0600）；最多每 30 分钟发一次 `daemon.process.memory`（attrs 在事件时读取 context，再并入样本的整 MB 字段）；写文件失败仅回调 onWriteError 不影响后续采样；stop 清定时器。
- attrs 契约固定 keys（process_instance_id/agents_running/agents_in_process/uptime_ms/*_mb/lazy_schemas_* + 可选 swap_mb/service_*）；无 swap 时缺省；service 样本仅在 sampledAt 距今 0–15 分钟内携带（rss/heap 必须数字，可带 swap）。
- Linux VmSwap 解析出 swapBytes（缺失即缺省）；Swift 无 V8 heap space，`old_space` 等取自进程 heap 数字（文档化替代，不是 V8 语义）。

### daemon legacySupervisor

- 检测仍在托管本 daemon 的 legacy supervisor 并给出精确清理命令（可注入 probe：pid/platform/env/execFile/readFile）：
  - PM2：祖先进程中含 pm2 或 env 有 PM2_HOME/pm_id 时才探测（不为无关进程启动 pm2）；`pm2 jlist` 中匹配 related pid 的 app 名 → `pm2 delete '<name>'` + `pm2 save`（名字单引号安全转义，含 `'` 时按 `'\''`）；解析失败给占位名称。
  - systemd（仅 linux）：`/proc/<pid>/cgroup` 里取最后一个非 `user@N.service` 的 `.service` 单元，`/user.slice/` 内用 `systemctl --user`，否则 `sudo systemctl`；仅 INVOCATION_ID 无单元时给占位；普通用户会话 cgroup（如 vte-spawn.scope）不误报。
  - launchd（仅 darwin）：LAUNCH_JOBKEY_LABEL 或 XPC_SERVICE_NAME（非空且非 "0"）→ `launchctl bootout gui/$(id -u)/'<label>'` + 删 LaunchAgents plist；三者按 PM2→systemd→launchd 顺序。

### daemon turnTriggerTrace

- 唤醒 turn 的触发属性（T4 端到端唤醒延迟）：只输出 kind 与毫秒数，无 id/内容。`triggerAgeMs` = turn start − 批次内最老触发的创建时间（消息用 Server 时钟，负值保留不截 0；本地 mint 的 app inbox 项同钟）；`localWaitMs` = turn start − 本机收到最老触发的时间（本地钟，免疫时钟偏移，且下限 0）。
- 消息：空 → other；任一 mention → mention；全部 sender_type=third_party_app → app；否则 message。app inbox：取 createdAtMs 最小项（缺省视为无穷）的 appId 映射 reminder（system.reminder）/wake_hint（system.cleaner）/app；mint 即接收。

### daemon runtimeModels/modelSourceCache

- 每个 runtime 的模型列表 stale-while-revalidate：live 列表缓存 60s（fresh 命中不探测）；过期则立即返回旧列表并单飞后台刷新（stale）；无可用条目则前台等待（miss）；force 绕过缓存等待（forced）并重新缓存。
- 只缓存 live；确定性非 live（未登录/无配置/无模型/未安装/不支持）删除条目；瞬时失败（retryable 且 code 缺省/detect_timeout/detect_failed，或 runtime_not_found 且 reason 非 not_installed）保留旧列表；connect 时 push 的 store() 同样预热；各 runtime 独立；确认缺失（not_installed 或无 reason）删除。

### daemon raftHome

- Raft home 单一规则：`$RAFT_HOME`（trim 后非空）优先于 `$SLOCK_HOME`；都未设时 `~/.slock` 已含 Raft 状态（agents/computer/machines/profiles/agent-state 任一存在）则用它，否则 `~/.raft`；只有 notice 文件的 `~/.slock` 不算。返回值规范化为绝对路径；`resolvePath` 拼接子路径。
- 自定义 home 时，`listLegacyStatePaths` 报告默认根下已存在的 agents/machines/attachments（带 destination 与描述）供迁移提示；默认 home 时为空。
- 非移植用例：上游「全仓源码不得硬编码默认 home」的源码扫描不适用于本移植（PARITY 已注明）。

### daemon drivers/nodeHostLaunch

- Node host 分类：先看 Electron（Electron 构建绝不是 SEA）；再跑 SEA 探针（注入的 execIsSea 或 seaProbe；`node:sea` 缺失/MODULE_NOT_FOUND/ERR_UNKNOWN_BUILTIN_MODULE 才是「非 SEA」证据，其它错误是「无法回答」→ unknown）；非 SEA 时 node 必须是正向判定（有 node runtime 信号），否则 unknown。
- 启动解析：Electron → 同一 executable + `ELECTRON_RUN_AS_NODE=1` 且保留其余 env；纯 Node → executable 与 env 原样；SEA → 抛带 `node_host_unavailable`/hostKind 的具名能力错误（绝不回退 execPath）；unknown → 同样 fail-closed。

### daemon runtimeAccountUsage/oarAdapter

- OAR 快照 → wire（protocolVersion 2）：身份在边界 mask（保留首 1–3 字符 + `****` + 可选尾 0–5 字符 + 小写 domain，无法 mask 的 email 直接丢弃，原值绝不出现）；plan/displayName 走 safeLabel（trim、1–80、无控制字符；有 maskedLabel 时不带 displayName）。
- 窗口：label 缺省为 "Usage limit"；`usedRatio` 非有限或越界 [0,1] → `parse_unavailable`（不带 usedRatio）并置 `parseErrorCode=oar_window_ratio_unreadable`；ratio≥1 → `limit_reached`，否则 ok；resetsAt 规范化为带毫秒 ISO，无法解析即缺省；rateLimited → health `rate_limited`；超过 wire 上限 12 个窗口 → health `error` 且无窗口（绝不截断）；unsupported/reauth_required → 无窗口。
- accountKey = sha256(provider + NUL + localAccountSlot) hex（provider 作用域、不泄露本地 slot）；读取失败 → health `error`、无窗口（绝不表示 0 用量）。

### daemon runtimeAccountUsage/collector

- 通过 OAR runtime 读取单 provider 账户用量并投影到 wire：installation 探针每次读恰好一次，available 时才把**同一个对象**交给 accountUsage；not_found/unsupported 或缺少 probe/reader → `unsupported`（结构性不可得）；读取抛错/超时 → `error` 且无窗口（绝不显示 0 用量）。
- Kimi 预刷新门禁（默认关闭）：开启时先按可用 installation 的 command 解析客户端 auth 并 ensureFresh；仅 rejected/revoked → `reauth_required`，transient 且 expired → `error`，其余 freshness（fresh/refreshed/adopted/missing/非过期 transient/platform_unsupported）都放行探针并保留 OAR 结果；关闭时不解析、不刷新、OAR 结果原样投影。
- collector 工厂按 provider 读取并把 now 注入 observedAt。
- 非移植用例：上游「每个 usage provider 路由到真实 OAR provider runtime」依赖未移植的 @botiverse/oar 实现（PARITY 已注明；工厂接线由本移植测试覆盖）。

### daemon runtimeAccountUsage/oarKimi

- Kimi 用量在 OAR 契约下的边界（测试-only 模块，现由 oarAdapter + collector 断言）：窗口百分比/resets 保持原值，account 身份 maskedLabel（`alpha@example.com`→`a****@example.com`）且原 email 不出现；无 email 的手机登录用 profile nickname（trim）作 displayName，有 maskedLabel 时不带 displayName；订阅窗口满但 Extra Usage 有余量时 health 仍 ok（满窗口 limit_reached、extra ok）；成功/失败读使用同一 provider-slot identity；无 reset 的百分比可用且无 parseErrorCode。
- collector 边界：installation 每次读探测一次且同一对象交给 reader；available/reauth_required/unsupported 分别投影；无 installation → unsupported 且绝不读 credentials；无关失败 → error 且错误文案不外泄（不引导重登）。

### daemon chatBridgeRequest

- 共享 chat-bridge HTTP 执行器：`executeJSON` 成功返回解析后的 JSON 与 duration；`executeResponse` 返回原始 body（二进制/文件流）。
- 本地超时：用本地 deadline 取消在途请求并记录结构化 `[ChatBridgeTimeout] tool=... target=... duration_ms=... timeout_ms=... outcome=timeout`，抛带 tool/target/timeout/duration 的 ChatBridgeToolTimeoutError。
- 状态优先：非 2xx 直接按 HTTP status 抛 HttpStatusError（HTML 错误页不会被误报为 JSON 解析错误）；JSON 错误体的 `error`（最多 300 字符）保留在 serverError 旁。

### daemon raftDiskJanitor

- 有界磁盘巡检：目录测量按 64 项一批扣预算（默认 200k 项 / 30s），只统计普通文件、不跟随 symlink；耗尽时 outcome 明确为 `truncated`/`timeout`（绝不当作完整小数值）；缺失目录为 0。
- 迁移代清理：`migrations/<migration>/<generation>` 含 `chunks`/`source-spool`/`extracting-*` 且最近活动（根与直接子项最大 mtime）早于 7 天 → 删除 bulk、保留 JSON 报告，返回释放字节。
- 备份保留：每个 agent 的 `migration-workspace-backups/<agent>/<backup>` 按 mtime 降序，保留前 3 且 mtime ≥ 30 天 cutoff；其余删除并逐条上报 owner/kind(preexisting|migration)/ageDays/freedBytes。
- footprint 分开统计 migrations / workspace backups / (cli-transport + agent-proxy-tokens)，并带 measure outcome；定时器初始 10 分钟后、此后每 24 小时跑一次，pass 不重叠（结束才重新 arm），stop 清定时器。

### daemon runtimeNotificationState

- 忙碌 stdin 通知状态：pending debt（自上次发送尝试起累计、与 inbox 长度无关，支持 add/remove/clearPending）与至多一个定时器分开管理；takePendingAndClearTimer 取走计数并清定时器；clear 同时清 pending/timer/fingerprint。
- inbox notice fingerprint：按消息身份取集合键（seq 优先，否则 message_id/id），排序后用逗号连接（`s:11,s:9` 字典序），空集为空串；同计数但集合变化（读一条+新一条）产生不同 fingerprint。
- 去重 memo：仅抑制**同 session** 且完全相同的已写 fingerprint（空指纹永不抑制）；recordNoticeWritten 记录贡献身份集合，filterUncontributedMessages 只过滤同 session 已贡献的已识别消息，pruneContributedToPending 让已消费行可再次出现。
- failed-encode memo：仅抑制同 session 相同 fingerprint 的失败尝试（空不记）；成功写入清除失败 memo；clear 清空两类 memo。

### daemon agentInboxProjection

- 收件箱投影按 target 分组待处理消息（不含正文）：thread → `#parent:8hex` 或 `dm:@parent:8hex`，dm → `dm:@peer`，channel → `#name`；行含 pendingCount、first/latest msg 与 seq、latestSenderName/Type、flags（thread/dm/task/mention/non_member_mention，字典序）。
- flags 渲染：mention → "you were mentioned"；non_member_mention → 固定非成员回复指引文本；未知 flag 用 JSON 引号转义并截断 40 字符显示；third-party 分组 target 显示为 "Third-party app events"、过滤 dm flag 并追加 "fetch with raft message check"。
- 格式化：snapshot 头区分 pending targets 与 suppressed-only targets；delta 头用 "pending your read across all conversations"（不用 unread），空行为 "Inbox update: no pending targets"；attention_hint 按 schema/trigger/scope/suggested_command/copy/copy_version/epoch_ms/thresholds 紧凑 JSON 输出。
- 抑制计数为旁路参数：仅正整数有效（Infinity/小数/负数/NaN 丢弃），全部被抑制的 target 仍产生 pendingCount=0 的行；省略该参数与传空 map 结果一致。

### daemon contextGeneration

- RFC 072 §7.2 上下文代信号：spawn/compaction 写入新 `context-id`（`<transportDir>/context-generation`，JSON、0600、原子 rename）；resume 复用该 session 上次的 id（agent 级 `sessions.json` 表，最多 32 条，按 updatedAt 保新）。
- 失败方向安全：写前先删旧文件；写/rename 失败清理 tmp 并把 generation 文件清掉（绝不留下可被 CLI 匹配的旧 id）；表写失败删除整表（宁丢表也不复用 compaction 前 id）。
- 计划与发布分离：plan 只计算不落盘；bindToSession 在 runtime 报告的 session 与 resume 目标不一致时先发布新 id（继承本次 spawn 的 passiveAx gate），再绑定 session→id；compaction 后重新绑定。
- `RUNTIME_REPORTS_COMPACTION` 为每个已注册 runtime 显式声明是否上报 compaction；configPassiveAx 仅显式 true 开启。

### daemon runtimeModels/oarListModels

- 经 OAR `listModels` 读取 runtime 可用模型并投影到既有 outcome：ok→live（保留 effort 菜单/默认 effort/service tier，`verified: launchable`），空列表或全部 disabled→no_models，unauthenticated→retryable `runtime_not_authenticated`，unsupported 交调用方决定（携带 OAR reason），listing 抛错→retryable 无 code。
- 截止时间：本地 deadline 先到→retryable `detect_timeout`；传给 lister 的 timeout 始终大于本地 deadline（本地 deadline 决定结果）；deadline 只停止等待，listing 继续跑到自身 timeout。
- 单飞：同一 lister 上仍在跑的 listing 被后续请求 join（不会并发发起第二个）；settle 后下一次请求才启动新 listing。
- 投影去重 id、丢弃 disabled；runtime 无法应用 effort 时丢弃 effort 字段。
- 注：上游 13 例中 3 例（opencode 安装形态/解析器对齐）依赖未移植的 opencode driver parser 与 provider label formatter，未计入（PARITY 注明）。

### daemon agentMigrationExport

- 迁移工作区扫描：未知文件默认全部迁移；只有明确工具生成的目录被列为 regenerable（third-party: node_modules/.venv/.terraform/.tox/vendor…；cache: __pycache__/.mypy_cache/.turbo/.gradle…；build: dist/target/.next/.nuxt/.svelte-kit），按类别统计；`build/` 不在白名单内，照常迁移。
- `.raftmigrateignore`：逐行精确路径（`#` 注释，含 `*?[]!` 的模式行跳过），仅可排除可重建/可重新下载的内容；MEMORY.md、ignore 文件自身、`.raft/activity` 及其父/子路径永不排除；被忽略目录递归统计 fileCount/sizeBytes。
- 不可读目录记入 `unreachable`（read_error），不中断扫描；`onEntry` 按名称顺序收到每个包含的文件路径。
- symlink target 归一化：拒绝绝对路径、Windows drive/UNC、NUL 与逃出 workspace 的目标（相对 link 目录解析），反斜杠转 `/`；`../target-file` 允许。
- summary：included 计数/字节、regenerable 计数与四类分布、MEMORY.md/notes/ 存在性；只有存在被忽略路径时才输出 excludedIgnored（count/fileCount/bytes/largest≤5），否则省略以兼容旧 server。
- 注：排序采用与 Node `localeCompare` 一致的口径（`_` 先于 `.`、字母忽略大小写）。

### daemon scopedAppStorage

- 平台拥有的按 (machine, server, app, agent) 作用域存储：`<home>/app-storage/v1/<machine>/<server>/<app>/{computer|agents/<agent>}/state.json`；同一 App/Agent 在不同 Server、同一 Server 下不同 Agent 互相隔离。
- 能力对象仅暴露 readText/writeTextAtomic/assertActive/reportDataFailure；写入 tmp(0600)+rename，目录 0700，失败清理 tmp，不残留 `.tmp`。
- 失败事件为隐私安全类型：operation(access/read/write/decode/legacy_quarantine)、store(app_state/legacy_unscoped)、appId、serverId、writerEpoch、outcome、reason（permission_denied/path_missing/lock_contention/storage_io/unknown/capability_revoked/invalid_payload）；不含路径、payload、agent id。
- revoke 后已发放能力与 factory.open 全部拒绝（每个入口一条 access/capability_revoked 事件）。
- decode 失败以读取代际为 failureInstanceId：首次 edge、同代重复 level；原子重写后下一次 decode 产生新代新 edge。
- legacy 文件隔离到 `app-storage-quarantine/v1/unscoped/<uuid>-<leaf>`；第二次为 absent；目录创建/移动失败发一条 legacy_quarantine 事件并 rethrow。
- scope 身份与 legacy 相对路径在构造路径前 fail closed（invalid/escapes root）。

### daemon runtimeErrorDiagnostics

- provider 错误分类（闭集）：Launcher → InputTooLarge → OperationAborted → INPUT_TOO_LARGE/too large/exceeds maximum/（max context + requested）→ Billing（402 或余额措辞，先于状态映射）→ plan-access（ModelConfigError）→ 显式 `*Error` 类 → HTTP 状态（429 RateLimit、401 Auth、403 需显式 auth 证据、404 NotFound、≥500 ProviderServer、其余 ProviderApi）→ auth 措辞 → model-not-supported/not-available → timeout → connection → stream → capacity/rate-limit → not found → RuntimeError。
- 动作：AuthError → `user_reauth`；仅 plan-without-model 的 ModelConfigError → `user_model_access`；其余 `none`。瞬时限流标记（rate limit/too many requests/concurrency/retry/later/resets/at capacity/…）否决 plan-access。
- 脱敏：Bearer/sk-*/xox*/email/URL query（保留 scheme/host/path）/Users|/home|Windows 用户路径；secret-shaped 键赋值保留 key、redact value（不误伤 NODE_ENV=production）；generic password/secret/token；ghp/gho/ghs/ghu/ghr 与 github_pat_ → `[REDACTED_TOKEN]`；excerpt 上限 4096 并标记 truncated。
- 诊断：fingerprint = lowercased、hex→`<hex>`、数字→`<num>`、空白归一后的 sha256 前 16 位；length bucket 0/<1k/1k-4k/4k-16k/16k+；InputTooLarge 附加 estimated/budget/context-limit/requested/message/completion/overage/model 计数（仅当 requested>limit 时 overage）。
- ActivityDiagnostic：保留精确 class/reason（显式 errorClass 优先）、fingerprint、reasonProvenance，requiredAction 仅在非 none 时出现；不含原始文本。
- 文案：login-required（builtin/pi/其余 runtime 名称）、start-timeout、input-too-large（grok/pi/builtin 指向 Reset Session & Restart，其余提示 compact）、billing-exhausted、plan-access（含模型名，非登录）。

### daemon skillFrontmatter

- SKILL.md frontmatter 只解析扁平 YAML 子集：`key: plain`（去 ` #` 尾注释）、双引号（`\"`/`\\` 反转义）、单引号（`''`→`'`）、literal `|`、folded `>` 及 `-`/`+` chomping 与显式缩进指示符（1–9；0/两位数视为非法并 fail closed）。
- block scalar 保真：`|-` 无尾随换行、`|` 恰好一个、`|+` 每个尾部空行一个；folded 中单换行折为空格、k 个空行产生 k 个换行、更多缩进行保留两侧换行（前置空行叠加结构换行）；行首空行是内容。
- 不支持语法（anchor/alias/tag/flow collection/复杂键/保留指示符 `@` `` ` `` `%`/序列项/未闭合引号/畸形 block header/嵌套 mapping）一律 fail closed 为空串；失败不影响其余键解析。
- 结构层级仅由“可承载 key 的行”决定（注释、空行、无冒号行不参与），嵌套子键不会提升为顶层元数据；block body 中的 `key: value` 不被当作键；全部缩进的文档仍可解析。
- CRLF 与 LF 解析结果一致；无 frontmatter 返回空 map；重复 key 后者覆盖。

### socket desktopAttentionEvents

- `desktop:attention { attended: true|false }` 仅 Raft Desktop socket 接收：web/mobile/cli 即使发送也不会改变任何人的通知状态。
- `{attended:true}` 记录该 socket 自身 user 的“桌面在场”（忽略 payload 中的 userId 等其他键），同一 socket 30s 内重复上报被丢弃；`{attended:false}`（空闲/锁屏）立即清除该 user 的记录，并把 record 节流重置为立即可记录；恢复上报不受 30s 限制。
- 非法 payload（非对象、attended 非布尔、缺 attended）一律忽略；record/clear 失败不外抛（只记日志），回到“记录自然过期”的安全状态。
- 记录存放在 `DesktopAttentionRegistry`（本移植以内存实现 Redis 服务的可观测抑制状态）。

### socket desktopAttention.api

- 真实 socket 端到端：desktop 连接发送 `desktop:attention {attended:true}` 后，该 user 在 `DESKTOP_ATTENTION_WINDOW_MS`（10 分钟，固定不可配置）内被记为“桌面在场”；同一时刻 web 连接发送同样事件不产生记录（浏览器不能压制自己的通知）。
- `{attended:false}` 立即清除该 user（不等 TTL），浏览器推送恢复；`DesktopAttentionRegistry.usersWithRecentDesktopAttention([...])` 只返回窗口内仍有效的 user，读失败时失败开放（不压制任何人）。
- 记录以内存实现 Redis TTL 的可观测语义，`resetForTests()` 支持清空。

### route App setup contract（appSetup.api 切片基础）

- 声明校验：`setupUrl` 必须为 HTTPS（或 loopback HTTP），无 userinfo、无 fragment，长度 ≤2000；空值视为未声明（`not_required`）。`setupDescription` 必须单行、无控制字符、≤500 字符。
- 状态投影：`project` 把 `installation_id`、`server_id`、`setup_revision` 作为精确上下文附加到 URL（覆盖输入中同名参数，保留其它参数），`status = completedRevision == setupRevision ? complete : pending`；完成时间仅在 complete 时输出 ISO UTC；无 setupUrl 时 `not_required`、url/description/completedAt 均为空。
- `installation_id` 必须是安装 UUID，否则 fail closed（防止路径/身份注入）。
- 该契约将用于 `appSetup.api` 的 GET clients/:clientId/setup、PUT installations/:id/setup、PATCH client 声明与安装卡片绑定。

### route App setup ledger 模型（appSetup.api 切片基础二）

- Client 记录新增 `setupUrl/setupDescription/setupRevision`（创建时校验并归一化，默认 revision 1）；Installation 记录新增 `setupCompletedRevision/setupCompletedAt`。
- 声明更新：setup URL 变化 → revision+1 并清空该 App 所有安装的完成状态；仅 description 措辞变化不升 revision、不要求重新配置。
- 读取 setup：仅 enabled client + active installation；无 setupUrl → `not_required`；有则按契约附加 installation_id/server_id/setup_revision 并返回 pending/complete。
- 上报 setup：仅 App 自身（clientRecordId）+ active installation；`revision != setupRevision` 或无 setupUrl → 409 语义冲突；complete/pending 幂等（重复上报不重复审计），审计事件 `installation.setup_updated` 可计数。
- 卸载删除 active installation；重新安装生成新 installation id 且 setup 回到 pending。

### route App setup HTTP 面（appSetup.api 切片基础三）

- `GET /api/integrations/clients/:clientId/setup`：需 server member；enabled client + active installation 才 200，否则 404；响应 `status/url/description/revision/completedAt/canConfigure` 且 `Cache-Control: no-store`；仅 owner/admin 看到 url/description（member 看到 url=null、canConfigure=false）。
- `PATCH /api/integrations/clients/:clientId`：source server owner/admin 才能改声明；setupUrl/setupDescription 校验失败 400；setup URL 变化 bump revision 并清空完成态。
- `PUT /api/oauth/installations/:installationId/setup`：clientId+clientSecret App 认证（人类登录 401）；status 必须 pending/complete；revision 不匹配或无 setupUrl → 409；active installation 不存在/不属该 App → 404；幂等（重复 complete 不重复审计）。
- `POST/DELETE /api/integrations/marketplace/:clientId/install`：owner/admin 在目标 Server 安装/卸载 marketplace App（record id 可直接解析）；卸载后 setup 读取与上报均为 404；重装生成新 installation。

### route Agent integrations 的 setup 投影（appSetup.api 基础四）

- `GET /internal/agent-api/integrations` 的 services 现在包含已安装到该 Server 的 marketplace App（不仅本 Server 自建 App）；每个 service 在有 active installation 时带 `setup{status,url,description,revision}`，url 携带目标 Server 的 installation_id/server_id/setup_revision。
- 发布方 Server 的 setup 完成不算目标 Server 完成（各自 installation 独立）。
- `integrations/app/update` 接受 `setupUrl/setupDescription`：setup URL 变化 bump declaration revision 并清空完成态；非法 URL/描述 400 INVALID_APP_METADATA。
- `integrations/app/status` 的 app 投影包含 `setupUrl/setupDescription/setupRevision/setup{status,url,description,revision,completedAt}`。

### route appSetup.api（锁定）

- 安装 setup 卡片：`prepare-action` 支持 `integration:install_marketplace_app`；卡片 action 携带 **canonical** `setupUrl/setupRevision`（忽略请求里的伪造值）；执行时若 App 声明 revision/url 已变化 → 409 `APP_SETUP_CHANGED`，不安装；成功 result 的 `setupUrl` 为目标 Server 带 `installation_id/server_id/setup_revision` 的上下文 URL。
- 注册卡片：`prepare-action` 支持 `integration:register_app`，准备阶段校验 setupUrl（HTTPS/loopback、无凭据/片段、≤2000）与单行 setupDescription（≤500、无控制字符），非法 → 400 `INVALID_APP_METADATA`；执行时把声明写入新建 client。
- 上传报告仅接受 App 凭据：带人类 Bearer 的 PUT setup 报告返回 401。
- 人类读取按角色：member 可读 status 但 url=null/canConfigure=false；owner/admin 可见 url；suspended installation → 404。
- 上游 6 条 appSetup 断言由 `AppSetupRoutesTests`/`AppSetupLedgerTests`/`AppSetupAgentProjectionTests`/`AppSetupCardTests` 覆盖。

### route Agent App access（grant 核心，agentAppAccess.api 进行中）

- `POST /api/oauth/requests/agent` 自动授权策略：App 所有者对 Agent 有权限（Agent creator 或 Server owner/admin）→ 自动创建 `app_request` grant 并返回 approved；`initiatedByAgent:true` → `agent_login` grant（无需人对 agent 的权限）；其他情况返回 pending。已存在 active grant 时直接 approved 且复用，不重复创建。
- 人撤销 grant（`POST /api/integrations/grants/:id/revoke`）→ 该 grant revoked 并写入 auto-grant block；之后 app 请求与 agent 登录都变为 pending，直到人重新授权。
- 人的授权（`POST /api/integrations/agents/:id/grants`）→ 201 新建 person grant 并清除 block；已存在 active grant 时 200 复用。权限仅 Agent creator 或 Server owner/admin；scope 必须非空且是 App allowedScopes 子集（否则 400）；App 必须在目标 Server 可用（否则 404）。
- 管理面：`GET /api/integrations/agents/:id/grants`（仅管理权限可见，普通 member 看到空）、`GET .../grantable-apps`（管理权限 200 列表；普通 member 403）；`approve`（`POST /api/integrations/requests/:id/approve`）仅 Agent creator 或 owner/admin，remember 时落地 person grant。
- `requests/agent` 接受 `agentId`（优先于 agentName）；非法/不存在/外服 id → 404。

### route agentAppAccess.api（锁定）

- `GET /api/integrations/agents/:id/events`：仅 Agent creator 或 Server owner/admin 可读（普通 member 403），事件按 createdAt 倒序、tie 用 id 倒序；`limit` 必须 1–100（0/非法 400）；`before` 为不透明 cursor（毫秒时间戳 + 事件 id），非法 400；`nextCursor` 在还有下一页时返回，否则 null。
- 事件状态显示：`delivered` 保持 delivered；`expired`/`rejected` → expired；其余若 `expiresAt <= now` → expired，否则 queued。
- 事件 summary 含 id/kind/summary/status/createdAt/expiresAt/deliveredAt/externalEventId/app{clientKey,clientName,logoUrl:null}；detail 额外返回解析后的 `payload`。
- 另一 Agent 的事件 id 与不存在 id 一律 404。
- `pruneExpiredAgentAppEvents(now:batchSize:)`：只删除 `expiresAt <= now - 30d` 的事件，按 expiresAt 升序、最多 batchSize 条；保留窗口内事件不动。
- 上游 6 条断言由 `AgentAppAccessTests`（4）与 `AgentAppEventListTests`（2）覆盖。

### route pending social link（核心，authPendingSocialLink.api 进行中）

- 一次性 pending social link：包含 provider、providerUserId、规范化 email、returnTo/returnUri、expiresAt；`cancel` 幂等（重复 204），取消/过期/已用后不可再用。
- 密码登录携带 `pendingLinkToken`：token 无效/取消/过期/已用 → 410 `pending_link_expired`；email 与 token 归属不符 → 403 `pending_link_account_mismatch`（不发 session）；密码错误 → 401 `AUTH_INVALID_CREDENTIALS`（token 仍可用）；成功 → 建立 session、一次性消费 token、写入 provider identity，响应含 `linkedProvider`。
- 成功消费后 replay → 410，且不产生第二个 session。

### route pending social link（web 冲突与 provider 完成，进行中）

- web 登录 callback 现在建立 completion：已存在 email 且该 provider 未链接时，`linkOnConflict=1` → 返回 completion code（非错误重定向）；未开启 → 旧错误重定向 “An account with this email already exists…”，且不建立任何 completion/pending 状态。
- `POST /api/auth/:provider/complete` 对 link-conflict completion 返回 409 `account_link_required`：`pendingLinkToken`、provider、email、expiresAt、`signInMethods{password,providers}`、returnTo；此路径在首次登录法律条款校验之前处理，不发 session、不写 identity。
- provider 完成携带 `pendingLinkToken`：校验“当前 provider 身份所属账户 == pending link 账户”，不符 → 403 `pending_link_account_mismatch` 且不消费 completion code；相符 → 一次性消费 token、链接 pending provider identity、发 session，响应 `linkedProvider` 为 pending provider。
- web 冲突 completion 的 `linkOnConflict` 通过签名 state 传递并在 verify 时还原。

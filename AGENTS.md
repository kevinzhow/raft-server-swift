# 继续复刻

等价复刻 raft-source `v1.21.23-source.1` 的 server 与 daemon。规格是 Node 测试里对外可见的状态码、JSON、响应头和套接字帧。大约完成 **60%**：daemon 与 server 基础面已落地，server 路由还在逐条补。这不是完成。

## 怎么接着做

一次只补一条 Node 断言过的路由。先写会失败的 Swift 测试，测试必须打到已发布的真实路径，再做最小实现。行为已经存在时，新测试只锁住它。Node 断言优先。

不要移植私有辅助函数、别的 package、查询次数 spy、tracer sink、failpoint、编排器注入，除非 HTTP 状态或 JSON 本身就是断言，并且不靠 spy 就能打到。

`make test` 使用 `/mnt/data/opt/swift-6.4.1-RELEASE-ubuntu26.04`。系统 `/usr/bin/swift` 是 6.1.3，不要用它。单条测试：

```sh
/mnt/data/opt/swift-6.4.1-RELEASE-ubuntu26.04/usr/bin/swift test --filter <TestName>
```

改完跑目标测试，再跑 `make test`。全量通过只说明已经移植的切片是绿的。行为还没补齐时，不要把这次日志当成完成门槛，也不要把它写成 `{SCRATCH}/make-test.log`。

最近一次全量日志：`/tmp/progress-analysis/make-test-app-retirement.log`，`PIPE:0`。347 个测试：RaftHTTP 34、HTTP 路由 219、daemon 71、`/daemon/connect` 鉴权 17、机器套接字 6。

## 已完成

- Daemon：`/daemon/connect` 仍在 SwiftNIO 上，不要挪到 Vapor。拒绝字节不含 api key；接受是 101、`raft-server-capabilities`、一帧 `machine:context`。重连、4003 长延迟、`legacy_machine_key_migrated` 停止重试、70s ping、断线期间每个 agent 只留最新 activity/status/invalidate、代理选择、连接池回收、CONNECT/headers/body 超时，都有 Swift 测试。
- Server 基础面在真实 `RaftServer` 入口上：`/robots.txt`、`/livez`、`/health`、`GET /api/version`、JSON 404、CORS 预检。每条响应带 `X-Robots-Tag: noindex, nofollow`，预检除外。没有数据库时进程 `/health` 是 503 `{"status":"error","detail":"database unreachable"}`。`/api/version` 缺发布身份是 503 `build_identity_unavailable`；`RAFT_RELEASE_SHA`、`RAFT_BUILD_AT`、`RAFT_RELEASE_BRANCH` 齐全时是 200，`version` 是 `1.21.23`。
- 路由切片已经写到 `packages/server/src/routes/oauth.api.test.ts` 的安装令牌签发。149 个 `*.api.test.ts` 里，按文件名走到第 96 个。这个文件只完成了下面几条，后面 53 个文件还没开始。更早的文件里，spy 和 failpoint 按上面的规则跳过了。
- 已锁住的 OAuth：`GET /api/oauth/.well-known/openid-configuration` 的公开 scope；`POST /api/oauth/authorize/human` 签发一次性 code；`POST /api/oauth/token` 的 form、camelCase JSON 和 Basic 都是 200，含 `access_token`、`Bearer`、`expires_in`、`scope`，有 `openid` 时有 `id_token`；超过 10 分钟的 code 是 400 `authorization_code_expired`，`next_action` 是 `obtain_fresh_authorization`，不签发 token；`POST /api/oauth/installation-token` 对活跃安装回 200，`Cache-Control: private, no-store`，令牌前缀 `raft_installation_`，`expires_in` 600；安装令牌打 `GET /api/oauth/userinfo` 和 `GET /api/oauth/agents` 都是 401，`/agents` 的 JSON 里没有 `agents`。
- 安装投影已经挂到 `RaftHTTP`：用户会话打 `GET /api/app-installation/server` 是 401；安装令牌打同一地址是 200，`Cache-Control: private, no-store`，`installation_id` 与 `server.id` 对得上；缺 `channel` 组的令牌打 `/api/app-installation/channels` 是 403。凭证每次重判 App 类别、安装状态、grant revision 和当前有效组。App 被收成 `slock_builtin` 或登记了平台身份后，旧安装令牌读投影是 401，重新签发是 401 且不新增令牌行。

README 里「没有 `acceptTerms: true`」之前的长段是按切片追加的行为说明。继续时在那句前面加一句，不要改掉更早的句子。

## 下一条

`oauth.api.test.ts` 的 “installation credentials and principal credentials are mutually rejected” 已经整条锁住。下一条是 “App client credentials discover only their active installation on an exact Server”：

1. `POST /api/oauth/installations/lookup` 用 Basic 客户端凭证和 `server_id` 找到该 Server 上的活跃安装，回 200、`Cache-Control: private, no-store`，正文是 `installation_id`、`server_id` 和 `setup`（`status` 是 `not_required`，`url`、`description`、`completedAt` 是 null，`revision` 1）。
2. 同一路径挂在 `/oidc/:server/api/oauth/...` 下不在 scoped 路由里，应 404。

同一文件里先跳过、不要补的：像素头像渲染单测；只打 `authenticateOAuthClient` 的 `slock_secret_` 旧密钥；换票抛错时的日志和审计脱敏（spy）。审计表断言不要单独移植。

源码在 `/mnt/data/tmp/grok/raft-source-v1.21.23/`，标签 `v1.21.23-source.1`。OAuth 账本是 `Sources/RaftHTTP/OAuthLedger.swift`，路由在 `Sources/RaftHTTPServer/FallbackApplication.swift`。

## 标识

下一次新用户从 `11111111-1111-4111-8111-111111111201` 起，下一台服务器从 `33333333-3333-4333-8333-333333333393` 起。`...197`–`...200` 和 `...389`–`...392` 已用于安装令牌、principal 边界、安装投影与退役。

## 约束

- Vapor 钉在 `0f2a8ee9f38b2589c066b604de3e3168ed54c82d`。不要改成 `branch: main`，不要手改 `Package.resolved`。beta.1 和 beta.2 在这套 Swift 上编不过。
- 全量 `make test` 里偶发的 signal 6 或 11，如果隔离的测试运行器通过，就再跑一次全量。用 `tee` 时退出码取 `PIPESTATUS[0]`。
- 两次真实 `RaftServer` 启动，以及完成门槛日志，留到 Node 断言过的 daemon 和 server 行为都没有缺口之后。没有数据库时 `/health` 必须仍是上面的 503 JSON。
- 不要为了收尾去勾计划清单，也不要提交，除非用户明确要求。

# 继续复刻

等价复刻 raft-source `v1.21.23-source.1` 的 server 与 daemon。规格是 Node 测试里对外可见的状态码、JSON、响应头和套接字帧。daemon 与 server 基础面已落地，server 路由还在逐条补。这不是完成。

## 怎么接着做

一次只补一条 Node 断言过的路由。先写会失败的 Swift 测试，测试必须打到已发布的真实路径，再做最小实现。行为已经存在时，新测试只锁住它。Node 断言优先。

不要移植私有辅助函数、别的 package、查询次数 spy、tracer sink、failpoint、编排器注入，除非 HTTP 状态或 JSON 本身就是断言，并且不靠 spy 就能打到。

测试和提交：

- `make test` 使用 `/mnt/data/opt/swift-6.4.1-RELEASE-ubuntu26.04`；系统 `/usr/bin/swift` 是 6.1.3，不要用它。
- 单条测试：`swift test --filter <TestName>`。
- 改完先跑目标测试，再跑 `make test`；全绿才提交。
- 一个功能切片一个 commit，不按文件或半成品拆。提交信息用一句祈使句标题，正文写这个切片锁住的行为。
- 全量里偶发 signal 6 或 11，隔离测试通过就再跑一次。用 `tee` 时退出码取 `PIPESTATUS[0]`。

## 约束

- Vapor 钉在 `0f2a8ee9f38b2589c066b604de3e3168ed54c82d`。不要改成 `branch: main`，不要手改 `Package.resolved`。
- `/daemon/connect` 留在 SwiftNIO，不要挪到 Vapor。
- 没有数据库时进程 `/health` 仍是 503 `{"status":"error","detail":"database unreachable"}`。
- 两次真实 `RaftServer` 启动和完成门槛日志，留到 Node 断言过的 daemon 和 server 行为都没有缺口之后。

## 文档

README 记已经锁住的行为；进度看 commit 历史。不要在 AGENTS.md 里追加逐条开发过程。

## 标识

下一次新用户从 `11111111-1111-4111-8111-111111111468` 起，下一台服务器从 `33333333-3333-4333-8333-333333333577` 起。

## 源码

`/mnt/data/tmp/grok/raft-source-v1.21.23/`，标签 `v1.21.23-source.1`。OAuth 账本在 `Sources/RaftHTTP/OAuthLedger.swift`，路由在 `Sources/RaftHTTPServer/FallbackApplication.swift`。

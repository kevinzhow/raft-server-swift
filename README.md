# raft-server-swift

等价复刻 [raft-source](https://github.com/botiverse/raft-source) `v1.21.23-source.1` 的 server 与 daemon。

规格是现有测试里对外可见的行为。Swift 测试先写这些断言，再写实现。Node 测试断言的行为优先，直到那条行为本身被改掉。

工具链：`/mnt/data/opt/swift-6.4.1-RELEASE-ubuntu26.04`（Swift 6.4.1）。系统的 `/usr/bin/swift` 仍是 6.1.3，本仓库用 `make test`。

当前切片：`/daemon/connect` 和只读 HTTP。鉴权决策在 `RaftConnectAuth`，SwiftNIO 监听在 `RaftMachineSocket`。拒绝时写出和 Node 相同的 401/500 字节；接受时回 101、`raft-server-capabilities`，再发一帧 `machine:context`。`RaftDaemonClient` 按 `packages/daemon/src/connection.ts` 完成客户端握手：默认 `Authorization: Bearer`，也可走旧的 `?key=`；拒绝时交出状态码和 `Slock-Reason`，错误文本不含 api key；101 时读能力头和第一帧 `machine:context`。`DaemonLink` 是同一处的重连循环，由调用方推进时钟，不打开套接字：退避从 1s 加倍到 30s，成功打开后回到起点；默认抖动铺在至少 5s 的窗口上；4003 的重复连接等 5 分钟，被关掉后的 30 分钟内再次被拒仍走长延迟；401 `legacy_machine_key_migrated` 停止重试；入站看门狗 70s 先发 `ping`，再过 70s 才断开。断线期间每个 agent 只留最新的 `agent:activity`、`agent:status` 和 `agent:session:invalidate`：失效帧在重新打开时先写出，status 和 activity 等这根套接字上的 `ready` 之后按 `clientSeq` 重放。代理和 TLS 还没移植。

`RaftHTTP` 按 `app.ts` 给出 `/robots.txt`、`/livez`、`/health` 和 JSON 404，每条响应都带 `X-Robots-Tag: noindex, nofollow`。`/health` 的数据库探测是注入的；`/livez` 不在请求路径上探测。这些函数还没有挂到 Vapor 进程上。

Vapor `5.0.0-beta.1`（`bce76e99119568a3c782b76bcf4c9891f757fdbe`）在本机 Swift 6.4.1 上还编不过。那个 tag 用 revision 依赖 `swift-http-server`，后者把 `swift-http-api-proposal` 限制在 0.2.x，而 0.2.1 在 Swift 6.4 的 `MemberImportVisibility` 下缺 `SpanPreview`。等上游能编过再挂进程。

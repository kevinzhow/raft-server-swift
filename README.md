# raft-server-swift

等价复刻 [raft-source](https://github.com/botiverse/raft-source) `v1.21.23-source.1` 的 server 与 daemon。

规格是现有测试里对外可见的行为。Swift 测试先写这些断言，再写实现。Node 测试断言的行为优先，直到那条行为本身被改掉。

工具链：`/mnt/data/opt/swift-6.4.1-RELEASE-ubuntu26.04`（Swift 6.4.1）。系统的 `/usr/bin/swift` 仍是 6.1.3，本仓库用 `make test`。

当前切片：`/daemon/connect`。鉴权决策在 `RaftConnectAuth`，SwiftNIO 监听在 `RaftMachineSocket`。拒绝时写出和 Node 相同的 401/500 字节；接受时回 101、`raft-server-capabilities`，再发一帧 `machine:context`。

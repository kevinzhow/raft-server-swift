import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import RaftConnectAuth
import Testing
@testable import RaftMachineSocket

private struct QueryWireCredential: MachineCredentialLooking {
    func findComputer(apiKey: String) async throws -> ComputerAuthResolution { .linked(computerId: "query-computer", machineId: "query-machine") }
    func machine(id: String) async throws -> MatchedMachine? { .init(id: "query-machine", serverId: "query-server") }
    func serverExists(id: String) async throws -> Bool { true }
    func machine(apiKey: String) async throws -> MatchedMachine? { nil }
}

/// Actual TCP/RFC6455 frames; compatibility transport only. The production PG
/// acceptance exercises the committed consumer. No probe callback/sink is used.
@Test func machineQueryWireUsesExactNodeEnvelopesAndCancelsPending() async throws {
    let registry = MachineCommandRegistry()
    let server = try await MachineConnectServer.start(lookup: QueryWireCredential(), commandRegistry: registry)
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    do {
        typealias Socket = NIOAsyncChannel<WebSocketFrame, WebSocketFrame>
        let upgrade: EventLoopFuture<Socket> = try await ClientBootstrap(group: group).connectTimeout(.seconds(2))
            .connect(host: "127.0.0.1", port: server.port) { channel in
                let deadline = channel.eventLoop.scheduleTask(in: .seconds(12)) { channel.close(promise: nil) }
                channel.closeFuture.whenComplete { _ in deadline.cancel() }
                let upgrader = NIOTypedWebSocketClientUpgrader<Socket>(maxFrameSize: 1_048_576) { channel, _ in
                    channel.eventLoop.makeCompletedFuture { try Socket(wrappingChannelSynchronously: channel) }
                }
                let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/daemon/connect",
                    headers: HTTPHeaders([("Host", "127.0.0.1:\(server.port)"), ("Authorization", "Bearer sk_computer_query_fixture")]))
                let options = NIOTypedHTTPClientUpgradeConfiguration(upgradeRequestHead: head, upgraders: [upgrader]) { channel in
                    channel.close().flatMapThrowing { throw MachineCommandError.protocolViolation }
                }
                var pipeline = NIOUpgradableHTTPClientPipelineConfiguration(upgradeConfiguration: options)
                pipeline.leftOverBytesStrategy = .forwardBytes
                return channel.pipeline.configureUpgradableHTTPClientPipeline(configuration: pipeline)
            }
        let socket = try await upgrade.get()
        try await socket.executeThenClose { inbound, outbound in
            var input = inbound.makeAsyncIterator()
            let context = try #require(try await input.next())
            let info = try #require(try JSONSerialization.jsonObject(with: Data(context.unmaskedData.readableBytesView)) as? [String: Any])
            let epoch = try #require(info["connectionEpochId"] as? String)
            try await outbound.write(WebSocketFrame(fin: true, opcode: .text, maskKey: .random(), data: ByteBuffer(string: #"{"type":"ping"}"#)))
            _ = try #require(try await input.next())
            let pending = Task { try await registry.query(.runtimeModels(runtime: "codex", force: false), machineId: "query-machine", serverId: "query-server", expectedConnectionEpochId: epoch) }
            let request = try #require(try await input.next())
            let fields = try #require(try JSONSerialization.jsonObject(with: Data(request.unmaskedData.readableBytesView)) as? [String: Any])
            #expect(Set(fields.keys) == Set(["type", "requestId", "runtime"]))
            #expect(fields["type"] as? String == "machine:runtime_models:detect")
            let id = try #require(fields["requestId"] as? String)
            struct Result: Encodable { let type = "machine:runtime_models:result"; let requestId: String; let models: [String] = [] }
            let response = try JSONEncoder().encode(Result(requestId: id))
            try await outbound.write(WebSocketFrame(fin: true, opcode: .text, maskKey: .random(), data: ByteBuffer(bytes: response)))
            #expect(try await pending.value.payload == response)
            let cancelled = Task { try await registry.query(.workspaceFiles(agentId: "agent", dirPath: "docs", includeHidden: true), machineId: "query-machine", serverId: "query-server", expectedConnectionEpochId: epoch) }
            let list = try #require(try await input.next())
            let listFields = try #require(try JSONSerialization.jsonObject(with: Data(list.unmaskedData.readableBytesView)) as? [String: Any])
            #expect(Set(listFields.keys) == Set(["type", "agentId", "dirPath", "includeHidden"]))
            #expect(listFields["type"] as? String == "agent:workspace:list")
            cancelled.cancel()
            await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
            let timed = Task { try await registry.query(.workspaceRead(agentId: "agent", path: "docs/notes.txt"), machineId: "query-machine", serverId: "query-server", expectedConnectionEpochId: epoch, timeout: .milliseconds(50)) }
            let read = try #require(try await input.next())
            let readFields = try #require(try JSONSerialization.jsonObject(with: Data(read.unmaskedData.readableBytesView)) as? [String: Any])
            #expect(Set(readFields.keys) == Set(["type", "agentId", "path", "requestId"]))
            await #expect(throws: MachineCommandError.timedOut) { _ = try await timed.value }
            await #expect(throws: MachineCommandError.machineOffline) {
                _ = try await registry.query(.runtimeModels(runtime: "codex", force: false), machineId: "query-machine", serverId: "query-server", expectedConnectionEpochId: "old-epoch")
            }
            let closing = Task { try await registry.query(.runtimeModels(runtime: "pi", force: true), machineId: "query-machine", serverId: "query-server", expectedConnectionEpochId: epoch) }
            _ = try #require(try await input.next())
            try await outbound.write(WebSocketFrame(fin: true, opcode: .connectionClose, maskKey: .random(), data: ByteBuffer()))
            await #expect(throws: MachineCommandError.disconnected) { _ = try await closing.value }
        }
        try await group.shutdownGracefully(); try await server.close()
    } catch {
        try? await group.shutdownGracefully(); try? await server.close(); throw error
    }
}

/// Legacy scan replies can cross sockets of the same daemon instance. Timeout,
/// cancellation and unknown identity cannot be healed by a socket epoch alone.
@Test func machineWorkspaceScanWireSerializesAndQuarantinesLegacyResults() async throws {
    let registry = MachineCommandRegistry()
    let server = try await MachineConnectServer.start(lookup: QueryWireCredential(), commandRegistry: registry)
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    typealias Socket = NIOAsyncChannel<WebSocketFrame, WebSocketFrame>
    func connect() async throws -> Socket {
        let upgrade: EventLoopFuture<Socket> = try await ClientBootstrap(group: group).connectTimeout(.seconds(2))
            .connect(host: "127.0.0.1", port: server.port) { channel in
                let deadline = channel.eventLoop.scheduleTask(in: .seconds(12)) { channel.close(promise: nil) }
                channel.closeFuture.whenComplete { _ in deadline.cancel() }
                let upgrader = NIOTypedWebSocketClientUpgrader<Socket>(maxFrameSize: 1_048_576) { channel, _ in
                    channel.eventLoop.makeCompletedFuture { try Socket(wrappingChannelSynchronously: channel) }
                }
                let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/daemon/connect",
                    headers: HTTPHeaders([("Host", "127.0.0.1:\(server.port)"), ("Authorization", "Bearer sk_computer_query_fixture")]))
                let options = NIOTypedHTTPClientUpgradeConfiguration(upgradeRequestHead: head, upgraders: [upgrader]) { channel in
                    channel.close().flatMapThrowing { throw MachineCommandError.protocolViolation }
                }
                var pipeline = NIOUpgradableHTTPClientPipelineConfiguration(upgradeConfiguration: options)
                pipeline.leftOverBytesStrategy = .forwardBytes
                return channel.pipeline.configureUpgradableHTTPClientPipeline(configuration: pipeline)
            }
        return try await upgrade.get()
    }
    do {
        // No identity; timeout A; reconnect A; cancel B; reconnect B; new C.
        for phase in 0..<6 {
            let socket = try await connect()
            try await socket.executeThenClose { inbound, outbound in
                var input = inbound.makeAsyncIterator()
                let context = try #require(try await input.next())
                let info = try #require(try JSONSerialization.jsonObject(with: Data(context.unmaskedData.readableBytesView)) as? [String: Any])
                let epoch = try #require(info["connectionEpochId"] as? String)
                let daemonId: String? = phase == 0 ? nil : (phase <= 2 ? "scan-daemon-a" : (phase <= 4 ? "scan-daemon-b" : "scan-daemon-c"))
                if let daemonId {
                    let ready = "{\"type\":\"ready\",\"daemonInstanceId\":\"\(daemonId)\"}"
                    try await outbound.write(WebSocketFrame(fin: true, opcode: .text, maskKey: .random(), data: ByteBuffer(string: ready)))
                }
                try await outbound.write(WebSocketFrame(fin: true, opcode: .text, maskKey: .random(), data: ByteBuffer(string: #"{"type":"ping"}"#)))
                _ = try #require(try await input.next())
                if phase == 0 {
                    await #expect(throws: MachineCommandError.protocolViolation) {
                        _ = try await registry.query(.workspaceScan, machineId: "query-machine", serverId: "query-server",
                            expectedConnectionEpochId: epoch, timeout: .milliseconds(50))
                    }
                    return
                }
                let result = Data(#"{"type":"machine:workspace:scan_result","directories":[]}"#.utf8)
                if phase == 2 || phase == 4 {
                    // An old producer can deliver its ID-free reply on this new
                    // socket. It must not clear the same-daemon quarantine.
                    try await outbound.write(WebSocketFrame(fin: true, opcode: .text, maskKey: .random(), data: ByteBuffer(bytes: result)))
                    try await outbound.write(WebSocketFrame(fin: true, opcode: .text, maskKey: .random(), data: ByteBuffer(string: #"{"type":"ping"}"#)))
                    _ = try #require(try await input.next())
                    await #expect(throws: MachineCommandError.duplicatePendingCommand) {
                        _ = try await registry.query(.workspaceScan, machineId: "query-machine", serverId: "query-server",
                            expectedConnectionEpochId: epoch, timeout: .milliseconds(50))
                    }
                    return
                }
                let scan = Task { try await registry.query(.workspaceScan, machineId: "query-machine", serverId: "query-server",
                    expectedConnectionEpochId: epoch, timeout: phase == 1 ? .milliseconds(50) : .seconds(2)) }
                let frame = try #require(try await input.next())
                let request = try #require(try JSONSerialization.jsonObject(with: Data(frame.unmaskedData.readableBytesView)) as? [String: String])
                #expect(request == ["type": "machine:workspace:scan"])
                await #expect(throws: MachineCommandError.duplicatePendingCommand) {
                    _ = try await registry.query(.workspaceScan, machineId: "query-machine", serverId: "query-server",
                        expectedConnectionEpochId: epoch, timeout: .milliseconds(50))
                }
                if phase == 5 {
                    try await outbound.write(WebSocketFrame(fin: true, opcode: .text, maskKey: .random(), data: ByteBuffer(bytes: result)))
                    #expect(try await scan.value.payload == result)
                    let next = Task { try await registry.query(.workspaceScan, machineId: "query-machine", serverId: "query-server",
                        expectedConnectionEpochId: epoch, timeout: .seconds(2)) }
                    _ = try #require(try await input.next())
                    try await outbound.write(WebSocketFrame(fin: true, opcode: .text, maskKey: .random(), data: ByteBuffer(bytes: result)))
                    #expect(try await next.value.connectionEpochId == epoch)
                } else {
                    if phase == 1 {
                        await #expect(throws: MachineCommandError.timedOut) { _ = try await scan.value }
                    } else {
                        scan.cancel()
                        await #expect(throws: CancellationError.self) { _ = try await scan.value }
                    }
                    try await outbound.write(WebSocketFrame(fin: true, opcode: .text, maskKey: .random(), data: ByteBuffer(bytes: result)))
                    try await outbound.write(WebSocketFrame(fin: true, opcode: .text, maskKey: .random(), data: ByteBuffer(string: #"{"type":"ping"}"#)))
                    _ = try #require(try await input.next())
                    await #expect(throws: MachineCommandError.duplicatePendingCommand) {
                        _ = try await registry.query(.workspaceScan, machineId: "query-machine", serverId: "query-server",
                            expectedConnectionEpochId: epoch, timeout: .milliseconds(50))
                    }
                }
            }
        }
        try await group.shutdownGracefully(); try await server.close()
    } catch {
        try? await group.shutdownGracefully(); try? await server.close(); throw error
    }
}

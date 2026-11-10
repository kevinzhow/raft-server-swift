import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import RaftConnectAuth
import Testing
@testable import RaftMachineSocket

private struct ResetWireCredential: MachineCredentialLooking {
    func findComputer(apiKey: String) async throws -> ComputerAuthResolution { .linked(computerId: "reset-computer", machineId: "reset-machine") }
    func machine(id: String) async throws -> MatchedMachine? { .init(id: "reset-machine", serverId: "reset-server") }
    func serverExists(id: String) async throws -> Bool { true }
    func machine(apiKey: String) async throws -> MatchedMachine? { nil }
}

/// Real TCP/RFC6455 output only. This compatibility-mode transport test does
/// not claim a PG commit, Computer cleanup, reset acknowledgement or model run.
@Test func workspaceResetUsesTheOfficialAcklessBodyAndAnEpochFence() async throws {
    let registry = MachineCommandRegistry()
    let server = try await MachineConnectServer.start(lookup: ResetWireCredential(), commandRegistry: registry)
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    do {
        typealias Socket = NIOAsyncChannel<WebSocketFrame, WebSocketFrame>
        let upgrade: EventLoopFuture<Socket> = try await ClientBootstrap(group: group).connectTimeout(.seconds(2))
            .connect(host: "127.0.0.1", port: server.port) { channel in
                let deadline = channel.eventLoop.scheduleTask(in: .seconds(8)) { channel.close(promise: nil) }
                channel.closeFuture.whenComplete { _ in deadline.cancel() }
                let upgrader = NIOTypedWebSocketClientUpgrader<Socket>(maxFrameSize: 1_048_576) { channel, _ in
                    channel.eventLoop.makeCompletedFuture { try Socket(wrappingChannelSynchronously: channel) }
                }
                let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/daemon/connect",
                    headers: HTTPHeaders([("Host", "127.0.0.1:\(server.port)"), ("Authorization", "Bearer sk_computer_reset_fixture")]))
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
            let contextJSON = try JSONSerialization.jsonObject(with: Data(context.unmaskedData.readableBytesView)) as? [String: Any]
            let epoch = try #require(contextJSON?["connectionEpochId"] as? String)
            let ping = ByteBuffer(string: #"{"type":"ping"}"#)
            try await outbound.write(WebSocketFrame(fin: true, opcode: .text, maskKey: .random(), data: ping))
            let pong = try #require(try await input.next())
            #expect(String(decoding: pong.unmaskedData.readableBytesView, as: UTF8.self) == #"{"type":"pong"}"#)
            try await registry.sendWorkspaceReset(machineId: "reset-machine", agentId: "agent", connectionEpochId: epoch)
            let reset = try #require(try await input.next())
            let resetJSON = String(decoding: reset.unmaskedData.readableBytesView, as: UTF8.self)
            let resetBody = try #require(try JSONSerialization.jsonObject(with: Data(resetJSON.utf8)) as? [String: Any])
            #expect(Set(resetBody.keys) == Set(["type", "agentId"]))
            #expect(resetBody["type"] as? String == "agent:reset-workspace")
            #expect(resetBody["agentId"] as? String == "agent")
            let command = try MachineCommand(json: resetJSON, expectedConnectionEpochId: epoch)
            #expect(command.kind == .resetWorkspace)
            await #expect(throws: MachineCommandError.noOutcomeContract) {
                try await registry.sendAndAwaitAcknowledgement(machineId: "reset-machine", command: command)
            }
            await #expect(throws: MachineCommandError.noOutcomeContract) {
                try await registry.sendAndAwaitOutcome(machineId: "reset-machine", command: command)
            }
            await #expect(throws: MachineCommandError.disconnected) {
                try await registry.sendWorkspaceReset(machineId: "reset-machine", agentId: "agent", connectionEpochId: "old-epoch")
            }
            // This actual control frame closes the FIFO window: no reset from
            // the refused stale epoch may appear before the following stop.
            try await registry.sendStop(machineId: "reset-machine", agentId: "agent", connectionEpochId: epoch)
            let next = try #require(try await input.next())
            let nextJSON = try JSONSerialization.jsonObject(with: Data(next.unmaskedData.readableBytesView)) as? [String: Any]
            #expect(nextJSON?["type"] as? String == "agent:stop")
        }
        try await group.shutdownGracefully()
        try await server.close()
    } catch {
        try? await group.shutdownGracefully()
        try? await server.close()
        throw error
    }
}

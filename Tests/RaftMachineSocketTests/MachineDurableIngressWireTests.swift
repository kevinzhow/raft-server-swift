import Foundation
import NIOCore
import NIOPosix
import Synchronization
import Testing
import RaftConnectAuth
@testable import RaftMachineSocket

private struct DurableWireCase: Sendable, CustomTestStringConvertible {
    let type: String
    let body: String
    let acknowledgement: MachineOutcomeAcknowledgement
    var testDescription: String { type }

    static let all: [Self] = [
        .init(type: "agent:start:outcome", body: #""launchId":"launch","result":{"kind":"not_spawned","reason":"spawn_error"}"#, acknowledgement: .sequence(agentId: "agent", daemonInstanceId: "previous-daemon", clientSeq: 0)),
        .init(type: "agent:process_spawned", body: #""launchId":"launch","processInstanceId":"process""#, acknowledgement: .sequence(agentId: "agent", daemonInstanceId: "previous-daemon", clientSeq: 0)),
        .init(type: "agent:process_exited", body: #""launchId":"launch","processInstanceId":"process","spawnLaunchId":"launch","code":0,"signal":null"#, acknowledgement: .sequence(agentId: "agent", daemonInstanceId: "previous-daemon", clientSeq: 0)),
        .init(type: "agent:runtime:outcome", body: #""v":1,"launchId":"launch","sessionId":null,"observedAtMs":1,"outcome":{"kind":"turn_completed","textEvents":1,"toolCalls":0}"#, acknowledgement: .sequence(agentId: "agent", daemonInstanceId: "previous-daemon", clientSeq: 0)),
        .init(type: "agent:runtime:outcome_gap", body: #""gapId":"gap","fromSeq":0,"toSeq":2,"takeoverEpoch":0,"counts":{"e1":1,"turnCompleted":0,"spawned":0,"exited":0,"startOutcome":0}"#, acknowledgement: .marker(agentId: "agent", gapId: "gap")),
        .init(type: "agent:runtime:outcome_cross_instance_unknown", body: #""gapId":"gap","instances":["previous-daemon"],"takeoverEpoch":0,"counts":{"e1":1,"turnCompleted":0,"spawned":0,"exited":0,"startOutcome":0}"#, acknowledgement: .marker(agentId: "agent", gapId: "gap")),
    ]

    var json: String {
        "{\"type\":\"\(type)\",\"agentId\":\"agent\",\"daemonInstanceId\":\"previous-daemon\",\"clientSeq\":0,\(body)}"
    }
}

/// Controls the commit boundary; assertions below observe only real wire output.
private actor DurableWireCommitGate {
    struct FailedCommit: Error {}
    private var release: CheckedContinuation<Bool, Never>?
    let entered: AsyncStream<Void>
    private let enteredContinuation: AsyncStream<Void>.Continuation

    init() {
        let pair = AsyncStream<Void>.makeStream()
        entered = pair.stream
        enteredContinuation = pair.continuation
    }

    func commit() async throws {
        let failed = await withCheckedContinuation { continuation in
            release = continuation
            enteredContinuation.yield(())
        }
        if failed { throw FailedCommit() }
    }

    func finish(failing: Bool = false) {
        release?.resume(returning: failing)
        release = nil
    }
}

private struct DurableWireLookup: MachineCredentialLooking {
    func findComputer(apiKey: String) async throws -> ComputerAuthResolution {
        .linked(computerId: "computer", machineId: "machine")
    }
    func machine(id: String) async throws -> MatchedMachine? { .init(id: "machine", serverId: "server") }
    func serverExists(id: String) async throws -> Bool { true }
    func machine(apiKey: String) async throws -> MatchedMachine? { nil }
}

private func durableWireRegistry(
    gate: DurableWireCommitGate, acknowledgement: MachineOutcomeAcknowledgement
) -> MachineCommandRegistry {
    MachineCommandRegistry(durableIngress: MachineDurableIngress(
        onOpened: { _ in },
        onMessage: { context, message in
            guard context.machineId == "machine", context.serverId == "server", !context.connectionEpochId.isEmpty else {
                return .hold(reason: "invalid_authenticated_context")
            }
            if message.type == "ready" { return .committed(ack: nil) }
            try await gate.commit()
            return .committed(ack: acknowledgement)
        },
        onClosed: { _ in }
    ))
}

@Test(arguments: DurableWireCase.all)
private func durableMachineWireAcknowledgesSixFamiliesOnlyAfterCommit(_ item: DurableWireCase) async throws {
    let gate = DurableWireCommitGate()
    let registry = durableWireRegistry(gate: gate, acknowledgement: item.acknowledgement)
    let server = try await MachineConnectServer.start(lookup: DurableWireLookup(), commandRegistry: registry)
    do {
        let peer = try await DurableMachineWirePeer(port: server.port)
        do {
            #expect(peer.context.contains("agent:runtime-outcome-ack-v1"))
            #expect(peer.context.contains("agent:start-spawn-error-v1"))
            let start = peer.frames.count
            try await peer.send(item.json)
            _ = try #require(try await firstWireGateEntry(gate))
            #expect(try await peer.fence(since: start) == [])
            await gate.finish()
            let ack = try await peer.nextText(since: start) { $0.contains("agent:outcome:ack") }
            try expectWireAcknowledgement(ack, matches: item.acknowledgement)
            try await peer.close()
        } catch {
            await gate.finish()
            try? await peer.close()
            throw error
        }
    } catch {
        await gate.finish()
        try? await server.close()
        throw error
    }
    try await server.close()
}

@Test private func durableMachineWireFailedCommitHoldsUntilSameConnectionReplayCommits() async throws {
    let item = DurableWireCase.all[0]
    let gate = DurableWireCommitGate()
    let registry = durableWireRegistry(gate: gate, acknowledgement: item.acknowledgement)
    let server = try await MachineConnectServer.start(lookup: DurableWireLookup(), commandRegistry: registry)
    do {
        let peer = try await DurableMachineWirePeer(port: server.port)
        do {
            let start = peer.frames.count
            try await peer.send(item.json)
            _ = try #require(try await firstWireGateEntry(gate))
            await gate.finish(failing: true)
            try await peer.applicationFence()
            #expect(try await peer.fence(since: start) == [#"{"type":"pong"}"#])
            let replayStart = peer.frames.count
            try await peer.send(item.json)
            _ = try #require(try await firstWireGateEntry(gate))
            #expect(try await peer.fence(since: replayStart) == [])
            await gate.finish()
            try expectWireAcknowledgement(try await peer.nextText(since: replayStart) { $0.contains("agent:outcome:ack") }, matches: item.acknowledgement)
            try await peer.close()
        } catch {
            await gate.finish()
            try? await peer.close()
            throw error
        }
    } catch {
        await gate.finish()
        try? await server.close()
        throw error
    }
    try await server.close()
}

@Test private func durableMachineWireReplacementCannotAcknowledgeAnOldPendingCommit() async throws {
    let item = DurableWireCase.all[1]
    let gate = DurableWireCommitGate()
    let registry = durableWireRegistry(gate: gate, acknowledgement: item.acknowledgement)
    let server = try await MachineConnectServer.start(lookup: DurableWireLookup(), commandRegistry: registry)
    do {
        let old = try await DurableMachineWirePeer(port: server.port)
        do {
            let start = old.frames.count
            try await old.send(item.json)
            _ = try #require(try await firstWireGateEntry(gate))
            #expect(try await old.fence(since: start) == [])
            let replacement = Task { try await DurableMachineWirePeer(port: server.port) }
            do {
                try await old.waitForClose()
                await gate.finish()
                let current = try await replacement.value
                do {
                    try await current.applicationFence()
                    #expect(!old.frames.contains { $0.text?.contains("agent:outcome:ack") == true })
                    #expect(try await current.fence(since: 0) == [current.context, #"{"type":"pong"}"#])
                    #expect(current.context != old.context)
                    try await current.close()
                } catch { try? await current.close(); throw error }
            } catch {
                await gate.finish()
                if let current = try? await replacement.value { try? await current.close() }
                throw error
            }
            try await old.close()
        } catch {
            await gate.finish()
            try? await old.close()
            throw error
        }
    } catch {
        await gate.finish()
        try? await server.close()
        throw error
    }
    try await server.close()
}

@Test private func durableMachineWireInventoryAndCommittedReconciliationGateCodexDispatchAndStop() async throws {
    let registry = MachineCommandRegistry(durableIngress: MachineDurableIngress(
        onOpened: { _ in }, onMessage: { _, _ in .committed(ack: nil) }, onClosed: { _ in }
    ))
    let server = try await MachineConnectServer.start(lookup: DurableWireLookup(), commandRegistry: registry)
    do {
        let peer = try await DurableMachineWirePeer(port: server.port)
        do {
            let contextObject = try #require(try JSONSerialization.jsonObject(with: Data(peer.context.utf8)) as? [String: Any])
            let currentEpoch = try #require(contextObject["connectionEpochId"] as? String)
            let command = try MachineCommand(json: "{\"type\":\"agent:start\",\"agentId\":\"agent\",\"startDispatchId\":\"dispatch\",\"launchId\":\"launch\",\"runtime\":\"codex\",\"connectionEpochId\":\"\(currentEpoch)\"}")
            await #expect(throws: MachineCommandError.machineOffline) {
                try await registry.sendAndAwaitAcknowledgement(machineId: "machine", command: command)
            }
            try await peer.send(#"{"type":"ready","daemonInstanceId":"daemon","capabilities":["agent:start","agent:deliver","agent:stop"],"runtimeDetection":{"status":"pending"},"runningAgents":[]}"#)
            try await peer.applicationFence()
            await #expect(throws: MachineCommandError.machineOffline) {
                try await registry.sendAndAwaitAcknowledgement(machineId: "machine", command: command)
            }
            try await peer.send(#"{"type":"ready","daemonInstanceId":"daemon","capabilities":["agent:start","agent:deliver","agent:stop"],"runtimeDetection":{"status":"complete","durationMs":1},"runtimes":["claude"],"runningAgents":[]}"#)
            try await peer.applicationFence()
            await #expect(throws: MachineCommandError.runtimeUnavailable) {
                try await registry.sendAndAwaitAcknowledgement(machineId: "machine", command: command)
            }
            try await peer.send(#"{"type":"ready","daemonInstanceId":"daemon","capabilities":["agent:start","agent:deliver","agent:stop"],"runtimeDetection":{"status":"complete","durationMs":1},"runtimes":["codex"],"runningAgents":["already-running"]}"#)
            try await peer.applicationFence()
            let start = peer.frames.count
            let sent = Task { try await registry.sendAndAwaitAcknowledgement(machineId: "machine", command: command) }
            _ = try await peer.nextText(since: start) { $0 == command.json }
            try await peer.send(#"{"type":"agent:start:ack","agentId":"agent","startDispatchId":"dispatch","launchId":"launch","queueState":"starting","queueDepth":0,"queueAgeMs":0}"#)
            _ = try await sent.value
            let stopStart = peer.frames.count
            try await registry.sendStop(machineId: "machine", agentId: "agent", connectionEpochId: currentEpoch)
            let stopped = try await peer.nextText(since: stopStart) { $0.contains("agent:stop") }
            let stopObject = try #require(try JSONSerialization.jsonObject(with: Data(stopped.utf8)) as? [String: String])
            #expect(stopObject == ["type": "agent:stop", "agentId": "agent"])
            #expect(await registry.isExecutionReady(machineId: "machine", runtime: "codex"))
            await #expect(throws: MachineCommandError.disconnected) {
                try await registry.sendStop(machineId: "machine", agentId: "agent", connectionEpochId: "replaced-epoch")
            }
            try await peer.close()
        } catch { try? await peer.close(); throw error }
    } catch { try? await server.close(); throw error }
    try await server.close()
}

@Test private func durableMachineWireHoldsBadIdentityAndCommitsUnreadableEvidenceBeforeAck() async throws {
    let gate = DurableWireCommitGate()
    let expected = MachineOutcomeAcknowledgement.sequence(agentId: "agent", daemonInstanceId: "previous-daemon", clientSeq: 0)
    let registry = MachineCommandRegistry(durableIngress: MachineDurableIngress(
        onOpened: { _ in },
        onMessage: { _, message in
            struct Identity: Decodable { let agentId: String; let daemonInstanceId: String; let clientSeq: Int64 }
            guard let identity = try? JSONDecoder().decode(Identity.self, from: message.payload),
                  identity.agentId == "agent", identity.daemonInstanceId == "previous-daemon", identity.clientSeq == 0 else {
                return .hold(reason: "malformed_identity")
            }
            // The domain owns the manual-recovery transaction for unreadable
            // evidence. Transport must allow that transaction to run first.
            try await gate.commit()
            return .committed(ack: expected)
        }, onClosed: { _ in }
    ))
    let server = try await MachineConnectServer.start(lookup: DurableWireLookup(), commandRegistry: registry)
    do {
        let peer = try await DurableMachineWirePeer(port: server.port)
        do {
            let invalidStart = peer.frames.count
            try await peer.send(#"{"type":"agent:start:outcome","agentId":"agent","daemonInstanceId":"previous-daemon","clientSeq":-1}"#)
            try await peer.send(#"{"type":"agent:start:outcome","agentId":"other-agent","daemonInstanceId":"previous-daemon","clientSeq":0}"#)
            try await peer.applicationFence()
            #expect(try await peer.fence(since: invalidStart) == [#"{"type":"pong"}"#])
            let malformedStart = peer.frames.count
            try await peer.send(#"{"type":"agent:start:outcome","agentId":"agent","daemonInstanceId":"previous-daemon","clientSeq":0,"result":7}"#)
            _ = try #require(try await firstWireGateEntry(gate))
            #expect(try await peer.fence(since: malformedStart) == [])
            await gate.finish()
            try expectWireAcknowledgement(try await peer.nextText(since: malformedStart) { $0.contains("agent:outcome:ack") }, matches: expected)
            try await peer.close()
        } catch { await gate.finish(); try? await peer.close(); throw error }
    } catch { await gate.finish(); try? await server.close(); throw error }
    try await server.close()
}

@Test private func durableMachineWireReadyCannotDispatchBeforeInventoryCommitOrAfterItsFailure() async throws {
    let gate = DurableWireCommitGate()
    let registry = MachineCommandRegistry(durableIngress: MachineDurableIngress(
        onOpened: { _ in },
        onMessage: { _, message in
            if message.type == "ready" { try await gate.commit() }
            return .committed(ack: nil)
        }, onClosed: { _ in }
    ))
    let server = try await MachineConnectServer.start(lookup: DurableWireLookup(), commandRegistry: registry)
    do {
        let peer = try await DurableMachineWirePeer(port: server.port)
        do {
            let ready = #"{"type":"ready","daemonInstanceId":"daemon","capabilities":["agent:start","agent:deliver","agent:stop"],"runtimes":["codex"],"runningAgents":["already-running"],"runtimeDetection":{"status":"complete","durationMs":1}}"#
            let command = try MachineCommand(json: #"{"type":"agent:start","agentId":"agent","startDispatchId":"dispatch","launchId":"launch","runtime":"codex"}"#)
            let start = peer.frames.count
            try await peer.send(ready)
            _ = try #require(try await firstWireGateEntry(gate))
            await #expect(throws: MachineCommandError.machineOffline) {
                try await registry.sendAndAwaitAcknowledgement(machineId: "machine", command: command)
            }
            #expect(try await peer.fence(since: start) == [])
            await gate.finish(failing: true)
            try await peer.applicationFence()
            await #expect(throws: MachineCommandError.machineOffline) {
                try await registry.sendAndAwaitAcknowledgement(machineId: "machine", command: command)
            }
            try await peer.send(ready)
            _ = try #require(try await firstWireGateEntry(gate))
            await gate.finish()
            try await peer.applicationFence()
            let dispatchStart = peer.frames.count
            let sent = Task { try await registry.sendAndAwaitAcknowledgement(machineId: "machine", command: command) }
            _ = try await peer.nextText(since: dispatchStart) { $0 == command.json }
            try await peer.send(#"{"type":"agent:start:ack","agentId":"agent","startDispatchId":"dispatch","launchId":"launch","queueState":"starting","queueDepth":0,"queueAgeMs":0}"#)
            _ = try await sent.value
            try await peer.close()
        } catch { await gate.finish(); try? await peer.close(); throw error }
    } catch { await gate.finish(); try? await server.close(); throw error }
    try await server.close()
}

@Test private func legacyMachineWireCannotAdvertiseDurableOutcomeCapabilities() async throws {
    let registry = MachineCommandRegistry(onMessageCommitted: { _, _ in })
    let server = try await MachineConnectServer.start(
        lookup: DurableWireLookup(), capabilities: ["agent:runtime-outcome-ack-v1", "agent:start-spawn-error-v1", serverCapabilityRuntimeDetectionAsyncV1], commandRegistry: registry
    )
    do {
        let peer = try await DurableMachineWirePeer(port: server.port)
        do {
            #expect(!peer.context.contains("agent:runtime-outcome-ack-v1"))
            #expect(!peer.context.contains("agent:start-spawn-error-v1"))
            #expect(peer.context.contains(serverCapabilityRuntimeDetectionAsyncV1))
            let start = peer.frames.count
            try await peer.send(DurableWireCase.all[0].json)
            try await peer.applicationFence()
            #expect(try await peer.fence(since: start) == [#"{"type":"pong"}"#])
            try await peer.close()
        } catch { try? await peer.close(); throw error }
    } catch { try? await server.close(); throw error }
    try await server.close()
}

private func firstWireGateEntry(_ gate: DurableWireCommitGate) async throws -> Bool {
    try await withThrowingTaskGroup(of: Bool.self) { group in
        group.addTask {
            for await _ in gate.entered { return true }
            return false
        }
        group.addTask { try await Task.sleep(for: .seconds(3)); throw DurableMachineWireTimeout() }
        let value = try await group.next()!
        group.cancelAll()
        return value
    }
}

private func expectWireAcknowledgement(_ json: String, matches expected: MachineOutcomeAcknowledgement) throws {
    let actual = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    #expect(actual["type"] as? String == "agent:outcome:ack")
    #expect(actual["agentId"] as? String == "agent")
    switch expected {
    case .sequence(_, let daemon, let seq):
        #expect(actual["daemonInstanceId"] as? String == daemon)
        #expect(actual["clientSeq"] as? Int64 == seq)
        #expect(actual["gapId"] == nil)
    case .marker(_, let gapId):
        #expect(actual["gapId"] as? String == gapId)
        #expect(actual["daemonInstanceId"] == nil)
        #expect(actual["clientSeq"] == nil)
    }
}

private struct DurableMachineWireTimeout: Error {}

private struct DurableMachineWireFrame: Sendable {
    let opcode: UInt8
    let payload: [UInt8]
    var text: String? { opcode == 1 ? String(bytes: payload, encoding: .utf8) : nil }
}

private final class DurableMachineWireInbox: Sendable {
    private struct State: Sendable { var frames: [DurableMachineWireFrame] = []; var closed = false }
    private let state = Mutex(State())
    var frames: [DurableMachineWireFrame] { state.withLock { $0.frames } }
    var closed: Bool { state.withLock { $0.closed } }
    func append(_ frames: [DurableMachineWireFrame]) { state.withLock { $0.frames += frames } }
    func close() { state.withLock { $0.closed = true } }
}

/// The parser stays on its NIO loop. Only the checked inbox crosses executors.
private final class DurableMachineWireHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private var header: [UInt8] = []
    private var upgraded = false
    private var codec = MachineCommandWebSocket()
    private let inbox: DurableMachineWireInbox
    init(inbox: DurableMachineWireInbox) { self.inbox = inbox }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let input = unwrapInboundIn(data)
        var bytes = Array(input.readableBytesView)
        do {
            if !upgraded {
                header += bytes
                guard let end = header.indices.first(where: { $0 + 3 < header.count && Array(header[$0...$0 + 3]) == [13, 10, 13, 10] }) else { return }
                guard String(decoding: header.prefix(end), as: UTF8.self).hasPrefix("HTTP/1.1 101") else { context.close(promise: nil); return }
                bytes = Array(header.dropFirst(end + 4)); header = []; upgraded = true
            }
            let frames = try codec.append(bytes, requireMask: false)
            inbox.append(frames.map { DurableMachineWireFrame(opcode: $0.opcode, payload: $0.payload) })
        } catch { context.close(promise: nil) }
    }
    func channelInactive(context: ChannelHandlerContext) { inbox.close(); context.fireChannelInactive() }
    func errorCaught(context: ChannelHandlerContext, error: any Error) { context.close(promise: nil) }
}

private final class DurableMachineWirePeer: Sendable {
    private let group: MultiThreadedEventLoopGroup
    private let channel: any Channel
    private let inbox: DurableMachineWireInbox
    let context: String
    var frames: [DurableMachineWireFrame] { inbox.frames }

    init(port: Int) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let inbox = DurableMachineWireInbox()
        let channel: any Channel
        do {
            channel = try await ClientBootstrap(group: group).channelInitializer { channel in
                let handler = NIOLoopBound(DurableMachineWireHandler(inbox: inbox), eventLoop: channel.eventLoop)
                return channel.eventLoop.submit { try channel.pipeline.syncOperations.addHandler(handler.value) }
            }.connect(host: "127.0.0.1", port: port).get()
        } catch { try? await group.shutdownGracefully(); throw error }
        do {
            let header = "GET /daemon/connect HTTP/1.1\r\nHost: example.com\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nAuthorization: Bearer sk_computer_wiretest\r\n\r\n"
            try await channel.writeAndFlush(channel.allocator.buffer(bytes: Array(header.utf8))).get()
            let deadline = Date().addingTimeInterval(3)
            while inbox.frames.first?.text == nil && Date() < deadline && !inbox.closed { try await Task.sleep(for: .milliseconds(5)) }
            guard let context = inbox.frames.first?.text else { throw DurableMachineWireTimeout() }
            self.context = context
        } catch { try? await channel.close(); try? await group.shutdownGracefully(); throw error }
        self.group = group; self.channel = channel; self.inbox = inbox
    }

    func send(_ json: String) async throws { try await send(opcode: 1, payload: Array(json.utf8)) }
    private func send(opcode: UInt8, payload: [UInt8]) async throws {
        let bytes = MachineCommandWebSocket.encode(opcode: opcode, payload: payload, masked: true)
        try await channel.writeAndFlush(channel.allocator.buffer(bytes: bytes)).get()
    }
    func nextText(since start: Int, matching predicate: @Sendable (String) -> Bool) async throws -> String {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let text = frames.dropFirst(start).compactMap(\.text).first(where: predicate) { return text }
            if inbox.closed { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw DurableMachineWireTimeout()
    }
    func applicationFence() async throws {
        let start = frames.count
        try await send(#"{"type":"ping"}"#)
        _ = try await nextText(since: start) { $0 == #"{"type":"pong"}"# }
    }
    /// Control ping stays live while a domain commit is suspended. The returned
    /// FIFO prefix therefore proves ACK absence before that commit is released.
    func fence(since start: Int) async throws -> [String] {
        let nonce = Array(UUID().uuidString.utf8)
        try await send(opcode: 9, payload: nonce)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let received = frames
            if let end = received.indices.first(where: { $0 >= start && received[$0].opcode == 10 && received[$0].payload == nonce }) {
                return received[start..<end].compactMap(\.text)
            }
            if inbox.closed { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw DurableMachineWireTimeout()
    }
    func waitForClose() async throws {
        let deadline = Date().addingTimeInterval(3)
        while !inbox.closed && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        guard inbox.closed else { throw DurableMachineWireTimeout() }
    }
    func close() async throws {
        try? await channel.close()
        try await group.shutdownGracefully()
    }
}

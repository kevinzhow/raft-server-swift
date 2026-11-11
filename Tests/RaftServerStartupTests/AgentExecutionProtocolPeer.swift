import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import RaftShared
import Synchronization

/// Controlled protocol evidence only. No official inventory, Codex login,
/// process execution, model result, or mailbox delivery is asserted here.
enum ProtocolPGFailure: Error {
    case missingDedicatedDatabase, databaseNotEmpty, invalidResponse, invalidSnapshot
    case refused, closed, timeout, frameLimit, missingField, persistenceUnavailable
}

struct ProtocolPGObject: Sendable, CustomStringConvertible {
    let fields: [String: JSONValue]
    var description: String { "ProtocolPGObject(redacted)" }
    init(_ fields: [String: JSONValue]) { self.fields = fields }
    init(data: Data) throws {
        guard case .object(let fields) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw ProtocolPGFailure.invalidResponse
        }
        self.fields = fields
    }
    init(text: String) throws { try self.init(data: Data(text.utf8)) }
    func string(_ key: String) -> String? {
        guard case .string(let value) = fields[key] else { return nil }; return value
    }
    func integer(_ key: String) -> Int64? {
        guard case .integer(let value) = fields[key] else { return nil }; return value
    }
    func bool(_ key: String) -> Bool? {
        guard case .bool(let value) = fields[key] else { return nil }; return value
    }
    func object(_ key: String) -> ProtocolPGObject? {
        guard case .object(let value) = fields[key] else { return nil }; return .init(value)
    }
    func array(_ key: String) -> [JSONValue]? {
        guard case .array(let value) = fields[key] else { return nil }; return value
    }
    func requireString(_ key: String) throws -> String {
        guard let value = string(key), !value.isEmpty else { throw ProtocolPGFailure.missingField }; return value
    }
    var data: Data { get throws { try JSONEncoder().encode(JSONValue.object(fields)) } }
}

private struct ProtocolPGFrame: Sendable {
    let opcode: WebSocketOpcode
    let text: String?
    let bytes: [UInt8]
}

private final class ProtocolPGInbox: Sendable {
    private struct State: Sendable { var frames: [ProtocolPGFrame] = []; var closed = false; var bytes = 0 }
    private let state = Mutex(State())
    var frames: [ProtocolPGFrame] { state.withLock { $0.frames } }
    var closed: Bool { state.withLock { $0.closed } }
    func append(_ frame: ProtocolPGFrame) -> Bool {
        state.withLock {
            guard $0.frames.count < 4096, $0.bytes + frame.bytes.count <= 8 * 1024 * 1024 else { return false }
            $0.frames.append(frame); $0.bytes += frame.bytes.count; return true
        }
    }
    func finish() { state.withLock { $0.closed = true } }
}

private final class ProtocolPGFrameHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame
    let inbox: ProtocolPGInbox
    init(inbox: ProtocolPGInbox) { self.inbox = inbox }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        var payload = frame.unmaskedData
        guard frame.fin, let bytes = payload.readBytes(length: payload.readableBytes),
              inbox.append(.init(opcode: frame.opcode, text: frame.opcode == .text ? String(bytes: bytes, encoding: .utf8) : nil, bytes: bytes)) else {
            inbox.finish(); context.close(promise: nil); return
        }
        if frame.opcode == .ping {
            var reply = context.channel.allocator.buffer(capacity: bytes.count)
            reply.writeBytes(bytes)
            context.writeAndFlush(NIOAny(WebSocketFrame(fin: true, opcode: .pong, maskKey: .random(), data: reply)), promise: nil)
        } else if frame.opcode == .text, String(bytes: bytes, encoding: .utf8) == "2" {
            // Real socket.io Engine.IO heartbeat, unrelated to machine outcome ACKs.
            var reply = context.channel.allocator.buffer(capacity: 1); reply.writeString("3")
            context.writeAndFlush(NIOAny(WebSocketFrame(fin: true, opcode: .text, maskKey: .random(), data: reply)), promise: nil)
        } else if frame.opcode == .connectionClose {
            inbox.finish(); context.close(promise: nil)
        }
    }
    func channelInactive(context: ChannelHandlerContext) { inbox.finish() }
    func errorCaught(context: ChannelHandlerContext, error: any Error) { inbox.finish(); context.close(promise: nil) }
}

/// All observations come from the authenticated network connection, rather than
/// an ingress callback or a service recorder. All waits and buffers are bounded.
final class ProtocolPGSocket: Sendable {
    private let group: MultiThreadedEventLoopGroup
    private let channel: any Channel
    private let inbox: ProtocolPGInbox
    private let didClose = Mutex(false)
    var count: Int { inbox.frames.count }
    var texts: [String] { inbox.frames.compactMap(\.text) }

    private init(group: MultiThreadedEventLoopGroup, channel: any Channel, inbox: ProtocolPGInbox) {
        self.group = group; self.channel = channel; self.inbox = inbox
    }
    static func connect(port: Int, path: String, authorization: String? = nil) async throws -> ProtocolPGSocket {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let inbox = ProtocolPGInbox()
        do {
            let upgraded: EventLoopFuture<any Channel> = try await ClientBootstrap(group: group)
                .connectTimeout(.seconds(3))
                .connect(host: "127.0.0.1", port: port) { channel in
                    let lifetime = channel.eventLoop.scheduleTask(in: .seconds(180)) { channel.close(promise: nil) }
                    channel.closeFuture.whenComplete { _ in lifetime.cancel() }
                    let upgrader = NIOTypedWebSocketClientUpgrader<any Channel>(maxFrameSize: 1_048_576) { channel, _ in
                        channel.eventLoop.makeCompletedFuture {
                            try channel.pipeline.syncOperations.addHandler(ProtocolPGFrameHandler(inbox: inbox))
                            return channel
                        }
                    }
                    var headers = HTTPHeaders([("Host", "127.0.0.1:\(port)")])
                    if let authorization { headers.add(name: "Authorization", value: authorization) }
                    let request = HTTPRequestHead(version: .http1_1, method: .GET, uri: path, headers: headers)
                    let upgrade = NIOTypedHTTPClientUpgradeConfiguration(upgradeRequestHead: request, upgraders: [upgrader]) { channel in
                        channel.close().flatMapThrowing { throw ProtocolPGFailure.refused }
                    }
                    var configuration = NIOUpgradableHTTPClientPipelineConfiguration(upgradeConfiguration: upgrade)
                    configuration.leftOverBytesStrategy = .forwardBytes
                    return channel.pipeline.configureUpgradableHTTPClientPipeline(configuration: configuration)
                }
            let channel = try await upgraded.get()
            return .init(group: group, channel: channel, inbox: inbox)
        } catch {
            try? await group.shutdownGracefully(); throw error
        }
    }
    func send(_ text: String) async throws {
        var data = channel.allocator.buffer(capacity: text.utf8.count)
        data.writeString(text)
        try await channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .text, maskKey: .random(), data: data)).get()
    }
    func send(_ object: ProtocolPGObject) async throws { try await send(String(decoding: object.data, as: UTF8.self)) }
    func nextText(since start: Int = 0, matching: @Sendable (String) -> Bool) async throws -> String {
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        while ContinuousClock.now < deadline {
            if let found = inbox.frames.dropFirst(start).compactMap(\.text).first(where: matching) { return found }
            if inbox.closed { throw ProtocolPGFailure.closed }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ProtocolPGFailure.timeout
    }
    func nextObject(since start: Int = 0, matching: @Sendable (ProtocolPGObject) -> Bool) async throws -> ProtocolPGObject {
        let text = try await nextText(since: start) { text in
            guard let value = try? ProtocolPGObject(text: text) else { return false }; return matching(value)
        }
        return try ProtocolPGObject(text: text)
    }
    /// JSON ping passes through the machine's ordered application queue, so the
    /// reply is after preceding ingress transactions. WS ping fences raw output.
    func applicationFence() async throws {
        let start = count
        try await send(.init(["type": .string("ping")]))
        _ = try await nextObject(since: start) { $0.string("type") == "pong" }
    }
    func wireFence(since start: Int) async throws -> [String] {
        let nonce = Array(UUID().uuidString.utf8)
        var data = channel.allocator.buffer(capacity: nonce.count); data.writeBytes(nonce)
        try await channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .ping, maskKey: .random(), data: data)).get()
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        while ContinuousClock.now < deadline {
            let frames = inbox.frames
            if let end = frames.indices.first(where: { $0 >= start && frames[$0].opcode == .pong && frames[$0].bytes == nonce }) {
                return frames[start..<end].compactMap(\.text)
            }
            if inbox.closed { throw ProtocolPGFailure.closed }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ProtocolPGFailure.timeout
    }
    func close() async {
        let first = didClose.withLock { value in if value { return false }; value = true; return true }
        guard first else { return }
        try? await channel.close(); try? await group.shutdownGracefully()
    }
}

/// One real daemon keeps its outcome clientSeq monotonic across socket
/// reconnects; a new peer instance for the same daemon shares this counter.
final class ProtocolPGSequence: Sendable {
    private let value = Mutex<Int64>(0)
    func next() -> Int64 { value.withLock { current in current += 1; return current } }
}

final class ControlledMachineProtocolPeer: Sendable {
    let socket: ProtocolPGSocket
    let context: ProtocolPGObject
    let daemonId: String
    /// The same real daemon keeps one instance id across a Main restart; the
    /// peer preserves it explicitly so a reconnect is not a daemon restart.
    let sequence: ProtocolPGSequence
    init(socket: ProtocolPGSocket, context: ProtocolPGObject, daemonId: String,
         sequence: ProtocolPGSequence = ProtocolPGSequence()) {
        self.socket = socket
        self.context = context
        self.daemonId = daemonId
        self.sequence = sequence
    }
    static func connect(port: Int, key: String, daemonId: String? = nil,
                        sequence: ProtocolPGSequence = ProtocolPGSequence()) async throws -> Self {
        let socket = try await ProtocolPGSocket.connect(port: port, path: "/daemon/connect", authorization: "Bearer \(key)")
        do {
            let context = try await socket.nextObject { $0.string("type") == "machine:context" }
            return Self(socket: socket, context: context,
                        daemonId: daemonId ?? "protocol-peer-\(UUID().uuidString.lowercased())",
                        sequence: sequence)
        } catch { await socket.close(); throw error }
    }
    func sendControlledReady(runningAgentIds: [String] = []) async throws {
        try await socket.send(.init([
            "type": .string("ready"), "daemonInstanceId": .string(daemonId),
            "capabilities": .array(["agent:start", "agent:deliver", "agent:stop", "agent:runtime-outcome-v1"].map(JSONValue.string)),
            "runtimes": .array([.string("codex")]),
            "runningAgents": .array(runningAgentIds.map(JSONValue.string)),
            "runtimeDetection": .object(["status": .string("complete")]),
        ]))
        try await socket.applicationFence()
    }
    /// A sequenced outcome frame from the same daemon instance. The client
    /// sequence is a per-daemon monotonic counter, never a fabricated receipt.
    func sendOutcome(_ fields: [String: JSONValue]) async throws {
        var body = fields
        body["daemonInstanceId"] = .string(daemonId)
        body["clientSeq"] = .integer(sequence.next())
        try await socket.send(.init(body))
        try await socket.applicationFence()
    }
    func sendProcessSpawned(agentId: String, launchId: String, processInstanceId: String) async throws {
        try await sendOutcome([
            "type": .string("agent:process_spawned"), "agentId": .string(agentId),
            "launchId": .string(launchId), "processInstanceId": .string(processInstanceId),
        ])
    }
    func sendRebound(agentId: String, launchId: String, processInstanceId: String) async throws {
        try await sendOutcome([
            "type": .string("agent:start:outcome"), "agentId": .string(agentId),
            "launchId": .string(launchId),
            "result": .object(["kind": .string("rebound"), "processInstanceId": .string(processInstanceId)]),
        ])
    }
    func sendProcessExited(agentId: String, launchId: String, processInstanceId: String,
                           spawnLaunchId: String) async throws {
        try await sendOutcome([
            "type": .string("agent:process_exited"), "agentId": .string(agentId),
            "launchId": .string(launchId), "processInstanceId": .string(processInstanceId),
            "spawnLaunchId": .string(spawnLaunchId),
        ])
    }
    func sendTurnCompleted(agentId: String, launchId: String, sessionId: String?) async throws {
        try await sendOutcome([
            "type": .string("agent:runtime:outcome"), "v": .integer(1), "agentId": .string(agentId),
            "launchId": .string(launchId),
            "sessionId": sessionId.map(JSONValue.string) ?? .null,
            "outcome": .object(["kind": .string("turn_completed")]),
        ])
    }
    func acknowledgeControlledStart(_ frame: ProtocolPGObject) async throws {
        try await socket.send(.init([
            "type": .string("agent:start:ack"), "agentId": .string(try frame.requireString("agentId")),
            "launchId": .string(try frame.requireString("launchId")), "startDispatchId": .string(try frame.requireString("startDispatchId")),
            "queueState": .string("starting"), "queueDepth": .integer(0), "queueAgeMs": .integer(0),
        ]))
        try await socket.applicationFence()
    }
    /// The official daemon's rebind ack: `queueState: running`/`rebound` plus
    /// the registered process identity (RFC 071 §4.3 rule 2).
    func acknowledgeControlledRebind(_ frame: ProtocolPGObject, processInstanceId: String,
                                     queueState: String = "running") async throws {
        try await socket.send(.init([
            "type": .string("agent:start:ack"), "agentId": .string(try frame.requireString("agentId")),
            "launchId": .string(try frame.requireString("launchId")),
            "startDispatchId": .string(try frame.requireString("startDispatchId")),
            "queueState": .string(queueState), "queueDepth": .integer(0), "queueAgeMs": .integer(0),
            "processInstanceId": .string(processInstanceId),
        ]))
        try await socket.applicationFence()
    }
    /// An `agent:session` control frame for the launch this daemon accepted.
    func sendSession(agentId: String, launchId: String, sessionId: String) async throws {
        try await socket.send(.init([
            "type": .string("agent:session"), "agentId": .string(agentId),
            "launchId": .string(launchId), "sessionId": .string(sessionId),
        ]))
        try await socket.applicationFence()
    }

    /// The official daemon's tracked-mention receipt chain: `daemon_received`,
    /// `daemon_drained`, then the final ACK carrying the same identity.
    func acknowledgeControlledMentionDelivery(_ frame: ProtocolPGObject) async throws {
        guard let sequence = frame.integer("seq"),
              let identity = frame.object("mentionDelivery") else { throw ProtocolPGFailure.missingField }
        func mentionIdentity() -> [String: JSONValue] {
            var fields: [String: JSONValue] = [:]
            for key in ["occurrenceId", "messageId", "machineId", "launchId", "sessionId"] {
                if let value = identity.string(key) { fields[key] = .string(value) }
            }
            return fields
        }
        try await socket.send(.init([
            "type": .string("agent:delivery:transition"), "agentId": .string(try frame.requireString("agentId")),
            "stage": .string("daemon_received"), "outcome": .string("accepted"),
            "mentionDelivery": .object(mentionIdentity()),
        ]))
        try await socket.send(.init([
            "type": .string("agent:delivery:transition"), "agentId": .string(try frame.requireString("agentId")),
            "stage": .string("daemon_drained"), "outcome": .string("accepted"),
            "mentionDelivery": .object(mentionIdentity()),
        ]))
        try await socket.send(.init([
            "type": .string("agent:deliver:ack"), "agentId": .string(try frame.requireString("agentId")),
            "deliveryId": .string(try frame.requireString("deliveryId")), "seq": .integer(sequence),
            "mentionDelivery": .object(mentionIdentity()),
        ]))
        try await socket.applicationFence()
    }

    func acknowledgeControlledDelivery(_ frame: ProtocolPGObject) async throws {
        guard let sequence = frame.integer("seq") else { throw ProtocolPGFailure.missingField }
        try await socket.send(.init([
            "type": .string("agent:deliver:ack"), "agentId": .string(try frame.requireString("agentId")),
            "deliveryId": .string(try frame.requireString("deliveryId")), "seq": .integer(sequence),
        ]))
        try await socket.applicationFence()
    }
}

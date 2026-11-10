import Foundation
import NIOCore
import NIOEmbedded
import NIOPosix
import NIOWebSocket
import RaftConnectAuth
import Synchronization
import Testing
@testable import RaftMachineSocket

/// Compatibility for the unchanged task-67 real-wire fixtures. All framing is
/// delegated to NIO's encoder/decoder; EmbeddedChannel exists only in tests.
final class MachineCommandWebSocket {
    struct Frame: Sendable { let opcode: UInt8; let payload: [UInt8] }
    private let decoder = EmbeddedChannel(handler: ByteToMessageHandler(WebSocketFrameDecoder(maxFrameSize: 1_048_576)))

    deinit { _ = try? decoder.finish(acceptAlreadyClosed: true) }

    func append(_ bytes: [UInt8], requireMask: Bool) throws -> [Frame] {
        try decoder.writeInbound(ByteBuffer(bytes: bytes))
        var result: [Frame] = []
        while let frame = try decoder.readInbound(as: WebSocketFrame.self) {
            guard (frame.maskKey != nil) == requireMask, !frame.rsv1, !frame.rsv2, !frame.rsv3 else {
                throw MachineCommandError.protocolViolation
            }
            result.append(Frame(opcode: UInt8(webSocketOpcode: frame.opcode), payload: Array(frame.unmaskedData.readableBytesView)))
        }
        return result
    }

    static func encode(
        opcode: UInt8, payload: [UInt8], masked: Bool = false, fin: Bool = true, rsv1: Bool = false
    ) -> [UInt8] {
        let encoder = EmbeddedChannel(handler: WebSocketFrameEncoder())
        defer { _ = try? encoder.finish(acceptAlreadyClosed: true) }
        guard let kind = WebSocketOpcode(encodedWebSocketOpcode: opcode) else { preconditionFailure("Invalid fixture opcode") }
        let frame = WebSocketFrame(
            fin: fin, rsv1: rsv1, opcode: kind,
            maskKey: masked ? .random() : nil, data: ByteBuffer(bytes: payload)
        )
        do {
            try encoder.writeOutbound(frame)
            var bytes: [UInt8] = []
            while let buffer = try encoder.readOutbound(as: ByteBuffer.self) { bytes += buffer.readableBytesView }
            return bytes
        } catch { preconditionFailure("NIO could not encode a test frame") }
    }
}

private struct LibraryWireLookup: MachineCredentialLooking {
    let gate: LibraryUpgradeGate?
    init(gate: LibraryUpgradeGate? = nil) { self.gate = gate }
    func findComputer(apiKey: String) async throws -> ComputerAuthResolution {
        if let gate { await gate.waitForRelease() }
        return .linked(computerId: "computer", machineId: "machine")
    }
    func machine(id: String) async throws -> MatchedMachine? { .init(id: "machine", serverId: "server") }
    func serverExists(id: String) async throws -> Bool { true }
    func machine(apiKey: String) async throws -> MatchedMachine? { nil }
}

private actor LibraryUpgradeGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    let entered: AsyncStream<Void>
    private let enteredContinuation: AsyncStream<Void>.Continuation
    init() {
        let pair = AsyncStream<Void>.makeStream()
        entered = pair.stream; enteredContinuation = pair.continuation
    }
    func waitForRelease() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            enteredContinuation.yield(())
        }
    }
    func release() {
        released = true
        continuation?.resume(); continuation = nil
    }
}

@Test private func libraryMachineWirePreservesUpgradeLeftoverAndFragmentedUTF8WithControlFrames() async throws {
    let gate = LibraryUpgradeGate()
    let server = try await MachineConnectServer.start(lookup: LibraryWireLookup(gate: gate), commandRegistry: MachineCommandRegistry())
    do {
        let peer = try await LibraryWirePeer(port: server.port)
        do {
            let bytes = Array(#"{"type":"ping","note":"€"}"#.utf8)
            let split = try #require(bytes.firstIndex(of: 0xE2)) + 1
            let first = MachineCommandWebSocket.encode(opcode: 1, payload: Array(bytes[..<split]), masked: true, fin: false)
            // The first frame is in the very same TCP write as the HTTP header.
            try await peer.sendRaw(Array(LibraryWirePeer.upgrade.utf8) + first)
            try await waitForLibraryUpgradeGate(gate)
            let nonce = Array(UUID().uuidString.utf8)
            // These bytes arrive while asynchronous credential resolution waits.
            try await peer.sendRaw(MachineCommandWebSocket.encode(opcode: 9, payload: nonce, masked: true))
            try await peer.sendRaw(MachineCommandWebSocket.encode(opcode: 0, payload: Array(bytes[split...]), masked: true))
            await gate.release()
            _ = try await peer.waitForFrame { $0.opcode == 1 && String(decoding: $0.payload, as: UTF8.self).contains("machine:context") }
            _ = try await peer.waitForFrame { $0.opcode == 10 && $0.payload == nonce }
            _ = try await peer.waitForFrame { $0.text == #"{"type":"pong"}"# }
            #expect(peer.frames.map(\.opcode) == [1, 10, 1])
            #expect(peer.header.hasPrefix("HTTP/1.1 101 Switching Protocols\r\n"))
            try await peer.close()
        } catch { await gate.release(); try? await peer.close(); throw error }
    } catch { await gate.release(); try? await server.close(); throw error }
    try await server.close()
}

@Test private func libraryMachineWireAcceptsExactlyOneMiBAcrossFragmentsAndEchoesClose() async throws {
    let server = try await MachineConnectServer.start(lookup: LibraryWireLookup(), commandRegistry: MachineCommandRegistry())
    do {
        let peer = try await LibraryWirePeer(port: server.port)
        do {
            try await peer.sendRaw(Array(LibraryWirePeer.upgrade.utf8))
            _ = try await peer.waitForFrame { $0.text?.contains("machine:context") == true }
            let prefix = Array(#"{"type":"ping","padding":""#.utf8)
            let suffix = Array(#""}"#.utf8)
            let bytes = prefix + Array(repeating: UInt8(ascii: "a"), count: 1_048_576 - prefix.count - suffix.count) + suffix
            #expect(bytes.count == 1_048_576)
            let midpoint = bytes.count / 2
            try await peer.sendRaw(MachineCommandWebSocket.encode(opcode: 1, payload: Array(bytes[..<midpoint]), masked: true, fin: false))
            try await peer.sendRaw(MachineCommandWebSocket.encode(opcode: 0, payload: Array(bytes[midpoint...]), masked: true))
            _ = try await peer.waitForFrame { $0.text == #"{"type":"pong"}"# }
            let close = Array([UInt8(3), 232]) + Array("done".utf8)
            try await peer.sendRaw(MachineCommandWebSocket.encode(opcode: 8, payload: close, masked: true))
            _ = try await peer.waitForFrame { $0.opcode == 8 && $0.payload == close }
            try await peer.waitForClose()
            #expect(peer.frames.map(\.opcode) == [1, 1, 8])
            try await peer.close()
        } catch { try? await peer.close(); throw error }
    } catch { try? await server.close(); throw error }
    try await server.close()
}

@Test private func libraryMachineWireDeliveryEpochMetadataCannotCrossReplacementAndLegacyJSONIsUnchanged() async throws {
    let registry = MachineCommandRegistry()
    let server = try await MachineConnectServer.start(lookup: LibraryWireLookup(), commandRegistry: registry)
    do {
        let old = try await LibraryWirePeer(port: server.port)
        do {
            try await old.sendRaw(Array(LibraryWirePeer.upgrade.utf8))
            let oldContext = try await old.waitForFrame { $0.text?.contains("machine:context") == true }
            let oldObject = try #require(try JSONSerialization.jsonObject(with: Data(oldContext.payload)) as? [String: Any])
            let oldEpoch = try #require(oldObject["connectionEpochId"] as? String)
            let wire = #"{ "type": "agent:deliver", "agentId": "agent", "deliveryId": "delivery", "seq": 7, "message": { "channel_id": "channel", "channel_name": "General", "channel_type": "channel", "sender_id": "user", "sender_name": "User", "sender_type": "human", "content": "hello", "timestamp": "1970-01-01T00:00:00Z" } }"#
            let prepared = try MachineCommand(json: wire, expectedConnectionEpochId: oldEpoch)
            #expect(prepared.json == wire)
            #expect(prepared.connectionEpochId == oldEpoch)
            let payload = try #require(try JSONSerialization.jsonObject(with: Data(prepared.json.utf8)) as? [String: Any])
            #expect(payload["connectionEpochId"] == nil)

            let current = try await LibraryWirePeer(port: server.port)
            do {
                try await current.sendRaw(Array(LibraryWirePeer.upgrade.utf8))
                let context = try await current.waitForFrame { $0.text?.contains("machine:context") == true }
                let object = try #require(try JSONSerialization.jsonObject(with: Data(context.payload)) as? [String: Any])
                let epoch = try #require(object["connectionEpochId"] as? String)
                #expect(epoch != oldEpoch)
                try await old.waitForClose()
                // Application FIFO processing waits for startup's registry-ready step.
                try await current.sendRaw(MachineCommandWebSocket.encode(opcode: 1, payload: Array(#"{"type":"ping"}"#.utf8), masked: true))
                _ = try await current.waitForFrame { $0.text == #"{"type":"pong"}"# }
                let staleStart = current.frames.count
                await #expect(throws: MachineCommandError.disconnected) {
                    try await registry.sendAndAwaitAcknowledgement(machineId: "machine", command: prepared)
                }
                #expect(try await current.fence(since: staleStart) == [])

                // Existing callers that omit private metadata keep their wire and behavior.
                let legacy = try MachineCommand(json: wire)
                #expect(legacy.connectionEpochId == nil)
                #expect(legacy.json == wire)
                let legacyStart = current.frames.count
                let legacySent = Task { try await registry.sendAndAwaitAcknowledgement(machineId: "machine", command: legacy) }
                let legacyFrame = try await current.waitForFrame(since: legacyStart) { $0.text == wire }
                #expect(legacyFrame.payload == Array(wire.utf8))
                let acknowledgement = #"{"type":"agent:deliver:ack","agentId":"agent","deliveryId":"delivery","seq":7}"#
                try await current.sendRaw(MachineCommandWebSocket.encode(opcode: 1, payload: Array(acknowledgement.utf8), masked: true))
                #expect(try await legacySent.value.json == acknowledgement)

                let matching = try MachineCommand(json: wire, expectedConnectionEpochId: epoch)
                let matchingStart = current.frames.count
                let matchingSent = Task { try await registry.sendAndAwaitAcknowledgement(machineId: "machine", command: matching) }
                let matchingFrame = try await current.waitForFrame(since: matchingStart) { $0.text == wire }
                #expect(matchingFrame.payload == Array(wire.utf8))
                try await current.sendRaw(MachineCommandWebSocket.encode(opcode: 1, payload: Array(acknowledgement.utf8), masked: true))
                #expect(try await matchingSent.value.json == acknowledgement)

                // Start already has an upstream epoch field: conflicting metadata
                // must fail without rewriting either source of identity.
                let startWire = "{\"type\":\"agent:start\",\"agentId\":\"agent\",\"startDispatchId\":\"dispatch\",\"launchId\":\"launch\",\"connectionEpochId\":\"\(epoch)\"}"
                #expect(throws: MachineCommandError.disconnected) {
                    try MachineCommand(json: startWire, expectedConnectionEpochId: oldEpoch)
                }
                let matchingStartCommand = try MachineCommand(json: startWire, expectedConnectionEpochId: epoch)
                #expect(matchingStartCommand.json == startWire)
                #expect(matchingStartCommand.connectionEpochId == epoch)
                try await current.close()
            } catch { try? await current.close(); throw error }
            try await old.close()
        } catch { try? await old.close(); throw error }
    } catch { try? await server.close(); throw error }
    try await server.close()
}

private enum LibraryRejectedFrame: String, CaseIterable, Sendable {
    case unmasked, binary, reservedBit, unknownOpcode, orphanContinuation, overlappingText
    case fragmentedControl, oversizedControl, shortClose, forbiddenCloseCode, invalidCloseUTF8, invalidTextUTF8
    case oversizedFrame, oversizedAggregate

    var bytes: [UInt8] {
        let ping = Array(#"{"type":"ping"}"#.utf8)
        switch self {
        case .unmasked: return MachineCommandWebSocket.encode(opcode: 1, payload: ping)
        case .binary: return MachineCommandWebSocket.encode(opcode: 2, payload: ping, masked: true)
        case .reservedBit: return MachineCommandWebSocket.encode(opcode: 1, payload: ping, masked: true, rsv1: true)
        case .unknownOpcode: return MachineCommandWebSocket.encode(opcode: 3, payload: ping, masked: true)
        case .orphanContinuation: return MachineCommandWebSocket.encode(opcode: 0, payload: ping, masked: true)
        case .overlappingText:
            return MachineCommandWebSocket.encode(opcode: 1, payload: [123], masked: true, fin: false)
                + MachineCommandWebSocket.encode(opcode: 1, payload: ping, masked: true)
        case .fragmentedControl: return MachineCommandWebSocket.encode(opcode: 9, payload: [1], masked: true, fin: false)
        case .oversizedControl: return MachineCommandWebSocket.encode(opcode: 9, payload: Array(repeating: 1, count: 126), masked: true)
        case .shortClose: return MachineCommandWebSocket.encode(opcode: 8, payload: [3], masked: true)
        case .forbiddenCloseCode: return MachineCommandWebSocket.encode(opcode: 8, payload: [3, 237], masked: true)
        case .invalidCloseUTF8: return MachineCommandWebSocket.encode(opcode: 8, payload: [3, 232, 255], masked: true)
        case .invalidTextUTF8: return MachineCommandWebSocket.encode(opcode: 1, payload: [255], masked: true)
        case .oversizedFrame: return MachineCommandWebSocket.encode(opcode: 1, payload: Array(repeating: 97, count: 1_048_577), masked: true)
        case .oversizedAggregate:
            return MachineCommandWebSocket.encode(opcode: 1, payload: Array(repeating: 97, count: 700_000), masked: true, fin: false)
                + MachineCommandWebSocket.encode(opcode: 0, payload: Array(repeating: 97, count: 400_000), masked: true)
        }
    }
}

@Test(arguments: LibraryRejectedFrame.allCases)
private func libraryMachineWireRejectsInvalidFramesBeforeApplicationOutput(_ rejected: LibraryRejectedFrame) async throws {
    let server = try await MachineConnectServer.start(lookup: LibraryWireLookup(), commandRegistry: MachineCommandRegistry())
    do {
        let peer = try await LibraryWirePeer(port: server.port)
        do {
            try await peer.sendRaw(Array(LibraryWirePeer.upgrade.utf8))
            _ = try await peer.waitForFrame { $0.text?.contains("machine:context") == true }
            // The peer may close as soon as an oversized header is decoded.
            // A failed large write is acceptable only if actual close follows.
            do { try await peer.sendRaw(rejected.bytes) } catch { }
            try await peer.waitForClose()
            #expect(peer.frames.count == 1)
            #expect(peer.frames[0].text?.contains("machine:context") == true)
            try await peer.close()
        } catch { try? await peer.close(); throw error }
    } catch { try? await server.close(); throw error }
    try await server.close()
}

private func waitForLibraryUpgradeGate(_ gate: LibraryUpgradeGate) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { for await _ in gate.entered { return } }
        group.addTask { try await Task.sleep(for: .seconds(3)); throw LibraryWireTimeout() }
        _ = try await group.next()
        group.cancelAll()
    }
}

private struct LibraryWireTimeout: Error {}
private struct LibraryReceivedFrame: Sendable {
    let opcode: UInt8
    let payload: [UInt8]
    var text: String? { opcode == 1 ? String(bytes: payload, encoding: .utf8) : nil }
}
private final class LibraryWireInbox: Sendable {
    private struct State: Sendable { var header = ""; var frames: [LibraryReceivedFrame] = []; var closed = false }
    private let state = Mutex(State())
    var header: String { state.withLock { $0.header } }
    var frames: [LibraryReceivedFrame] { state.withLock { $0.frames } }
    var closed: Bool { state.withLock { $0.closed } }
    func setHeader(_ header: String) { state.withLock { $0.header = header } }
    func append(_ frames: [LibraryReceivedFrame]) { state.withLock { $0.frames += frames } }
    func close() { state.withLock { $0.closed = true } }
}
private final class LibraryWireHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private var header: [UInt8] = []
    private var upgraded = false
    private let codec = MachineCommandWebSocket()
    private let inbox: LibraryWireInbox
    init(inbox: LibraryWireInbox) { self.inbox = inbox }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var bytes = Array(unwrapInboundIn(data).readableBytesView)
        do {
            if !upgraded {
                header += bytes
                guard let end = header.indices.first(where: { $0 + 3 < header.count && Array(header[$0...$0 + 3]) == [13, 10, 13, 10] }) else { return }
                let text = String(decoding: header.prefix(end + 4), as: UTF8.self)
                inbox.setHeader(text)
                guard text.hasPrefix("HTTP/1.1 101") else { context.close(promise: nil); return }
                bytes = Array(header.dropFirst(end + 4)); header = []; upgraded = true
            }
            inbox.append(try codec.append(bytes, requireMask: false).map { LibraryReceivedFrame(opcode: $0.opcode, payload: $0.payload) })
        } catch { context.close(promise: nil) }
    }
    func channelInactive(context: ChannelHandlerContext) { inbox.close(); context.fireChannelInactive() }
    func errorCaught(context: ChannelHandlerContext, error: any Error) { context.close(promise: nil) }
}
private final class LibraryWirePeer: Sendable {
    static let upgrade = "GET /daemon/connect HTTP/1.1\r\nHost: example.com\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nAuthorization: Bearer sk_computer_wiretest\r\n\r\n"
    private let group: MultiThreadedEventLoopGroup
    private let channel: any Channel
    private let inbox: LibraryWireInbox
    var frames: [LibraryReceivedFrame] { inbox.frames }
    var header: String { inbox.header }
    init(port: Int) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let inbox = LibraryWireInbox()
        do {
            channel = try await ClientBootstrap(group: group).channelInitializer { channel in
                let handler = NIOLoopBound(LibraryWireHandler(inbox: inbox), eventLoop: channel.eventLoop)
                return channel.eventLoop.submit { try channel.pipeline.syncOperations.addHandler(handler.value) }
            }.connect(host: "127.0.0.1", port: port).get()
        } catch { try? await group.shutdownGracefully(); throw error }
        self.group = group; self.inbox = inbox
    }
    func sendRaw(_ bytes: [UInt8]) async throws { try await channel.writeAndFlush(channel.allocator.buffer(bytes: bytes)).get() }
    func waitForFrame(since start: Int = 0, _ predicate: @Sendable (LibraryReceivedFrame) -> Bool) async throws -> LibraryReceivedFrame {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let frame = frames.dropFirst(start).first(where: predicate) { return frame }
            if inbox.closed { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw LibraryWireTimeout()
    }
    func fence(since start: Int) async throws -> [String] {
        let nonce = Array(UUID().uuidString.utf8)
        try await sendRaw(MachineCommandWebSocket.encode(opcode: 9, payload: nonce, masked: true))
        _ = try await waitForFrame(since: start) { $0.opcode == 10 && $0.payload == nonce }
        let received = frames
        let end = try #require(received.indices.first { $0 >= start && received[$0].opcode == 10 && received[$0].payload == nonce })
        return received[start..<end].compactMap(\.text)
    }
    func waitForClose() async throws {
        let deadline = Date().addingTimeInterval(5)
        while !inbox.closed && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        guard inbox.closed else { throw LibraryWireTimeout() }
    }
    func close() async throws { try? await channel.close(); try await group.shutdownGracefully() }
}

import Foundation
import Synchronization
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import RaftHTTP
import RaftPersistence
import RaftRealtime
import RaftShared
import TestSupport
import Testing
@testable import RaftServer

/// This proves the publication validator and actual hub/socket boundary. The
/// committed production outbox-to-subscriber acknowledgement is a stage gate.
@Suite struct ProductionRealtimePublicationTests: Sendable {
    @Test func rejectsCorruptEnvelopesWithOneBoundedCode() throws {
        let id = UUID()
        let rejected = [
            try effect(codec: "other-codec"),
            try effect(effectID: id, eventID: UUID()),
            try effect(kind: "agent.execution"),
            try effect(room: ""),
            try effect(room: "user:\u{0}invalid"),
            try effect(room: String(repeating: "r", count: 1_025)),
            try effect(event: ""),
            try effect(event: "message:\nnew"),
            try effect(event: String(repeating: "e", count: 129)),
            try effect(payloadJSON: "{not-json}"),
            try effect(payloadJSON: "{}], [\"injected\",{}"),
            try DurableEffect(kind: DurableEffectKind("realtime.publish"), payload: Data("{}".utf8)),
        ]
        for row in rejected {
            #expect(throws: ProductionRealtimePublicationDelivery.Failure.rejected) {
                try ProductionRealtimePublicationDelivery.validate(row)
            }
        }
    }

    @Test func originalPublicationReachesAuthenticatedSocketAndRejectedOneCannotPassFence() async throws {
        let scene = OAuthScene()
        let userID = UUID().uuidString.lowercased()
        scene.auth.addAccount(id: userID, email: "publication-\(userID)@slock.test", password: "publication-fixture-password")
        let token = scene.auth.mintAccessTokenForTesting(userId: userID)
        let serverID = UUID().uuidString.lowercased()
        scene.oauth.addOwnedServer(id: serverID, slug: "publication-\(serverID)", name: "Publication fixture", ownerId: userID)
        let hub = RealtimeHub()
        let server = try await RealtimeServer.start(auth: LedgerRealtimeAuth(
            authCore: scene.services.identity.core, membership: scene.services.messaging.socketMembership
        ), hub: hub)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let socket = try await connect(port: server.port, group: group)
            try await socket.executeThenClose { inbound, outbound in
                var incoming = inbound.makeAsyncIterator()
                let open = try await nextText(&incoming)
                try #require(open.hasPrefix("0{"))
                let authData = try JSONEncoder().encode(["token": token, "serverId": serverID])
                try await outbound.write(textFrame("40" + String(decoding: authData, as: UTF8.self)))
                let connected = try await nextText(&incoming)
                try #require(connected.hasPrefix("40"))
                let joined = try await nextText(&incoming)
                try #require(joined == "42[\"rooms:joined\"]")

                let room = "user:\(userID)"
                let nonce = UUID().uuidString.lowercased()
                // Spaces, escapes, fractional spelling and a wide JSON integer
                // must survive unchanged. There is no outcome-fingerprint policy.
                let payload = " { \"id\":\"\(nonce)\", \"content\":\"é😀 \\\"quoted\\\"\\n\", \"fraction\":1.2500, \"wide\":18446744073709551615 } "
                try ProductionRealtimePublicationDelivery.publish(try effect(room: room, payloadJSON: payload), hub: hub)
                let delivered = try await nextText(&incoming)
                #expect(delivered == "42[\"message:new\",\(payload)]")

                // The same room's fresh FIFO fence closes this observation
                // window. No timeout or private callback count proves absence.
                let fence = UUID().uuidString.lowercased()
                let bad = try effect(room: room, event: "publication:rejected", payloadJSON: "{broken}")
                #expect(throws: ProductionRealtimePublicationDelivery.Failure.rejected) {
                    try ProductionRealtimePublicationDelivery.publish(bad, hub: hub)
                }
                hub.emit(room: room, event: "publication:fence", payloadJSON: "{\"nonce\":\"\(fence)\"}")
                let expectedFence = "42[\"publication:fence\",{\"nonce\":\"\(fence)\"}]"
                var reachedFence = false
                for _ in 0..<8 {
                    let frame = try await nextText(&incoming)
                    #expect(!frame.hasPrefix("42[\"publication:rejected\","))
                    if frame == expectedFence { reachedFence = true; break }
                }
                #expect(reachedFence)
            }
            try await group.shutdownGracefully()
            try await server.close()
        } catch {
            try? await group.shutdownGracefully()
            try? await server.close()
            throw error
        }
    }

    @Test(arguments: [ProductionRealtimePublicationDelivery.HandoffOutcome.expired, .notReady])
    func queuedPublicationLosingAdmissionBeforeFlushHasNoFrameOrAcknowledgement(
        lost: ProductionRealtimePublicationDelivery.HandoffOutcome
    ) async throws {
        let scene = OAuthScene()
        let userID = UUID().uuidString.lowercased()
        scene.auth.addAccount(id: userID, email: "handoff-\(userID)@slock.test", password: "publication-fixture-password")
        let token = scene.auth.mintAccessTokenForTesting(userId: userID)
        let serverID = UUID().uuidString.lowercased()
        scene.oauth.addOwnedServer(id: serverID, slug: "handoff-\(serverID)", name: "Handoff fixture", ownerId: userID)
        let hub = RealtimeHub()
        let server = try await RealtimeServer.start(auth: LedgerRealtimeAuth(
            authCore: scene.services.identity.core, membership: scene.services.messaging.socketMembership
        ), hub: hub)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let socket = try await connect(port: server.port, group: group)
            try await socket.executeThenClose { inbound, outbound in
                var incoming = inbound.makeAsyncIterator()
                let open = try await nextText(&incoming)
                try #require(open.hasPrefix("0{"))
                let authData = try JSONEncoder().encode(["token": token, "serverId": serverID])
                try await outbound.write(textFrame("40" + String(decoding: authData, as: UTF8.self)))
                let connected = try await nextText(&incoming)
                try #require(connected.hasPrefix("40"))
                let joined = try await nextText(&incoming)
                try #require(joined == "42[\"rooms:joined\"]")

                let room = "user:\(userID)"
                let clock = Mutex(Date())
                let ready = Mutex(true)
                let expiresAt = clock.withLock { $0.addingTimeInterval(60) }
                let fence = UUID().uuidString.lowercased()
                let fencePayload = "{\"nonce\":\"\(fence)\"}"
                let context = TransactionContext(domain: TransactionDomain())
                // This is a volatile transaction/controlled-time socket check,
                // not PostgreSQL COMMIT or durable-acknowledgement evidence.
                let (skipped, delivered) = try await withTransactionContext(context) {
                    let queuedAt = clock.withLock { $0 }
                    let readyAtQueue = ready.withLock { $0 }
                    #expect(expiresAt > queuedAt)
                    #expect(readyAtQueue)
                    let skipped = try ProductionRealtimePublicationDelivery.enqueue(
                        try effect(room: room, event: "publication:lost-before-flush"),
                        hub: hub, expiresAt: expiresAt,
                        isReady: { ready.withLock { $0 } }, now: { clock.withLock { $0 } }
                    )
                    #expect(skipped.outcome == .queued)
                    #expect(throws: PersistenceError.outboxClaimLost) {
                        try skipped.requireHandoffForAcknowledgement()
                    }
                    if lost == .expired {
                        clock.withLock { $0 = expiresAt.addingTimeInterval(1) }
                    } else {
                        ready.withLock { $0 = false }
                    }
                    let delivered = try ProductionRealtimePublicationDelivery.enqueue(
                        try effect(room: room, event: "publication:handoff-fence", payloadJSON: fencePayload),
                        hub: hub, expiresAt: clock.withLock { $0.addingTimeInterval(60) },
                        isReady: { true }, now: { clock.withLock { $0 } }
                    )
                    try context.prepareCommit()
                    context.publishCommitted()
                    context.flushDeferredEffects()
                    return (skipped, delivered)
                }
                #expect(skipped.outcome == lost)
                // This is the exact worker gate before markDelivered, not an ACK spy.
                #expect(throws: PersistenceError.outboxClaimLost) {
                    try skipped.requireHandoffForAcknowledgement()
                }
                #expect(delivered.outcome == .handedOff)
                try delivered.requireHandoffForAcknowledgement()
                // Both effects shared one FIFO flush and one room. Seeing the
                // fresh fence first proves the skipped publication emitted no frame.
                let actual = try await nextText(&incoming)
                #expect(actual == "42[\"publication:handoff-fence\",\(fencePayload)]")
            }
            try await group.shutdownGracefully()
            try await server.close()
        } catch {
            try? await group.shutdownGracefully()
            try? await server.close()
            throw error
        }
    }

    private struct Envelope: Encodable {
        let codec: String
        let eventId: UUID
        let room: String
        let event: String
        let payloadJSON: String
    }

    private func effect(
        effectID: UUID = UUID(), eventID: UUID? = nil,
        kind: String = "realtime.publish", codec: String = "raft-realtime-publication-v1",
        room: String = "user:publication-fixture", event: String = "message:new", payloadJSON: String = "{}"
    ) throws -> DurableEffect {
        try DurableEffect(effectID: effectID, kind: DurableEffectKind(kind), payload: JSONEncoder().encode(Envelope(
            codec: codec, eventId: eventID ?? effectID, room: room, event: event, payloadJSON: payloadJSON
        )))
    }

    private enum WireFailure: Error { case refused, closed, invalidText }
    private typealias Socket = NIOAsyncChannel<WebSocketFrame, WebSocketFrame>

    private func connect(port: Int, group: MultiThreadedEventLoopGroup) async throws -> Socket {
        let upgraded: EventLoopFuture<Socket> = try await ClientBootstrap(group: group)
            .connectTimeout(.seconds(2))
            .connect(host: "127.0.0.1", port: port) { channel in
                // Bound the real peer's lifetime, including handshake and reads.
                let deadline = channel.eventLoop.scheduleTask(in: .seconds(8)) { channel.close(promise: nil) }
                channel.closeFuture.whenComplete { _ in deadline.cancel() }
                let upgrader = NIOTypedWebSocketClientUpgrader<Socket>(maxFrameSize: 1_048_576) { channel, _ in
                    channel.eventLoop.makeCompletedFuture {
                        try Socket(wrappingChannelSynchronously: channel)
                    }
                }
                let request = HTTPRequestHead(version: .http1_1, method: .GET,
                    uri: "/socket.io/?EIO=4&transport=websocket", headers: HTTPHeaders([("Host", "127.0.0.1:\(port)")]))
                let upgrade = NIOTypedHTTPClientUpgradeConfiguration(upgradeRequestHead: request, upgraders: [upgrader]) { channel in
                    channel.close().flatMapThrowing { throw WireFailure.refused }
                }
                var configuration = NIOUpgradableHTTPClientPipelineConfiguration(upgradeConfiguration: upgrade)
                configuration.leftOverBytesStrategy = .forwardBytes
                return channel.pipeline.configureUpgradableHTTPClientPipeline(configuration: configuration)
            }
        return try await upgraded.get()
    }

    private func textFrame(_ text: String) -> WebSocketFrame {
        var buffer = ByteBufferAllocator().buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        return WebSocketFrame(fin: true, opcode: .text, maskKey: .random(), data: buffer)
    }

    private func nextText(
        _ incoming: inout NIOAsyncChannelInboundStream<WebSocketFrame>.AsyncIterator
    ) async throws -> String {
        while let frame = try await incoming.next() {
            if frame.opcode == .connectionClose { throw WireFailure.closed }
            guard frame.opcode == .text else { continue }
            var buffer = frame.unmaskedData
            guard frame.fin, let text = buffer.readString(length: buffer.readableBytes)
            else { throw WireFailure.invalidText }
            return text
        }
        throw WireFailure.closed
    }
}

import Foundation
import Synchronization
import NIOCore

/// Per-Engine.IO-session Socket.IO namespace state: handshake auth, rooms,
/// events, desktop attention and the application heartbeat. Every method runs
/// on the engine session's owner loop; `NIOLoopBound` in the connection
/// handler makes that ownership explicit.
final class RealtimeSocketIOSession {
    private let auth: any RealtimeAuthorizing
    private let hub: RealtimeHub
    private let desktopAttention: DesktopAttentionRegistry
    private let heartbeat: RealtimeHeartbeatConfiguration
    private let ownerLoop: any EventLoop

    weak var engine: EngineIOSession?
    private var session: SocketIOSession?
    private var desktopAttentionHandler: DesktopAttentionHandler?

    private var applicationHeartbeatActive = false
    private var applicationHeartbeatGeneration = 0
    private var applicationHeartbeatTimer: Scheduled<Void>?

    init(
        auth: any RealtimeAuthorizing,
        hub: RealtimeHub,
        desktopAttention: DesktopAttentionRegistry,
        heartbeat: RealtimeHeartbeatConfiguration,
        ownerLoop: any EventLoop
    ) {
        self.auth = auth
        self.hub = hub
        self.desktopAttention = desktopAttention
        self.heartbeat = heartbeat
        self.ownerLoop = ownerLoop
    }

    func receive(_ packet: String) {
        ownerLoop.preconditionInEventLoop()
        guard let engine, !engine.isClosed else { return }
        if packet == "1" {
            stopApplicationHeartbeat()
            if let session {
                session.close()
            } else {
                engine.close()
            }
            return
        }
        if packet.hasPrefix("0") {
            guard session == nil else {
                engine.close()
                return
            }
            connect(payload: String(packet.dropFirst()), engine: engine)
            return
        }
        guard let session else {
            engine.close()
            return
        }
        if packet.hasPrefix("2") {
            handleEvent(String(packet.dropFirst()), session: session)
        } else if packet.hasPrefix("3") {
            // Incoming ACK packet. No upstream namespace handler registers a
            // server-side acknowledgement, matching the current WS transport.
        } else if packet.hasPrefix("4") {
            // Socket.IO error packet from a client is ignored by upstream.
        } else {
            engine.close()
        }
    }

    private func connect(payload: String, engine: EngineIOSession) {
        let parsed = parseSocketHandshakeAuth(Data(payload.utf8))
        let handshake: SocketHandshakeAuth
        switch parsed {
        case .success(let value): handshake = value
        case .failure:
            engine.enqueueFinal(socketIOErrorFrame("Authentication required"))
            return
        }
        guard let identity = auth.sessionIdentity(forAccessToken: handshake.token) else {
            engine.enqueueFinal(socketIOErrorFrame("Invalid or expired token"))
            return
        }
        let userId = identity.userId
        let session = SocketIOSession(
            id: socketIOGeneratedID(), userId: userId,
            serverId: handshake.serverId, clientKind: handshake.clientKind,
            familyId: identity.familyId, pending: true,
            send: { [weak engine] frame in engine?.enqueue(frame) },
            sendAndClose: { [weak engine] frame in engine?.enqueueFinal(frame) },
            close: { [weak engine] in engine?.close() }
        )
        self.session = session
        hub.register(session)
        engine.adopt(session)

        let role: String?
        let channelIds: [String]
        if let serverId = handshake.serverId {
            role = auth.serverRole(serverId: serverId, userId: userId)
            guard role != nil else {
                engine.enqueueFinal(socketIOErrorFrame(socketNotServerMemberMessage))
                return
            }
            channelIds = auth.visibleChannelIds(serverId: serverId, userId: userId)
        } else {
            role = nil
            channelIds = []
        }
        guard auth.sessionIdentity(forAccessToken: handshake.token) == identity, session.admit() else {
            session.close()
            return
        }
        desktopAttentionHandler = DesktopAttentionHandler(
            userId: userId, clientKind: handshake.clientKind, recorder: desktopAttention
        )
        session.send(socketIOConnectFrame(sid: session.id))
        session.join(["user:\(userId)", socketClientKindRoom(userId: userId, clientKind: handshake.clientKind)])
        if let serverId = handshake.serverId {
            if role == "guest" { session.join([socketServerGuestsRoom(serverId: serverId)]) }
            else { session.join(["server:\(serverId)"]) }
            session.join([socketUserServerRoom(userId: userId, serverId: serverId)])
            session.join(channelIds.map { "channel:\($0)" })
            session.send(socketIOEventFrame("rooms:joined"))
            startApplicationHeartbeat(serverId: serverId)
        }
    }

    private struct EventPacket: Decodable {
        struct SyncResume: Decodable { var lastSeq: Int }
        struct Attention: Decodable { var attended: Bool? }

        var name: String
        var channel: String?
        var lastSeq: Int?
        var attended: Bool?

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            name = try container.decode(String.self)
            guard !container.isAtEnd else { return }
            switch name {
            case "join:channel", "leave:channel":
                channel = try? container.decode(String.self)
            case "sync:resume":
                lastSeq = (try? container.decode(SyncResume.self))?.lastSeq
            case DesktopAttentionEvents.eventName:
                attended = (try? container.decode(Attention.self))?.attended
            default:
                break
            }
        }
    }

    private func handleEvent(_ payload: String, session: SocketIOSession) {
        guard let data = payload.data(using: .utf8),
              let event = try? JSONDecoder().decode(EventPacket.self, from: data)
        else { return }
        if event.name == DesktopAttentionEvents.eventName {
            desktopAttentionHandler?.handle(attended: event.attended)
            return
        }
        guard let serverId = session.serverId else { return }
        let userId = session.userId
        switch event.name {
        case "join:channel":
            guard let channelId = event.channel, !channelId.isEmpty else { return }
            guard auth.visibleChannelIds(serverId: serverId, userId: userId).contains(channelId) else { return }
            session.join(["channel:\(channelId)"])
        case "leave:channel":
            guard let channelId = event.channel else { return }
            session.leave("channel:\(channelId)")
        case "sync:resume":
            guard let lastSeq = event.lastSeq, lastSeq > 0 else { return }
            guard let body = auth.syncResumePayload(
                serverId: serverId, userId: userId, lastSeq: lastSeq, limit: socketResumeLimit
            ) else { return }
            session.send(socketIOEventFrame("sync:resume:response", payloadJSON: body))
        default:
            break
        }
    }

    // MARK: - Application-level `heartbeat` event

    private func startApplicationHeartbeat(serverId: String) {
        ownerLoop.preconditionInEventLoop()
        guard heartbeat.applicationIntervalMilliseconds > 0 else { return }
        applicationHeartbeatActive = true
        armApplicationHeartbeat(serverId: serverId)
    }

    private func armApplicationHeartbeat(serverId: String) {
        ownerLoop.preconditionInEventLoop()
        applicationHeartbeatGeneration += 1
        let generation = applicationHeartbeatGeneration
        applicationHeartbeatTimer?.cancel()
        let bound = NIOLoopBound(self, eventLoop: ownerLoop)
        applicationHeartbeatTimer = ownerLoop.scheduleTask(
            in: .milliseconds(Int64(heartbeat.applicationIntervalMilliseconds))
        ) {
            bound.value.applicationHeartbeatFired(generation: generation, serverId: serverId)
        }
    }

    private func applicationHeartbeatFired(generation: Int, serverId: String) {
        ownerLoop.preconditionInEventLoop()
        applicationHeartbeatTimer = nil
        guard applicationHeartbeatActive,
              applicationHeartbeatGeneration == generation,
              engine?.isClosed != true,
              let session,
              !session.isClosed
        else { return }
        if let seq = auth.maxMessageSeq(serverId: serverId) {
            let timestamp = Int(Date().timeIntervalSince1970 * 1000)
            session.send(socketIOApplicationHeartbeatFrame(seq: seq, timestampMilliseconds: timestamp))
        }
        armApplicationHeartbeat(serverId: serverId)
    }

    private func stopApplicationHeartbeat() {
        applicationHeartbeatActive = false
        applicationHeartbeatGeneration += 1
        applicationHeartbeatTimer?.cancel()
        applicationHeartbeatTimer = nil
    }
}

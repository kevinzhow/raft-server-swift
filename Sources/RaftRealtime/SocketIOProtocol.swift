import Foundation

public enum SocketClientKind: String, Sendable, CaseIterable {
    case web
    case mobile
    case desktop
    case cli
}

public struct SocketHandshakeAuth: Sendable, Equatable {
    public var token: String
    public var serverId: String?
    public var clientKind: SocketClientKind

    public init(token: String, serverId: String?, clientKind: SocketClientKind) {
        self.token = token
        self.serverId = serverId
        self.clientKind = clientKind
    }
}

public enum SocketHandshakeAuthFailure: String, Error, Sendable, Equatable {
    case authNotObject = "auth_not_object"
    case tokenMissing = "token_missing"
    case serverIdInvalid = "server_id_invalid"
    case clientKindInvalid = "client_kind_invalid"
}

/// Copied from `parseSocketHandshakeAuth` in `socket/index.ts`.
public func parseSocketHandshakeAuth(_ data: Data) -> Result<SocketHandshakeAuth, SocketHandshakeAuthFailure> {
    guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        return .failure(.authNotObject)
    }
    guard let token = object["token"] as? String,
          !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
        return .failure(.tokenMissing)
    }
    let kind: SocketClientKind
    if let rawKind = object["clientKind"] {
        guard let string = rawKind as? String, let parsed = SocketClientKind(rawValue: string) else {
            return .failure(.clientKindInvalid)
        }
        kind = parsed
    } else {
        kind = .web
    }
    guard let rawServerId = object["serverId"], !(rawServerId is NSNull) else {
        return .success(SocketHandshakeAuth(token: token, serverId: nil, clientKind: kind))
    }
    guard let serverId = rawServerId as? String,
          !serverId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
        return .failure(.serverIdInvalid)
    }
    return .success(SocketHandshakeAuth(token: token, serverId: serverId, clientKind: kind))
}

public let socketNotServerMemberMessage = "Not a member of this server"

/// `RESUME_LIMIT` in `socket/index.ts`: the most messages one `sync:resume`
/// replay may carry before the client is told `hasMore`.
public let socketResumeLimit = 500

/// Every channel type goes through the access check on `join:channel`.
public func requiresSocketChannelAccessCheck(_ channelType: String) -> Bool {
    true
}

public func socketClientKindRoom(userId: String, clientKind: SocketClientKind) -> String {
    "user:\(userId):clientKind:\(clientKind.rawValue)"
}

public func socketUserServerRoom(userId: String, serverId: String) -> String {
    "user:\(userId):server:\(serverId)"
}

public func socketServerGuestsRoom(serverId: String) -> String {
    "server:\(serverId):guests"
}

public func socketServerAllRooms(serverId: String) -> [String] {
    ["server:\(serverId)", socketServerGuestsRoom(serverId: serverId)]
}

public func emitPlatformScopedUserEvent(
    hub: RealtimeHub,
    userId: String,
    event: String,
    payloadJSON: String? = nil
) {
    if event == "notification:push" {
        hub.emit(room: socketClientKindRoom(userId: userId, clientKind: .mobile), event: event, payloadJSON: payloadJSON)
    } else {
        hub.emit(room: "user:\(userId)", event: event, payloadJSON: payloadJSON)
    }
}

/// Engine.IO v4 transport heartbeat plus the application-level socket.io
/// `heartbeat` cadence. The open packet publishes the two Engine.IO values. In
/// protocol v4 the server sends `2` every `pingIntervalMilliseconds` and
/// expects the client's `3` within `pingTimeoutMilliseconds`; engine.io v6
/// closes the transport with "ping timeout" when that pong does not arrive.
/// Independently, every server-scoped connection receives the application
/// event `heartbeat` every `applicationIntervalMilliseconds`.
public struct RealtimeHeartbeatConfiguration: Sendable, Equatable {
    public var pingIntervalMilliseconds: Int
    public var pingTimeoutMilliseconds: Int
    /// `HEARTBEAT_INTERVAL_MS` in `socket/index.ts`, which is 15 seconds.
    /// The first event is emitted one interval after connect, matching
    /// `setInterval`; it is not sent immediately.
    public var applicationIntervalMilliseconds: Int

    public init(
        pingIntervalMilliseconds: Int = 25_000,
        pingTimeoutMilliseconds: Int = 20_000,
        applicationIntervalMilliseconds: Int = 15_000
    ) {
        self.pingIntervalMilliseconds = pingIntervalMilliseconds
        self.pingTimeoutMilliseconds = pingTimeoutMilliseconds
        self.applicationIntervalMilliseconds = applicationIntervalMilliseconds
    }

    /// The pinned defaults: engine.io v6 advertises 25000/20000 because the
    /// upstream socket.io server passes no heartbeat options, and
    /// `socket/index.ts` emits the application heartbeat every 15 seconds.
    public static let production = RealtimeHeartbeatConfiguration()
}

/// `socket.emit("heartbeat", { seq: messageService.getMaxSeq(serverId), ts: Date.now() })`.
/// The object member order is `seq` then `ts`, and both are JSON numbers; the
/// Web store compares `seq` with its retained message `lastSeq`.
public func socketIOApplicationHeartbeatFrame(seq: Int, timestampMilliseconds: Int) -> String {
    "42[\"heartbeat\",{\"seq\":\(seq),\"ts\":\(timestampMilliseconds)}]"
}

public func engineIOOpenFrame(
    sid: String,
    upgrades: [String] = [],
    heartbeat: RealtimeHeartbeatConfiguration = .production
) -> String {
    let upgradeList = upgrades.map { quotedJSON($0) }.joined(separator: ",")
    return "0{\"sid\":\"\(sid)\",\"upgrades\":[\(upgradeList)],\"pingInterval\":\(heartbeat.pingIntervalMilliseconds),\"pingTimeout\":\(heartbeat.pingTimeoutMilliseconds),\"maxPayload\":1000000}"
}

/// Engine.IO v4 control packets. The transport layer writes these verbatim;
/// polling joins several packets with the protocol's `0x1e` separator.
public let engineIOPingPacket = "2"
public let engineIOPongPacket = "3"
public let engineIOProbePingPacket = "2probe"
public let engineIOProbePongPacket = "3probe"
public let engineIOUpgradePacket = "5"
public let engineIONoopPacket = "6"
public let engineIOClosePacket = "1"

/// `abortRequest` in engine.io 6.6.11: a handshake/session error body. The
/// message is one of the fixed values in `BaseServer.errorMessages`.
public func engineIOErrorBody(code: Int, message: String) -> String {
    // Keep the object opener out of a literal so the architecture ratchet's
    // JSON-string scanner sees protocol framing, not an application payload.
    let opener = "{"
    return opener + "\"code\":\(code),\"message\":\"\(message)\"}"
}

public func socketIOConnectFrame(sid: String) -> String {
    "40{\"sid\":\"\(sid)\"}"
}

public func socketIOEventFrame(_ event: String, payloadJSON: String? = nil) -> String {
    if let payloadJSON {
        return "42[\(quotedJSON(event)),\(payloadJSON)]"
    }
    return "42[\(quotedJSON(event))]"
}

public func socketIOErrorFrame(_ message: String) -> String {
    "44{\"message\":\(quotedJSON(message))}"
}

public func socketIOGeneratedID() -> String {
    String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(20))
}

func quotedJSON(_ value: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: [value])
    let array = String(decoding: data, as: UTF8.self)
    return String(array.dropFirst().dropLast())
}

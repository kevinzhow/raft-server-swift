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

public func engineIOOpenFrame(sid: String) -> String {
    "0{\"sid\":\"\(sid)\",\"upgrades\":[],\"pingInterval\":25000,\"pingTimeout\":20000,\"maxPayload\":1000000}"
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

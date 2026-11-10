import Foundation

/// `requireServerMatchesParam` from `middleware/auth.ts`.
///
/// A non-UUID `:id` is 404 `Server not found` before any query, so a bad id
/// cannot surface a database cast error. A UUID that does not equal
/// `X-Server-Id` is 400 and must stay that typed 4xx.
///
/// The path/header checks are also consumed by routes that run the whole
/// funnel inside their domain service (so authentication still precedes them);
/// `validate` is that shared, reply-free core.

public enum ServerScope {
    /// The path and header checks `requireServerMatchesParam` performs before
    /// the membership query.
    public enum PathFailure: Sendable, Equatable {
        case serverIdRequired
        case serverNotFound
        case missingHeader
        case headerMismatch
    }

    /// `nil` when the path names a UUID and `X-Server-Id` exactly matches it.
    public static func validate(serverId: String, headerServerId: String?) -> PathFailure? {
        if serverId.isEmpty {
            return .serverIdRequired
        }
        if !isUUID(serverId) {
            return .serverNotFound
        }
        guard let headerServerId, !headerServerId.isEmpty else {
            return .missingHeader
        }
        if headerServerId != serverId {
            return .headerMismatch
        }
        return nil
    }

    public static func membersGuard(serverId: String, headerServerId: String?) -> HTTPReply? {
        switch validate(serverId: serverId, headerServerId: headerServerId) {
        case nil:
            return nil
        case .serverIdRequired:
            return json(400, "Server id is required")
        case .serverNotFound:
            return json(404, "Server not found")
        case .missingHeader:
            return json(400, "Missing X-Server-Id header")
        case .headerMismatch:
            return json(400, "X-Server-Id must match server id in URL")
        }
    }

    /// `GET /:id/members/:memberId/profile`. `memberId` is guarded as `Member`
    /// after the server id and `X-Server-Id` checks. A non-UUID names no member.
    public static func memberProfile(
        serverId: String,
        headerServerId: String?,
        memberId: String
    ) -> HTTPReply {
        if let reply = membersGuard(serverId: serverId, headerServerId: headerServerId) {
            return reply
        }
        if !isUUID(memberId) {
            return json(404, "Member not found")
        }
        return json(403, "Not a member of this server")
    }

    public static func isUUID(_ value: String) -> Bool {
        value.wholeMatch(of: /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) != nil
    }

    private static func json(_ status: Int, _ error: String) -> HTTPReply {
        let body = "{\"error\":\(jsonString(error))}"
        return HTTPReply(
            status: status,
            headers: [
                "X-Robots-Tag": AppFallback.robotsTag,
                "Content-Type": AppFallback.jsonContentType,
                "Content-Length": String(Data(body.utf8).count),
            ],
            body: body
        )
    }
}

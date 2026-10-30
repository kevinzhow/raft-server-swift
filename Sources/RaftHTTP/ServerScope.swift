import Foundation

/// `requireServerMatchesParam` from `middleware/auth.ts`.
///
/// A non-UUID `:id` is 404 `Server not found` before any query, so a bad id
/// cannot surface a database cast error. A UUID that does not equal
/// `X-Server-Id` is 400 and must stay that typed 4xx.

public enum ServerScope {
    public static func membersGuard(serverId: String, headerServerId: String?) -> HTTPReply? {
        if serverId.isEmpty {
            return json(400, "Server id is required")
        }
        if !isUUID(serverId) {
            return json(404, "Server not found")
        }
        guard let headerServerId, !headerServerId.isEmpty else {
            return json(400, "Missing X-Server-Id header")
        }
        if headerServerId != serverId {
            return json(400, "X-Server-Id must match server id in URL")
        }
        return nil
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

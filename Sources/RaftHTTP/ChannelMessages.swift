import Foundation

/// `GET /api/messages/channel/:channelId`.
///
/// `guardUuidPathParams` answers a non-UUID `:channelId` with 404
/// `Channel not found` before the handler. A UUID that is not a visible
/// channel uses the shared neutral body, the same bytes as a hidden channel.

public enum ChannelMessages {
    public static func list(channelId: String) -> HTTPReply {
        if !ServerScope.isUUID(channelId) {
            return json(404, "Channel not found")
        }
        return json(404, "Channel not found or not visible")
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

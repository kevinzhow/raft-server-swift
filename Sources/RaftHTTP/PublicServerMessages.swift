import Foundation

/// Anonymous public history routes from `routes/publicServer.ts`.
///
/// `guardUuidPathParams` answers a non-UUID `:channelId` or `:threadChannelId`
/// before the handler. A UUID that is not an anonymously readable channel or
/// thread is the handler's plain `Not found`. Every reply on this router is
/// `Cache-Control: no-store`.

public enum PublicServerMessages {
    public static func channel(channelId: String) -> HTTPReply {
        guard ServerScope.isUUID(channelId) else {
            return json("Channel not found")
        }
        return json("Not found")
    }

    public static func thread(threadChannelId: String) -> HTTPReply {
        guard ServerScope.isUUID(threadChannelId) else {
            return json("Thread not found")
        }
        return json("Not found")
    }

    private static func json(_ error: String) -> HTTPReply {
        let body = "{\"error\":\(jsonString(error))}"
        return HTTPReply(
            status: 404,
            headers: [
                "X-Robots-Tag": AppFallback.robotsTag,
                "Content-Type": AppFallback.jsonContentType,
                "Cache-Control": "no-store",
                "Content-Length": String(Data(body.utf8).count),
            ],
            body: body
        )
    }
}

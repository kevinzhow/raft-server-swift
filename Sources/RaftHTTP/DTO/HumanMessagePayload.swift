import Foundation

/// Published human-message echo, also reused by idempotent replay and realtime.
struct HumanMessagePayload: JSONBodyConvertible {
    let message: StoredHumanMessage
    init(_ message: StoredHumanMessage) { self.message = message }

    var jsonBody: OrderedJSON {
        var body = OrderedJSONObject([
            OrderedJSONField("id", message.id),
            OrderedJSONField("channelId", message.channelId),
            OrderedJSONField("content", message.content),
            OrderedJSONField("attachments", .array(message.attachmentIds.map {
                .object([OrderedJSONField("id", $0)])
            })),
            OrderedJSONField("mentions", .array(message.mentions.map {
                .object([
                    OrderedJSONField("type", $0.type),
                    OrderedJSONField("id", $0.id),
                    OrderedJSONField("name", $0.name),
                ])
            })),
        ])
        body.append("randomId", ifPresent: message.randomId)
        return body.json
    }
}

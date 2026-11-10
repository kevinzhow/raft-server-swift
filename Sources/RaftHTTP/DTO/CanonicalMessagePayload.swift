import Foundation

/// One retained message projected through the canonical message manifest
/// (`packages/shared/src/canonicalMessageManifest.ts`).
///
/// The create acknowledgement and the `message:new` frame share this body: the
/// frame appends the socket-only `conversationContext`. Every value comes from
/// the committed row, its sender account and its retained attachment rows.
/// Storage-only columns (`senderTimezone`, `searchText`, `searchVector`,
/// `agentSendKey`, `serverId`) never appear on the published frontend
/// projection.
struct CanonicalMessagePayload: JSONBodyConvertible {
    /// The published sender facts: the account label/description and the
    /// channel-membership status of this message's author.
    struct Sender: Sendable, Equatable {
        var name: String
        var description: String?
        var membershipStatus: String?
    }

    /// The canonical attachment object (7 fields, no viewer-scoped comment
    /// count). `mimeType` is resolved from the stored row and filename exactly
    /// as the history read resolves it.
    struct Attachment: JSONBodyConvertible, Sendable, Equatable {
        let id: String
        let filename: String
        let mimeType: String
        let sizeBytes: Int?
        let width: Int?
        let height: Int?
        let thumbnailUrl: String?

        init(_ row: ChannelAttachment) {
            id = row.id
            filename = row.filename
            mimeType = ChannelFileRules.resolveAttachmentMimeType(filename: row.filename, stored: row.mimeType)
            sizeBytes = row.sizeBytes
            width = row.width
            height = row.height
            // The stored thumbnail key is the only retained thumbnail fact; the
            // public address follows the same attachment route the channel-file
            // projection publishes for that key.
            thumbnailUrl = row.thumbnailKey.flatMap {
                $0.isEmpty ? nil : "/api/attachments/\(row.id)/thumbnail"
            }
        }

        var jsonBody: OrderedJSON {
            .object([
                OrderedJSONField("id", id),
                OrderedJSONField("filename", filename),
                OrderedJSONField("mimeType", mimeType),
                OrderedJSONField("sizeBytes", optional: sizeBytes),
                OrderedJSONField("width", optional: width),
                OrderedJSONField("height", optional: height),
                OrderedJSONField("thumbnailUrl", optional: thumbnailUrl),
            ])
        }
    }

    let message: StoredHumanMessage
    let sender: Sender
    let attachments: [Attachment]
    let mentions: [StoredMessageMention]
    let conversationContext: OrderedJSON?

    var jsonBody: OrderedJSON {
        var body = OrderedJSONObject([
            OrderedJSONField("id", message.id),
            OrderedJSONField("seq", message.seq),
            OrderedJSONField("channelId", message.channelId),
            OrderedJSONField("senderType", message.senderType),
            OrderedJSONField("senderId", message.senderId),
            OrderedJSONField("randomId", optional: message.randomId),
            OrderedJSONField("messageType", message.messageType),
            OrderedJSONField("content", message.content),
            OrderedJSONField("actionMetadata", .null),
            OrderedJSONField("threadId", .null),
            OrderedJSONField("createdAt", DateText.isoString(message.createdAt)),
            OrderedJSONField("updatedAt", DateText.isoString(message.createdAt)),
            OrderedJSONField("senderName", sender.name),
            OrderedJSONField("senderDescription", optional: sender.description),
            OrderedJSONField("senderMembershipStatus", optional: sender.membershipStatus),
            OrderedJSONField("attachments", .array(attachments.map(\.jsonBody))),
            OrderedJSONField("mentions", .array(mentions.map { mention in
                .object([
                    OrderedJSONField("type", mention.type),
                    OrderedJSONField("id", mention.id),
                    OrderedJSONField("name", mention.name),
                ])
            })),
            // A freshly persisted row has no reactions, comment ref or external
            // author; the persisted frontend payload publishes the explicit
            // empty/null values.
            OrderedJSONField("reactions", .array([])),
            OrderedJSONField("commentRef", .null),
            OrderedJSONField("externalAuthor", .null),
        ])
        if let conversationContext {
            body.append("conversationContext", conversationContext)
        }
        return body.json
    }
}

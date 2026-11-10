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
    /// Creation-time conversation identity. Only `message:new` carries it;
    /// `message:updated` is the same canonical row without this member.
    let conversationContext: OrderedJSON?
    /// The retained forwarded-bundle / action-card metadata for an update
    /// projection. A freshly persisted ordinary row has none.
    var actionMetadata: OrderedJSON? = nil
    /// Reaction buckets in first-reaction order; empty for a fresh row.
    var reactions: [OrderedJSON] = []
    /// The scoped attachment-comment reference. Shared broadcast frames scrub
    /// it to null; only viewer-private reads carry the object.
    var commentRef: OrderedJSON? = nil
    var externalAuthor: OrderedJSON? = nil
    /// The row's retained update time; a fresh row and a reaction-only update
    /// both publish the creation time.
    var updatedAt: Date? = nil

    /// The same members `jsonBody` publishes, exposed so the thread-summary
    /// `latestReply` projection can append its display-only fields without
    /// re-rendering and re-sorting the canonical object.
    var orderedObject: OrderedJSONObject {
        var body = OrderedJSONObject([
            OrderedJSONField("id", message.id),
            OrderedJSONField("seq", message.seq),
            OrderedJSONField("channelId", message.channelId),
            OrderedJSONField("senderType", message.senderType),
            OrderedJSONField("senderId", message.senderId),
            OrderedJSONField("randomId", optional: message.randomId),
            OrderedJSONField("messageType", message.messageType),
            OrderedJSONField("content", message.content),
            OrderedJSONField("actionMetadata", actionMetadata ?? .null),
            OrderedJSONField("threadId", .null),
            OrderedJSONField("createdAt", DateText.isoString(message.createdAt)),
            OrderedJSONField("updatedAt", DateText.isoString(updatedAt ?? message.createdAt)),
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
            // The persisted frontend payload always publishes the aggregate
            // members explicitly: a freshly persisted row has no reactions,
            // comment ref or external author, while an update projection
            // carries the retained values.
            OrderedJSONField("reactions", .array(reactions)),
            OrderedJSONField("commentRef", commentRef ?? .null),
            OrderedJSONField("externalAuthor", externalAuthor ?? .null),
        ])
        if let conversationContext {
            body.append("conversationContext", conversationContext)
        }
        return body
    }

    var jsonBody: OrderedJSON { orderedObject.json }
}

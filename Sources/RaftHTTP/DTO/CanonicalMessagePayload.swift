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

    /// Canonical task facts riding the host message. The `tasks` table is the
    /// authority; the legacy `messages.task_*` columns are only a frozen
    /// rollback snapshot and are read solely when no canonical row exists.
    ///
    /// `asTask` sends project the just-created task onto the acknowledgement and
    /// the `message:new` frame; every ordinary send still publishes the six keys
    /// as `null` because upstream spreads the stored row.
    struct TaskFacts: Sendable, Equatable {
        var status: String
        var number: Int
        var assigneeType: String?
        var assigneeId: String?
        var claimedAt: String?
        var completedAt: String?

        init(_ task: TaskRecord) {
            status = task.status
            number = task.taskNumber
            assigneeType = task.assigneeType
            assigneeId = task.assigneeId
            claimedAt = task.claimedAt.map(DateText.isoString)
            completedAt = task.completedAt.map(DateText.isoString)
        }
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
            filename = AttachmentPresentationRules.normalizedFilename(row.filename)
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
    /// Canonical task facts for an `asTask` send; `nil` for every other row.
    let task: TaskFacts?
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

    init(
        message: StoredHumanMessage,
        sender: Sender,
        attachments: [Attachment],
        mentions: [StoredMessageMention],
        conversationContext: OrderedJSON?,
        task: TaskFacts? = nil,
        actionMetadata: OrderedJSON? = nil,
        reactions: [OrderedJSON] = [],
        commentRef: OrderedJSON? = nil,
        externalAuthor: OrderedJSON? = nil,
        updatedAt: Date? = nil
    ) {
        self.message = message
        self.sender = sender
        self.attachments = attachments
        self.mentions = mentions
        self.conversationContext = conversationContext
        self.task = task
        self.actionMetadata = actionMetadata
        self.reactions = reactions
        self.commentRef = commentRef
        self.externalAuthor = externalAuthor
        self.updatedAt = updatedAt
    }

    /// The same members `jsonBody` publishes, exposed so the thread-summary
    /// `latestReply` projection can append its display-only fields without
    /// re-rendering and re-sorting the canonical object.
    var orderedObject: OrderedJSONObject {
        let taskStatus = task?.status ?? message.taskStatus
        let taskNumber = task?.number ?? message.taskNumber
        let taskAssigneeType = task?.assigneeType ?? message.taskAssigneeType
        let taskAssigneeId = task?.assigneeId ?? message.taskAssigneeId
        let taskClaimedAt = task?.claimedAt ?? message.taskClaimedAt
        let taskCompletedAt = task?.completedAt ?? message.taskCompletedAt
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
            // The stored row is spread upstream, so the task-domain projection
            // keys are always present. A canonical `asTask` task wins over the
            // frozen row columns, matching the read/mutation tie-break.
            OrderedJSONField("taskStatus", optional: taskStatus),
            OrderedJSONField("taskNumber", optional: taskNumber),
            OrderedJSONField("taskAssigneeType", optional: taskAssigneeType),
            OrderedJSONField("taskAssigneeId", optional: taskAssigneeId),
            OrderedJSONField("taskClaimedAt", optional: taskClaimedAt),
            OrderedJSONField("taskCompletedAt", optional: taskCompletedAt),
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

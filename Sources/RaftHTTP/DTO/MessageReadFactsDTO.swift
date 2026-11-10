import Foundation

/// Canonical retained message facts used by every production cold-read carrier.
/// Route-local metadata (forward/action cards and comment visibility) stays with
/// its existing policy owner. No URL, storage key, watermark or epoch is invented.
public struct MessageReadFactsDTO: Sendable, Equatable {
    let id: String
    let channelId: String
    let seq: Int
    let senderId: String
    let senderType: String
    let senderName: String?
    let senderHandle: String?
    let senderDisplayName: String?
    let senderDescription: String?
    let senderAvatarUrl: String?
    let senderMembershipStatus: String?
    let messageType: String
    let content: String
    let createdAt: String
    let randomId: String?
    let threadId: String?
    let conversationContext: OrderedJSON?
    let attachments: [InboxAttachmentChipDTO]
    let reactions: OrderedJSON
    let mentions: [InboxMentionDTO]
    let taskCurrentProjection: TaskCurrentProjectionDTO?
    /// Factual optional fields from the retained message; built in one place.
    let retained: [OrderedJSONField]

    var fields: [OrderedJSONField] {
        var result: [OrderedJSONField] = [
            .init("id", id), .init("channelId", channelId), .init("seq", seq),
            .init("senderId", senderId), .init("senderType", senderType),
            .init("senderAvatarUrl", optional: senderAvatarUrl),
            .init("senderMembershipStatus", optional: senderMembershipStatus),
            .init("messageType", messageType), .init("content", content),
            .init("createdAt", createdAt), .init("randomId", optional: randomId),
            .init("threadId", optional: threadId),
            .init("attachments", .array(attachments.map(\.jsonBody))),
            .init("reactions", reactions), .init("mentions", .array(mentions.map(\.jsonBody))),
        ]
        if let senderName { result.append(.init("senderName", senderName)) }
        if let senderHandle { result.append(.init("senderHandle", senderHandle)) }
        if let senderDisplayName { result.append(.init("senderDisplayName", senderDisplayName)) }
        if let senderDescription { result.append(.init("senderDescription", senderDescription)) }
        if let conversationContext { result.append(.init("conversationContext", conversationContext)) }
        if let taskCurrentProjection { result.append(.init("taskCurrentProjection", taskCurrentProjection.jsonBody)) }
        return result + retained
    }

    /// Keep each carrier's established member order and private fragments while
    /// replacing common values with the same authoritative facts. Missing common
    /// fields are appended once; duplicate JSON keys are never emitted.
    func merging(into body: OrderedJSON) -> OrderedJSON {
        guard case .object(let original) = body else { return body }
        let canonical = fields
        let values = Dictionary(uniqueKeysWithValues: canonical.map { ($0.key, $0.value) })
        let existing = Set(original.map(\.key))
        return .object(original.map { field in
            values[field.key].map { OrderedJSONField(field.key, $0) } ?? field
        } + canonical.filter { !existing.contains($0.key) })
    }
}

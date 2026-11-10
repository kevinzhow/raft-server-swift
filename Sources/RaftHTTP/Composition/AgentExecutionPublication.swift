import Crypto
import Foundation
import RaftShared

/// Stages publication beside business rows. Unsealed in-memory graphs can emit
/// directly; production graphs require the ambient durable transaction.
enum AgentExecutionPublication {
    static func eventId(room: String, event: String, identity: String) -> UUID {
        let key = "raft-realtime-publication-v1\u{0}\(room)\u{0}\(event)\u{0}\(identity)"
        var bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }
        let text = hex[0..<4].joined() + "-" + hex[4..<6].joined() + "-" + hex[6..<8].joined()
            + "-" + hex[8..<10].joined() + "-" + hex[10..<16].joined()
        return UUID(uuidString: text)!
    }

    static func publish(
        room: String, event: String, identity: String, payloadJSON: String,
        emit: @escaping @Sendable (String, String, String) -> Void
    ) throws {
        do {
            try DeferredEffects.requireDurableTransaction(in: .shared)
        } catch {
            guard !TransactionDomain.shared.isReadOnlyUnscoped else { throw error }
            emit(room, event, payloadJSON)
            return
        }
        do {
            let publication = RealtimePublication(
                eventId: eventId(room: room, event: event, identity: identity),
                room: room, event: event, payloadJSON: payloadJSON)
            try DeferredEffects.persist(kind: "realtime.publish", payload: JSONEncoder().encode(publication), effectID: publication.eventId)
        } catch {
            DeferredEffects.markRollbackOnly()
            throw error
        }
    }

    private static func baseMessagePayload(_ message: StoredHumanMessage, senderName: String) -> OrderedJSONObject {
        OrderedJSONObject([
            .init("id", message.id), .init("seq", message.seq), .init("channelId", message.channelId),
            .init("senderType", message.senderType), .init("senderId", message.senderId), .init("randomId", optional: message.randomId),
            .init("messageType", message.messageType), .init("content", message.content),
            .init("actionMetadata", .null), .init("threadId", .null),
            .init("taskStatus", optional: message.taskStatus), .init("taskNumber", optional: message.taskNumber),
            .init("taskAssigneeType", optional: message.taskAssigneeType), .init("taskAssigneeId", optional: message.taskAssigneeId),
            .init("taskClaimedAt", optional: message.taskClaimedAt), .init("taskCompletedAt", optional: message.taskCompletedAt),
            .init("createdAt", DateText.isoString(message.createdAt)), .init("updatedAt", DateText.isoString(message.createdAt)),
            .init("senderName", senderName),
        ])
    }

    static func messagePayload(_ message: StoredHumanMessage, senderName: String, includeAttachments: Bool = false) -> String {
        var payload = baseMessagePayload(message, senderName: senderName)
        if includeAttachments {
            payload.append("attachments", .array(message.attachmentIds.map { .object([.init("id", $0)]) }))
            payload.append("mentions", .array(message.mentions.map { .object([.init("type", $0.type), .init("id", $0.id), .init("name", $0.name)]) }))
        }
        return payload.json.render()
    }

    /// Node's system broadcaster uses the rich frontend projection. Causal actor
    /// metadata belongs to the human/agent that caused the event; its persisted
    /// sender identity remains user/system rather than an invented account.
    static func systemMessagePayload(_ message: StoredHumanMessage, channelType: String,
                                     parentMessageId: String? = nil, parentChannelId: String? = nil,
                                     parentChannelType: String? = nil) -> String {
        var payload = baseMessagePayload(message, senderName: "System")
        payload.append("causalActorType", optional: message.causalActorType)
        payload.append("causalActorId", optional: message.causalActorId)
        payload.append("systemSubtype", optional: message.systemSubtype)
        payload.append("senderDescription", .null)
        payload.append("senderMembershipStatus", .null)
        payload.append("attachments", .array([]))
        payload.append("mentions", .array([]))
        payload.append("reactions", .array([]))
        payload.append("commentRef", .null)
        payload.append("externalAuthor", .null)
        var context = OrderedJSONObject([.init("channelType", channelType)])
        if channelType == "thread", let parentMessageId, let parentChannelId, let parentChannelType {
            context.append("parentMessageId", parentMessageId)
            context.append("parentChannelId", parentChannelId)
            context.append("parentChannelType", parentChannelType)
        }
        payload.append("conversationContext", context.json)
        return payload.json.render()
    }
}

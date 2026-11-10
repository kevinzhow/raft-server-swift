import Foundation

/// `GET /api/messages/context/:messageId` id checks from `routes/messages.ts`.
///
/// A path id must be a full UUID or an 8-hex short id before any lookup.
/// A present `channelId` that is not a UUID is 400. A short id matches the
/// half-open prefix range and is a hit only when that channel has exactly one
/// row, which is what `getMessageContextByShortId` returns.

public struct ContextMessage: Equatable, Sendable {
    public var id: String
    public var channelId: String
    public var content: String
    public var seq: Int

    public init(id: String, channelId: String, content: String, seq: Int) {
        self.id = id
        self.channelId = channelId
        self.content = content
        self.seq = seq
    }
}

/// One server's local joint channel, whose messages are stored on the canonical channel.
public struct JointChannelProjection: Equatable, Sendable {
    public var localChannelId: String
    public var canonicalChannelId: String
    public var serverId: String
    public var memberIds: Set<String>

    public init(localChannelId: String, canonicalChannelId: String, serverId: String, memberIds: Set<String>) {
        self.localChannelId = localChannelId
        self.canonicalChannelId = canonicalChannelId
        self.serverId = serverId
        self.memberIds = memberIds
    }
}

/// A joint thread stored on the host, read through one server's local thread channel.
public struct JointThreadProjection: Equatable, Sendable {
    public var localParentChannelId: String
    public var canonicalParentChannelId: String
    public var canonicalParentMessageId: String
    public var canonicalThreadChannelId: String
    public var localThreadChannelId: String
    public var localServerId: String
    public var memberIds: Set<String>

    public init(
        localParentChannelId: String,
        canonicalParentChannelId: String,
        canonicalParentMessageId: String,
        canonicalThreadChannelId: String,
        localThreadChannelId: String,
        localServerId: String,
        memberIds: Set<String>
    ) {
        self.localParentChannelId = localParentChannelId
        self.canonicalParentChannelId = canonicalParentChannelId
        self.canonicalParentMessageId = canonicalParentMessageId
        self.canonicalThreadChannelId = canonicalThreadChannelId
        self.localThreadChannelId = localThreadChannelId
        self.localServerId = localServerId
        self.memberIds = memberIds
    }
}

public struct MessageContextCatalog: Equatable, Sendable {
    public var messages: [ContextMessage]
    public var jointProjections: [JointChannelProjection]
    public var jointThreads: [JointThreadProjection]

    public init(
        messages: [ContextMessage] = [],
        jointProjections: [JointChannelProjection] = [],
        jointThreads: [JointThreadProjection] = []
    ) {
        self.messages = messages
        self.jointProjections = jointProjections
        self.jointThreads = jointThreads
    }
}

public enum MessageContext {
    public static func reply(
        messageId: String,
        channelId: String?,
        catalog: MessageContextCatalog,
        callerId: String? = nil,
        serverId: String? = nil
    ) -> HTTPReply {
        switch resolve(messageId: messageId, channelId: channelId, catalog: catalog, callerId: callerId, serverId: serverId) {
        case .found(let target): return found(target.message, thread: target.thread)
        case .refused(let refusal): return error(refusal.status, refusal.message)
        }
    }

    /// Pure target selection shared by permission admission and the renderer.
    struct Target {
        let message: ContextMessage
        let sourceChannelId: String
        let thread: JointThreadProjection?
    }
    struct Refusal {
        let status: Int
        let message: String
    }

    enum Resolution {
        case found(Target)
        case refused(Refusal)
    }

    static func resolve(messageId: String, channelId: String?, catalog: MessageContextCatalog,
                        callerId: String?, serverId: String?) -> Resolution {
        if !ServerScope.isUUID(messageId) && !isShortId(messageId) {
            return .refused(.init(status: 400, message: "Invalid message id"))
        }
        if let channelId, !ServerScope.isUUID(channelId) {
            return .refused(.init(status: 400, message: "Invalid channel id"))
        }
        if let channelId,
           let serverId,
           let joint = catalog.jointProjections.first(where: {
               same($0.localChannelId, channelId) && same($0.serverId, serverId)
           }) {
            guard let callerId, joint.memberIds.contains(where: { same($0, callerId) }) else {
                return .refused(.init(status: 404, message: "Message not found"))
            }
            if var target = find(messageId: messageId, channelId: joint.canonicalChannelId, catalog: catalog) {
                let source = target.channelId
                target.channelId = joint.localChannelId
                return .found(Target(message: target, sourceChannelId: source, thread: nil))
            }
            let threadHits = catalog.jointThreads.compactMap { projection -> (ContextMessage, JointThreadProjection)? in
                guard same(projection.localParentChannelId, joint.localChannelId),
                      same(projection.localServerId, serverId),
                      catalog.messages.contains(where: {
                          same($0.id, projection.canonicalParentMessageId) && same($0.channelId, joint.canonicalChannelId)
                      }),
                      let message = find(messageId: messageId, channelId: projection.canonicalThreadChannelId, catalog: catalog)
                else { return nil }
                return (message, projection)
            }
            guard threadHits.count == 1 else {
                return .refused(.init(status: 404, message: "Message not found"))
            }
            var reply = threadHits[0].0
            let projection = threadHits[0].1
            let source = reply.channelId
            reply.channelId = projection.localThreadChannelId
            return .found(Target(message: reply, sourceChannelId: source, thread: projection))
        }
        if let channelId,
           let serverId,
           let projection = catalog.jointThreads.first(where: {
               same($0.localThreadChannelId, channelId) && same($0.localServerId, serverId)
           }) {
            guard let callerId, projection.memberIds.contains(where: { same($0, callerId) }) else {
                return .refused(.init(status: 404, message: "Message not found"))
            }
            guard var target = find(messageId: messageId, channelId: projection.canonicalThreadChannelId, catalog: catalog) else {
                return .refused(.init(status: 404, message: "Message not found"))
            }
            let source = target.channelId
            target.channelId = projection.localThreadChannelId
            return .found(Target(message: target, sourceChannelId: source, thread: projection))
        }
        guard let target = find(messageId: messageId, channelId: channelId, catalog: catalog) else {
            return .refused(.init(status: 404, message: "Message not found"))
        }
        return .found(Target(message: target, sourceChannelId: target.channelId, thread: nil))
    }

    public static func isShortId(_ value: String) -> Bool {
        value.wholeMatch(of: /^[0-9a-fA-F]{8}$/) != nil
    }

    private static func find(
        messageId: String,
        channelId: String?,
        catalog: MessageContextCatalog
    ) -> ContextMessage? {
        if ServerScope.isUUID(messageId) {
            return catalog.messages.first { message in
                same(message.id, messageId)
                    && (channelId == nil || same(message.channelId, channelId!))
            }
        }
        guard let channelId else { return nil }
        let prefix = messageId.lowercased()
        let matches = catalog.messages.filter { message in
            same(message.channelId, channelId) && message.id.lowercased().hasPrefix(prefix)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func same(_ stored: String, _ given: String) -> Bool {
        stored.caseInsensitiveCompare(given) == .orderedSame
    }

    private static func found(_ target: ContextMessage, thread: JointThreadProjection? = nil) -> HTTPReply {
        let message = "{\"id\":\(jsonString(target.id)),\"channelId\":\(jsonString(target.channelId)),\"content\":\(jsonString(target.content)),\"seq\":\(target.seq)}"
        var body = "{\"channelId\":\(jsonString(target.channelId)),\"targetMessageId\":\(jsonString(target.id)),\"hasOlder\":false,\"hasNewer\":false,\"messages\":[\(message)]"
        if let thread {
            body += ",\"canonicalTarget\":{\"kind\":\"thread\",\"channelId\":\(jsonString(thread.localParentChannelId)),\"messageId\":\(jsonString(target.id)),\"threadParentMessageId\":\(jsonString(thread.canonicalParentMessageId)),\"threadChannelId\":\(jsonString(thread.localThreadChannelId))}"
        }
        body += ",\"threadSummariesByParentMessageId\":{},\"historyLimited\":false,\"channelArchived\":false}"
        return HTTPReply(
            status: 200,
            headers: [
                "X-Robots-Tag": AppFallback.robotsTag,
                "Content-Type": AppFallback.jsonContentType,
                "Content-Length": String(Data(body.utf8).count),
            ],
            body: body
        )
    }

    private static func error(_ status: Int, _ message: String) -> HTTPReply {
        let body = "{\"error\":\(jsonString(message))}"
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

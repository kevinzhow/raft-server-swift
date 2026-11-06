import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The served-inbox boundary: the channel message page and its sync cursor,
/// mention deliveries, the Done inbox page and the stored-message seams the
/// projections read.
///
/// The state transitions stay on `EmailLoginDirectory` with unchanged
/// signatures, so every existing caller and test compiles untouched. This type
/// is the `Service` boundary the routes call.
public struct InboxAndWakeService: Sendable {
    public let directory: EmailLoginDirectory

    public init(directory: EmailLoginDirectory) {
        self.directory = directory
    }

    /// `GET /api/messages/sync`.
    public func syncChannelMessages(
        channelId: String?,
        sinceSeq: String?,
        authorization: String?,
        serverId: String?,
        limit: String? = nil
    ) -> HTTPReply {
        directory.syncChannelMessages(
            channelId: channelId,
            sinceSeq: sinceSeq,
            authorization: authorization,
            serverId: serverId,
            limit: limit
        )
    }

    /// `GET /api/messages/channel/:channelId`.
    public func listChannelMessages(
        channelId: String,
        authorization: String?,
        serverId: String?,
        limit: String? = nil,
        before: String? = nil,
        after: String? = nil
    ) -> HTTPReply {
        directory.listChannelMessages(
            channelId: channelId,
            authorization: authorization,
            serverId: serverId,
            limit: limit,
            before: before,
            after: after
        )
    }

    /// `GET /api/messages/:messageId/mention-deliveries`.
    public func mentionDeliveries(
        messageId: String,
        authorization: String?,
        serverId: String?
    ) -> HTTPReply {
        directory.mentionDeliveries(
            messageId: messageId,
            authorization: authorization,
            serverId: serverId
        )
    }

    /// `GET /api/channels/inbox`.
    public func doneInbox(authorization: String?, serverId: String?, query: String? = nil) -> HTTPReply {
        directory.doneInbox(authorization: authorization, serverId: serverId, query: query)
    }

    /// Stores a human message row without an HTTP round trip.
    public func insertHumanMessage(
        id: String,
        channelId: String,
        senderId: String,
        content: String,
        messageType: String = "chat",
        senderType: String = "user",
        actionKind: String? = nil
    ) {
        directory.insertHumanMessage(
            id: id,
            channelId: channelId,
            senderId: senderId,
            content: content,
            messageType: messageType,
            senderType: senderType,
            actionKind: actionKind
        )
    }
}

extension EmailLoginDirectory {
    public func syncChannelMessages(channelId: String?, sinceSeq: String?, authorization: String?, serverId: String?, limit rawLimit: String? = nil) -> HTTPReply {
        if let channelId, !ServerScope.isUUID(channelId) {
            return Self.json(400, "{\"error\":\"Invalid channel id\"}")
        }
        guard sinceSeq == nil || sinceSeq == "0" || Int(sinceSeq ?? "") != nil else {
            return Self.json(400, "{\"error\":\"Invalid sync cursor\"}")
        }
        let userId: String
        switch authorize(authorization) {
        case .rejected(let reply):
            return reply
        case .user(let id):
            userId = id
        }
        guard isEmailVerified(userId: userId) else {
            return Self.json(403, "{\"error\":\"Email verification required\"}")
        }
        let pageLimit = Self.messagePageLimit(rawLimit)
        let commentsVisible = attachmentCommentsEnabled(serverId: serverId ?? "", userId: userId)
        if channelId == nil {
            let cursor = Int(sinceSeq ?? "") ?? 0
            let isGuest = serverId.flatMap { oauth.memberRole(serverId: $0, userId: userId) } == "guest"
            var guestJoined: Set<String> = []
            if isGuest {
                lock.lock()
                let candidateIds = Array(postableChannels.keys)
                lock.unlock()
                guestJoined = Set(candidateIds.filter { oauth.channelHumanIds(channelId: $0).contains(userId) })
            }
            lock.lock()
            var visibleChannels: [String] = []
            for (id, channel) in postableChannels {
                guard channel.serverId == serverId, channel.deletedAt == nil, !channel.archived else { continue }
                if isGuest && !guestJoined.contains(id) { continue }
                if channel.kind == "channel" || channel.memberIds.contains(userId) {
                    visibleChannels.append(id)
                }
            }
            var listed: [String] = []
            for id in visibleChannels {
                let rows = humanMessageRows.filter { $0.channelId == id }
                for message in rows where message.seq > cursor {
                    var row = "{\"id\":\(jsonString(message.id)),\"channelId\":\(jsonString(id)),\"seq\":\(message.seq),\"content\":\(jsonString(message.content)),\"attachments\":[\(messageAttachmentsJSONLocked(message.attachmentIds, commentsVisible: commentsVisible))]"
                    if let commentRef = commentRefJSONLocked(messageId: message.id), commentsVisible {
                        row += ",\"commentRef\":\(commentRef)"
                    }
                    listed.append(row + "}")
                }
            }
            lock.unlock()
            let page = listed.suffix(pageLimit)
            return Self.json(200, "[\(page.joined(separator: ","))]")
        }
        guard let channelId else {
            return Self.json(400, "{\"error\":\"Invalid channel id\"}")
        }
        lock.lock()
        if let serverId, channelProbeAccessLocked(channelId: channelId, serverId: serverId, userId: userId) == .residue {
            lock.unlock()
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        let visible: Bool = {
            guard let channel = postableChannels[channelId], channel.serverId == serverId else { return false }
            if channel.kind == "channel" { return true }
            let guest = serverId.flatMap { oauth.memberRole(serverId: $0, userId: userId) } == "guest"
            if channel.kind == "thread" {
                if guest { return false }
                if let parentId = channel.parentChannelId,
                   let parent = postableChannels[parentId], parent.kind == "channel" {
                    return true
                }
            }
            return channel.memberIds.contains(userId)
        }()
        let storageChannelId = jointProjections.first { $0.localChannelId == channelId }?.canonicalChannelId ?? channelId
        let allRows = humanMessageRows.filter { $0.channelId == storageChannelId || $0.channelId == channelId }
        let cursor = Int(sinceSeq ?? "") ?? 0
        let indexed = allRows.filter { $0.seq > cursor }
        let limitedIndexed = Array(indexed.suffix(pageLimit))
        let listed = limitedIndexed.map { message -> String in
            var row = "{\"id\":\(jsonString(message.id)),\"channelId\":\(jsonString(channelId)),\"seq\":\(message.seq),\"content\":\(jsonString(message.content)),\"attachments\":[\(messageAttachmentsJSONLocked(message.attachmentIds, commentsVisible: commentsVisible))]"
            if let commentRef = commentRefJSONLocked(messageId: message.id), commentsVisible {
                row += ",\"commentRef\":\(commentRef)"
            }
            if let metadata = forwardMetadataJSONLocked(messageId: message.id, userId: userId, serverId: serverId)
                ?? actionCardMetadataLocked(messageId: message.id) {
                row += ",\"actionMetadata\":\(metadata)"
            }
            row += "}"
            return row
        }.joined(separator: ",")
        lock.unlock()
        guard visible else {
            return Self.json(404, "{\"error\":\"Channel not found or not visible\"}")
        }
        let body = "[\(listed)]"
        return Self.json(200, body)
    }

    /// `GET /api/messages/:messageId/mention-deliveries`. Only the author who can still read the channel sees coarse outcomes.
    public func mentionDeliveries(messageId: String, authorization: String?, serverId: String?) -> HTTPReply {
        let userId: String
        switch authorize(authorization) {
        case .rejected(let reply):
            return reply
        case .user(let id):
            userId = id
        }
        guard isEmailVerified(userId: userId) else {
            return Self.json(403, "{\"error\":\"Email verification required\"}")
        }
        guard ServerScope.isUUID(messageId) else {
            return Self.json(404, "{\"status\":\"NOT_JOINABLE\"}")
        }
        lock.lock()
        defer { lock.unlock() }
        guard let message = humanMessageRows.first(where: { $0.id.caseInsensitiveCompare(messageId) == .orderedSame }),
              message.senderType == "user",
              message.senderId == userId,
              messageSearchVisibleLocked(messageChannelId: message.channelId, serverId: serverId, viewer: .user(userId)),
              postableChannels[message.channelId]?.serverId == serverId
        else {
            return Self.json(404, "{\"status\":\"NOT_JOINABLE\"}")
        }
        let deliveries = storedMentions.filter {
            $0.messageId == message.id && $0.targetType == "agent" && $0.notifiableAtSend
        }.map { mention in
            "{\"targetId\":\(jsonString(mention.targetId)),\(Self.mentionDeliveryFields(handle: mention.handle, terminalCode: mention.terminalCode))}"
        }.joined(separator: ",")
        return Self.json(200, "{\"messageId\":\(jsonString(message.id)),\"deliveries\":[\(deliveries)]}")
    }


    /// `GET /api/messages/channel/:channelId`. A non-UUID is `Channel not found`. A UUID the caller cannot see uses the neutral body.
    public func listChannelMessages(channelId: String, authorization: String?, serverId: String?, limit rawLimit: String? = nil, before rawBefore: String? = nil, after rawAfter: String? = nil) -> HTTPReply {
        if let serverId, let userId = sessionUserId(authorization: authorization) {
            lock.lock()
            let threadScope = postableChannels[channelId]?.kind == "thread"
            let guestVisible = guestCanSeeScopeLocked(channelId)
            lock.unlock()
            if oauth.memberRole(serverId: serverId, userId: userId) == "guest",
               !oauth.channelHumanIds(channelId: channelId).contains(userId) {
                return Self.json(403, "{\"error\":\"Forbidden\"}")
            }
            if threadScope, oauth.memberRole(serverId: serverId, userId: userId) == "guest", !guestVisible {
                return Self.json(403, "{\"error\":\"Forbidden\"}")
            }
        }
        let before = Self.parsePageCursor(rawBefore)
        let after = Self.parsePageCursor(rawAfter)
        if before == .invalid || after == .invalid || (before.value != nil && after.value != nil && rawBefore != nil && rawAfter != nil) {
            return Self.json(400, "{\"error\":\"Invalid message page cursor\",\"code\":\"invalid_message_page_cursor\"}")
        }
        if !ServerScope.isUUID(channelId) {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        let userId: String?
        if case .user(let id) = authorize(authorization) {
            userId = id
        } else {
            userId = nil
        }
        lock.lock()
        if let userId, let serverId,
           channelProbeAccessLocked(channelId: channelId, serverId: serverId, userId: userId) == .residue {
            lock.unlock()
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        let visible: Bool = {
            guard let channel = postableChannels[channelId], channel.serverId == serverId,
                  channel.deletedAt == nil, let userId
            else { return false }
            if channel.kind == "channel" { return true }
            let guest = serverId.flatMap { oauth.memberRole(serverId: $0, userId: userId) } == "guest"
            if channel.kind == "thread" {
                if guest { return false }
                if let parentId = channel.parentChannelId, let parent = postableChannels[parentId] {
                    if parent.kind == "channel" { return parent.deletedAt == nil }
                    return channel.memberIds.contains(userId)
                }
                return channel.memberIds.contains(userId)
            }
            return channel.memberIds.contains(userId)
        }()
        let storageChannelId = jointProjections.first { $0.localChannelId == channelId }?.canonicalChannelId ?? channelId
        let rows = humanMessageRows.filter { $0.channelId == storageChannelId || $0.channelId == channelId }
        let cursorRows = rows.filter { row in
            if let before = before.value, row.seq >= before { return false }
            if let after = after.value, row.seq <= after { return false }
            return true
        }
        let pageRows = Array(cursorRows.suffix(Self.messagePageLimit(rawLimit)))
        let statusRequests = pageRows.map { (id: $0.id, senderId: $0.senderId, senderType: $0.senderType) }
        let memberStatusSnapshot = serverMemberStatuses
        lock.unlock()
        var senderStatuses: [String: String] = [:]
        for request in statusRequests {
            if request.senderType == "agent" {
                senderStatuses[request.id] = oauth.agentRuntimeInfo(id: request.senderId)?.deleted == true ? "removed" : "active"
            } else if let serverId, oauth.memberRole(serverId: serverId, userId: request.senderId) != nil {
                senderStatuses[request.id] = "active"
            } else {
                senderStatuses[request.id] = memberStatusSnapshot["\(serverId ?? "")\n\(request.senderId)"] ?? "removed"
            }
        }
        lock.lock()
        let highWater = rows.map(\.seq).max() ?? 0
        let pageSeqs = pageRows.map(\.seq)
        let isTail = rawBefore == nil && rawAfter == nil
        let coveredFrom = pageSeqs.first ?? (isTail ? 1 : 0)
        let coveredThrough = pageSeqs.last ?? 0
        let coveredAfter = max(0, coveredFrom - 1)
        let pageHasGap = !isTail
        let pageHasNewer = rawBefore != nil
        let completeThroughLatest = isTail
        let windowJSON = "{\"schemaVersion\":1,\"domain\":\"receiver_visible_messages_v1\",\"serverId\":\(jsonString(serverId ?? "")),\"receiverKind\":\"user\",\"receiverId\":\(jsonString(userId ?? "")),\"scopeId\":\(jsonString(channelId)),\"coveredFromSeq\":\(coveredFrom),\"coveredAfterSeq\":\(coveredAfter),\"coveredThroughSeq\":\(coveredThrough),\"remoteHighWaterSeq\":\(highWater),\"hasGap\":\(pageHasGap),\"hasNewer\":\(pageHasNewer),\"completeThroughLatest\":\(completeThroughLatest)}"
        let commentsVisible = attachmentCommentsEnabled(serverId: serverId ?? "", userId: userId)
        let listed = pageRows.map { message in
            let membershipStatus = senderStatuses[message.id] ?? "removed"
            var row = "{\"id\":\(jsonString(message.id)),\"senderId\":\(jsonString(message.senderId)),\"senderType\":\(jsonString(message.senderType)),\"senderMembershipStatus\":\(jsonString(membershipStatus)),\"content\":\(jsonString(message.content)),\"attachments\":[\(messageAttachmentsJSONLocked(message.attachmentIds, commentsVisible: commentsVisible))],\"reactions\":[\(reactionJSONLocked(messageId: message.id))],\"mentions\":[\(visibleMentionJSONLocked(messageId: message.id))]"
            if let commentRef = commentRefJSONLocked(messageId: message.id), commentsVisible {
                row += ",\"commentRef\":\(commentRef)"
            }
            var metadata = actionCardMetadataLocked(messageId: message.id)
            if let userId {
                metadata = forwardMetadataJSONLocked(messageId: message.id, userId: userId, serverId: serverId) ?? metadata
            }
            if let metadata {
                row += ",\"actionMetadata\":\(metadata)"
            }
            row += "}"
            return row
        }.joined(separator: ",")
        let summaries = threadSummariesJSONLocked(parentChannelId: channelId, parentIds: pageRows.map(\.id))
        lock.unlock()
        guard visible else {
            return Self.json(404, "{\"error\":\"Channel not found or not visible\"}")
        }
        return Self.json(200, "{\"messages\":[\(listed)],\"historyLimited\":false,\"messageWindow\":\(windowJSON),\"threadSummariesByParentMessageId\":{\(summaries)}}")
    }

    /// Missing, zero, or non-numeric limits are 50. A positive limit is capped at 200. The page is the newest rows.



    /// Summaries for threads whose parent message is on this page. Newest three non-system replies, oldest of those first.
    func threadSummariesJSONLocked(parentChannelId: String, parentIds: [String]) -> String {
        let parents = Set(parentIds)
        var parts: [String] = []
        for (threadId, thread) in postableChannels {
            guard thread.kind == "thread",
                  thread.deletedAt == nil,
                  thread.parentChannelId == parentChannelId,
                  let parentId = thread.parentMessageId,
                  parents.contains(parentId)
            else { continue }
            let replies = humanMessageRows.filter { $0.channelId == threadId }
            let previews = replies.filter { $0.messageType != "system" }.suffix(3)
            let latest = previews.map { "{\"preview\":\(jsonString($0.content))}" }.joined(separator: ",")
            parts.append("\(jsonString(parentId)):{\"replyCount\":\(replies.count),\"latestReplies\":[\(latest)]}")
        }
        return parts.joined(separator: ",")
    }

    /// Mentions a reader can see: notifiable at send, or later notified.
    func visibleMentionJSONLocked(messageId: String) -> String {
        storedMentions.filter { row in
            row.messageId == messageId && (row.notifiableAtSend || row.notifiedAt != nil)
        }.map { row in
            "{\"type\":\(jsonString(row.targetType)),\"id\":\(jsonString(row.targetId)),\"name\":\(jsonString(row.handle))}"
        }.joined(separator: ",")
    }

    /// Stores a message row with a fixed id. Reaction short-id tests need a known prefix.
    public func insertHumanMessage(id: String, channelId: String, senderId: String, content: String, messageType: String = "chat", senderType: String = "user", actionKind: String? = nil) {
        lock.lock()
        appendHumanMessageLocked(StoredHumanMessage(
            id: id,
            channelId: channelId,
            senderId: senderId,
            content: content,
            messageType: messageType,
            senderType: senderType,
            actionKind: actionKind
        ))
        lock.unlock()
    }

    /// Task columns on a source message. A forward must not copy them onto the destination.
    public func setHumanMessageTask(messageId: String, status: String, number: Int, assigneeType: String, assigneeId: String, claimedAt: String, completedAt: String) {
        lock.lock()
        if let index = humanMessageRows.firstIndex(where: { $0.id == messageId }) {
            humanMessageRows[index].taskStatus = status
            humanMessageRows[index].taskNumber = number
            humanMessageRows[index].taskAssigneeType = assigneeType
            humanMessageRows[index].taskAssigneeId = assigneeId
            humanMessageRows[index].taskClaimedAt = claimedAt
            humanMessageRows[index].taskCompletedAt = completedAt
        }
        lock.unlock()
    }

    public func addBackfilledTaskForTesting(channelId: String, title: String, taskNumber: Int, messageId: String) -> String {
        lock.lock()
        let id = UUID().uuidString.lowercased()
        taskRecords.append(TaskRecord(
            id: id,
            channelId: channelId,
            title: title,
            description: nil,
            status: "todo",
            taskNumber: taskNumber,
            messageId: messageId,
            createdAt: Date()
        ))
        if let index = humanMessageRows.firstIndex(where: { $0.id == messageId }) {
            humanMessageRows[index].taskStatus = "todo"
            humanMessageRows[index].taskNumber = taskNumber
        }
        lock.unlock()
        return id
    }

    public func mentionNotifiedActionForTesting(id: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storedMentions.first { $0.id == id }?.notifiedAction
    }

    public func messageAttachmentIdsForTesting(messageId: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return humanMessageRows.first { $0.id == messageId }?.attachmentIds ?? []
    }

    public func setMessageAttachmentIdsForTesting(messageId: String, attachmentIds: [String]) {
        lock.lock()
        if let index = humanMessageRows.firstIndex(where: { $0.id == messageId }) {
            humanMessageRows[index].attachmentIds = attachmentIds
        }
        lock.unlock()
    }

    public func amendTaskForTesting(taskId: String, title: String, description: String?, amendedByName: String = "user") {
        lock.lock()
        if let index = taskRecords.firstIndex(where: { $0.id == taskId }) {
            taskRecords[index].title = title
            if let description { taskRecords[index].description = description }
            taskRecords[index].revision += 1
            taskRecords[index].amendedAt = Date()
            taskRecords[index].amendedByType = "user"
            taskRecords[index].amendedByName = amendedByName
            taskRecords[index].superseded = true
        }
        lock.unlock()
    }

    public func taskNumberForTaskIdForTesting(taskId: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return taskRecords.first { $0.id == taskId }?.taskNumber
    }

    public func messageChannelIdForTesting(messageId: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return humanMessageRows.first { $0.id == messageId }?.channelId
    }

    public func messageSeqForTesting(messageId: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return humanMessageRows.first { $0.id == messageId }?.seq
    }

    public func messageCreatedAtForTesting(messageId: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return humanMessageRows.first { $0.id == messageId }?.createdAt
    }

    public func setMessageCreatedAtForTesting(messageId: String, at date: Date) {
        lock.lock()
        if let index = humanMessageRows.firstIndex(where: { $0.id == messageId }) {
            humanMessageRows[index].createdAt = date
        }
        lock.unlock()
    }

    public func messageCountForTesting(channelId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return humanMessageRows.filter { $0.channelId == channelId }.count
    }

    public func removeMessageForTesting(messageId: String) {
        lock.lock()
        humanMessageRows.removeAll { $0.id == messageId }
        for key in attachmentCommentRecords.keys {
            attachmentCommentRecords[key]?.removeAll { $0.id == messageId }
        }
        lock.unlock()
    }

    public func addOrphanTaskForTesting(channelId: String, title: String, taskNumber: Int) -> String {
        lock.lock()
        let id = UUID().uuidString.lowercased()
        var record = TaskRecord(
            id: id,
            channelId: channelId,
            title: title,
            description: nil,
            status: "todo",
            taskNumber: taskNumber,
            messageId: UUID().uuidString.lowercased(),
            createdAt: Date()
        )
        record.hasHostMessage = false
        taskRecords.append(record)
        lock.unlock()
        return id
    }

    public func assignTaskForTesting(taskId: String, assigneeId: String?) {
        lock.lock()
        if let index = taskRecords.firstIndex(where: { $0.id == taskId }) {
            taskRecords[index].assigneeId = assigneeId
            taskRecords[index].assigneeType = assigneeId == nil ? nil : "agent"
            taskRecords[index].claimedAt = nil
        }
        lock.unlock()
    }

    public func taskAssigneeForTesting(taskId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return taskRecords.first { $0.id == taskId }?.assigneeId
    }

    public func messageTaskShadowForTesting(messageId: String) -> (status: String, number: Int)? {
        lock.lock()
        defer { lock.unlock() }
        guard let row = humanMessageRows.first(where: { $0.id == messageId }),
              let status = row.taskStatus, let number = row.taskNumber
        else { return nil }
        return (status, number)
    }

    /// A mention row search can filter with `mentionTarget=self`. Send only stores mentions of people who are not yet members.
    /// A notifiable agent mention whose delivery ended in a terminal code. The author route projects that code.
    public func recordAgentMentionDelivery(messageId: String, agentId: String, handle: String, terminalCode: String) {
        lock.lock()
        let message = humanMessageRows.first { $0.id == messageId }
        storedMentions.append(StoredMention(
            id: UUID().uuidString.lowercased(),
            messageId: messageId,
            channelId: message?.channelId ?? "",
            senderId: message?.senderId ?? "",
            targetType: "agent",
            targetId: agentId,
            handle: handle,
            notifiableAtSend: true,
            notifiedAt: nil,
            notifiedByType: nil,
            notifiedById: nil,
            notifiedAction: nil,
            terminalCode: terminalCode
        ))
        lock.unlock()
    }

    public func addMessageMention(
        messageId: String,
        targetType: String,
        targetId: String,
        notifiableAtSend: Bool = true,
        notifiedAt: Date? = nil,
        notifiedByType: String? = nil,
        notifiedById: String? = nil,
        notifiedAction: String? = nil
    ) {
        lock.lock()
        let message = humanMessageRows.first { $0.id == messageId }
        storedMentions.append(StoredMention(
            id: UUID().uuidString.lowercased(),
            messageId: messageId,
            channelId: message?.channelId ?? "",
            senderId: message?.senderId ?? "",
            targetType: targetType,
            targetId: targetId,
            handle: "",
            notifiableAtSend: notifiableAtSend,
            notifiedAt: notifiedAt,
            notifiedByType: notifiedByType,
            notifiedById: notifiedById,
            notifiedAction: notifiedAction
        ))
        lock.unlock()
    }

    /// Pins the timestamp used by `sort=recent` message search.
    public func setHumanMessageCreatedAt(messageId: String, createdAt: Date) {
        lock.lock()
        if let index = humanMessageRows.firstIndex(where: { $0.id == messageId }) {
            humanMessageRows[index].createdAt = createdAt
        }
        lock.unlock()
    }

    public func markMessageSystem(messageId: String) {
        lock.lock()
        if let index = humanMessageRows.firstIndex(where: { $0.id == messageId }) {
            humanMessageRows[index].messageType = "system"
        }
        lock.unlock()
    }

    public func archiveChannel(channelId: String) {
        lock.lock()
        postableChannels[channelId]?.archived = true
        lock.unlock()
    }

    public func markChannelDeleted(channelId: String) {
        lock.lock()
        postableChannels[channelId]?.deletedAt = Date()
        lock.unlock()
    }

    /// Drops a channel membership. A later send on another channel must not replay this channel's randomId.
    public func removeChannelMember(channelId: String, memberId: String) {
        lock.lock()
        postableChannels[channelId]?.memberIds.remove(memberId)
        lock.unlock()
    }

    public func setChannelMessageCreatedAtForTesting(id: String, createdAt: Date) {
        lock.lock()
        if let index = humanMessageRows.firstIndex(where: { $0.id == id }) {
            humanMessageRows[index].createdAt = createdAt
        }
        lock.unlock()
    }

    public func humanMessageRandomIds(channelId: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return humanMessageRows.filter { $0.channelId == channelId }.compactMap(\.randomId)
    }

    public func humanMessageIds(channelId: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return humanMessageRows.filter { $0.channelId == channelId }.map(\.id)
    }

    /// The IANA zone stored for a human send. Human HTTP never returns this column.
    public func storedSenderTimezone(messageId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return humanMessageRows.first { $0.id == messageId }?.senderTimezone
    }

    /// The stored notify/add row for one resolution id.
    public func mentionActionRecord(id: String) -> MentionActionRecord? {
        lock.lock()
        defer { lock.unlock() }
        guard let row = storedMentions.first(where: { $0.id == id }) else { return nil }
        return MentionActionRecord(
            notified: row.notifiedAt != nil,
            notifiedByType: row.notifiedByType,
            notifiedById: row.notifiedById,
            notifiedAction: row.notifiedAction
        )
    }

    public func channelAgentIds(channelId: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(channelAgentMembers[channelId] ?? []).sorted()
    }

    public func channelMemberIds(channelId: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(postableChannels[channelId]?.memberIds ?? []).sorted()
    }

    /// Mention rows written for this message. Public-channel outsiders stay `notifiableAtSend: false` and unnotified.
    public func messageMentionRows(messageId: String) -> [MentionFact] {
        lock.lock()
        defer { lock.unlock() }
        return storedMentions.filter { $0.messageId == messageId }.map {
            MentionFact(targetType: $0.targetType, targetId: $0.targetId, notifiableAtSend: $0.notifiableAtSend, notified: $0.notifiedAt != nil)
        }
    }

    public func inboxFacts(messageId: String, receiverIds: [String]) -> [InboxFact] {
        lock.lock()
        defer { lock.unlock() }
        let wanted = Set(receiverIds)
        return inboxFactStore.all().filter { $0.messageId == messageId && wanted.contains($0.receiverId) }.map {
            InboxFact(
                receiverType: $0.receiverType,
                receiverId: $0.receiverId,
                personalMention: $0.personalMention,
                unreadEligible: $0.unreadEligible
            )
        }
    }

    public func agentDeliveries(agentId: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedAgentDeliveries.filter { $0.agentId == agentId }.map(\.messageId)
    }

    public func agentDeliveryChannelTypes(agentId: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedAgentDeliveries.filter { $0.agentId == agentId }.map(\.channelType)
    }

    /// `GET /api/channels/inbox`. A DM outsider mention is not an inbox item.
    public func doneInbox(authorization: String?, serverId: String?, query: String? = nil) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        let params = Self.inboxQueryParameters(query)
        let limit = min(max(Int(params["limit"] ?? "") ?? 30, 1), 100)
        let q = (params["q"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let channelFilter = params["channelId"]
        let ascending = params["sort"] == "asc"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        lock.lock()
        let guest = serverId.flatMap { oauth.memberRole(serverId: $0, userId: userId) } == "guest"
        var rows: [(id: String, kind: String, channelId: String?, threadChannelId: String?, parentChannelId: String?, doneAt: Date)] = []
        for key in inboxDoneScopes where key.hasPrefix("\(userId)\n") {
            let scopeId = String(key.dropFirst("\(userId)\n".count))
            if guest, !guestCanSeeScopeLocked(scopeId) { continue }
            let type = postableChannels[scopeId]?.kind ?? oauth.channelType(id: scopeId) ?? "channel"
            let isThread = type == "thread"
            let parentId = postableChannels[scopeId]?.parentChannelId
            if let channelFilter, !(isThread ? parentId == channelFilter : scopeId == channelFilter) { continue }
            if !q.isEmpty {
                let matches = humanMessageRows.contains { row in
                    row.channelId == scopeId && row.content.localizedCaseInsensitiveContains(q)
                }
                if !matches { continue }
            }
            rows.append((
                id: scopeId,
                kind: isThread ? "thread" : "channel",
                channelId: isThread ? nil : scopeId,
                threadChannelId: isThread ? scopeId : nil,
                parentChannelId: parentId,
                doneAt: inboxDoneAt[key] ?? Date.distantPast
            ))
        }
        rows.sort { lhs, rhs in
            if lhs.doneAt != rhs.doneAt { return ascending ? lhs.doneAt < rhs.doneAt : lhs.doneAt > rhs.doneAt }
            return ascending ? lhs.id < rhs.id : lhs.id > rhs.id
        }
        let page = Array(rows.prefix(limit))
        let items = page.map { row -> String in
            let done = jsonString(formatter.string(from: row.doneAt))
            if row.kind == "thread" {
                let following = threadFollows["\(serverId ?? "")\n\(userId)\n\(row.id)"] != nil
                let unread = oauth.channelUnreadInfo(channelId: row.id, userId: userId).unreadCount
                let parentJSON = row.parentChannelId.map(jsonString) ?? "null"
                return "{\"kind\":\"thread\",\"threadChannelId\":\(jsonString(row.id)),\"parentChannelId\":\(parentJSON),\"isFollowing\":\(following),\"unreadCount\":\(unread),\"doneAt\":\(done)}"
            }
            let unread = oauth.channelUnreadInfo(channelId: row.id, userId: userId).unreadCount
            return "{\"kind\":\"channel\",\"channelId\":\(jsonString(row.id)),\"unreadCount\":\(unread),\"doneAt\":\(done)}"
        }.joined(separator: ",")
        lock.unlock()
        return Self.json(200, "{\"items\":[\(items)],\"hasMore\":\(rows.count > page.count),\"totalCount\":null}")
    }

}

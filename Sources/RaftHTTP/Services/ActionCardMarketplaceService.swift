import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Agent task delete/convert/create plus the inbox conversation surface.
/// Migrated verbatim from the first half of `EmailLogin+ActionCards2.swift`.
///
/// The handlers stay on `EmailLoginDirectory`, which owns the lock and the
/// domain ledgers. This type is the named, `Sendable` handle a route can hold
/// instead of reaching for the composition root; it carries no state of its own.
public struct ActionCardMarketplaceService: Sendable {
    public let directory: EmailLoginDirectory

    public init(directory: EmailLoginDirectory) {
        self.directory = directory
    }
}

extension EmailLoginDirectory {
    public func agentTaskDelete(authorization: String?, body: String, legacyAgentId: String? = nil) -> HTTPReply {
        if let denial = agentCapabilityDenial(authorization, required: "tasks") { return denial }
        guard let writer = agentTaskWriter(authorization, legacyAgentId: legacyAgentId)
        else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        if let reply = agentGrantDenial(agentId: writer.agentId, scope: "task:write") { return reply }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let channelRef = object["channel"] as? String,
              let channelId = agentTaskChannel(serverId: writer.serverId, agentId: writer.agentId, reference: channelRef),
              let taskNumber = object["task_number"] as? Int
        else {
            return Self.json(400, "{\"error\":\"Invalid task delete request\"}")
        }
        lock.lock()
        guard let index = taskRecords.firstIndex(where: { $0.channelId == channelId && $0.taskNumber == taskNumber }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Task not found\"}")
        }
        let task = taskRecords[index]
        let isAdmin = oauth.agentRole(serverId: writer.serverId, agentId: writer.agentId) == "admin"
        guard isAdmin || task.creatorId == writer.agentId else {
            lock.unlock()
            return Self.json(403, "{\"error\":\"Only the task creator can delete it\",\"code\":\"task_delete_forbidden\"}")
        }
        taskRecords.remove(at: index)
        lock.unlock()
        return Self.json(200, "{\"ok\":true}")
    }

    public func agentTaskConvert(authorization: String?, body: String, legacyAgentId: String? = nil) -> HTTPReply {
        if let denial = agentCapabilityDenial(authorization, required: "tasks") { return denial }
        guard let writer = agentTaskWriter(authorization, legacyAgentId: legacyAgentId)
        else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        if let reply = agentGrantDenial(agentId: writer.agentId, scope: "task:write") { return reply }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let channelRef = object["channel"] as? String,
              let channelId = agentTaskChannel(serverId: writer.serverId, agentId: writer.agentId, reference: channelRef),
              let messageRef = object["message_id"] as? String
        else {
            return Self.json(400, "{\"error\":\"Invalid task convert request\"}")
        }
        lock.lock()
        guard let message = humanMessageRows.first(where: { $0.id == messageRef || $0.id.hasPrefix(messageRef) }), message.channelId == channelId else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Message not found\"}")
        }
        if taskRecords.contains(where: { $0.messageId == message.id }) {
            lock.unlock()
            return Self.json(409, "{\"error\":\"Message is already a task\"}")
        }
        let taskNumber = taskRecords.filter { $0.channelId == channelId }.count + 1
        let id = UUID().uuidString.lowercased()
        var record = TaskRecord(
            id: id,
            channelId: channelId,
            title: "Converted message",
            description: nil,
            status: "todo",
            taskNumber: taskNumber,
            messageId: message.id,
            createdAt: Date()
        )
        record.creatorId = writer.agentId
        taskRecords.append(record)
        let json = taskJSON(record)
        lock.unlock()
        return Self.json(200, "{\"task\":\(json)}")
    }

    public func agentTasksCreate(authorization: String?, legacyAgentId: String?, body: String) -> HTTPReply {
        if let denial = agentCapabilityDenial(authorization, required: "tasks") { return denial }
        let auth: (agentId: String, serverId: String)
        switch agentTaskAuth(authorization: authorization, legacyAgentId: legacyAgentId) {
        case .refused(let reply): return reply
        case .ok(let agentId, let serverId): auth = (agentId, serverId)
        }
        if let reply = agentGrantDenial(agentId: auth.agentId, scope: "task:write") { return reply }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let channelRef = object["channel"] as? String,
              let channelId = agentTaskChannel(serverId: auth.serverId, agentId: auth.agentId, reference: channelRef),
              let rawTasks = object["tasks"] as? [[String: Any]]
        else {
            return Self.json(400, "{\"error\":\"Invalid task request\"}")
        }
        if let reply = agentApiIdempotencyReply(agentId: auth.agentId, route: "taskCreate", object: object) {
            return reply
        }
        let titles = rawTasks.compactMap { task -> String? in
            let title = (task["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? nil : title
        }
        guard !titles.isEmpty, titles.count == rawTasks.count else {
            return Self.json(400, "{\"error\":\"Invalid task request\"}")
        }
        var assignee: (id: String, type: String, name: String)?
        if let rawAssignee = object["assignee"] as? String, !rawAssignee.isEmpty {
            let handle = rawAssignee.hasPrefix("@") ? String(rawAssignee.dropFirst()) : rawAssignee
            let lowered = handle.lowercased()
            let agentMatch = oauth.channelAgentIds(channelId: channelId).compactMap { oauth.agentRuntimeInfo(id: $0) }.first {
                $0.name.lowercased() == lowered || $0.displayName.lowercased() == lowered
            }
            let humanMatch = oauth.channelHumanIds(channelId: channelId).compactMap { userId in
                accounts.values.first { $0.id == userId }
            }.first { $0.name.lowercased() == lowered }
            guard (agentMatch == nil) != (humanMatch == nil) else {
                return Self.json(404, "{\"error\":\"Assignee is not assignable\",\"code\":\"assignee_not_assignable\"}")
            }
            if let agentMatch {
                assignee = (agentMatch.id, "agent", agentMatch.name)
            } else if let humanMatch {
                assignee = (humanMatch.id, "user", humanMatch.name)
            }
        }
        let ids = addTasks(channelId: channelId, titles: titles, creatorId: auth.agentId, creatorType: "agent")
        let resourceFlags = rawTasks.map { $0["creates_resource"] as? Bool == true }
        if resourceFlags.contains(true) {
            lock.lock()
            for (offset, id) in ids.enumerated() where offset < resourceFlags.count && resourceFlags[offset] {
                if let index = taskRecords.firstIndex(where: { $0.id == id }) {
                    taskRecords[index].requiresResourceReceipt = true
                }
            }
            lock.unlock()
        }
        let idsJSON = ids.map { jsonString($0) }.joined(separator: ",")
        var receiptJSON = "null"
        lock.lock()
        if let assignee {
            for id in ids {
                guard let index = taskRecords.firstIndex(where: { $0.id == id }) else { continue }
                taskRecords[index].assigneeId = assignee.id
                taskRecords[index].assigneeType = assignee.type
                taskRecords[index].revision += 1
                inboxFactStore.append(StoredInboxFact(
                    messageId: taskRecords[index].messageId,
                    receiverType: assignee.type,
                    receiverId: assignee.id,
                    channelId: channelId,
                    serverId: auth.serverId,
                    personalMention: true,
                    unreadEligible: true
                ))
            }
            let receiptId = UUID().uuidString.lowercased()
            let receiptContent = "@\(assignee.name) assigned you: \(titles.first ?? "task")"
            appendHumanMessageLocked(StoredHumanMessage(
                id: receiptId,
                channelId: channelId,
                senderId: auth.agentId,
                content: receiptContent,
                randomId: nil,
                messageType: "task_assignment",
                senderType: "agent"
            ))
            inboxFactStore.append(StoredInboxFact(
                messageId: receiptId,
                receiverType: assignee.type,
                receiverId: assignee.id,
                channelId: channelId,
                serverId: auth.serverId,
                personalMention: true,
                unreadEligible: true
            ))
            receiptJSON = "{\"messageId\":\(jsonString(receiptId)),\"content\":\(jsonString(receiptContent)),\"assignee\":\(jsonString("@\(assignee.name)")),\"state\":\"assigned\"}"
        }
        let taskJSONs = ids.compactMap { id in taskRecords.first { $0.id == id }.map(taskJSON) }
        lock.unlock()
        let idempotentReply = Self.json(200, "{\"taskIds\":[\(idsJSON)],\"tasks\":[\(taskJSONs.joined(separator: ","))],\"assignmentReceipt\":\(receiptJSON)}")
        storeAgentApiIdempotency(agentId: auth.agentId, route: "taskCreate", object: object, reply: idempotentReply)
        return idempotentReply
    }

    public func agentTaskResourceReceipt(authorization: String?, body: String, legacyAgentId: String? = nil) -> HTTPReply {
        guard let writer = agentTaskWriter(authorization, legacyAgentId: legacyAgentId) else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        if let reply = agentGrantDenial(agentId: writer.agentId, scope: "task:write") { return reply }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let channelRef = object["channel"] as? String,
              let channelId = agentTaskChannel(serverId: writer.serverId, agentId: writer.agentId, reference: channelRef),
              let taskNumber = object["task_number"] as? Int,
              let receipt = object["receipt"] as? [String: Any],
              let objectName = (receipt["object"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !objectName.isEmpty,
              let purpose = (receipt["purpose"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !purpose.isEmpty,
              let teardownOwner = (receipt["teardown_owner"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !teardownOwner.isEmpty,
              let securityPrivacy = (receipt["security_privacy"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !securityPrivacy.isEmpty,
              let expiryRaw = receipt["expiry"] as? String,
              let runbook = (receipt["runbook"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !runbook.isEmpty,
              let tracking = (receipt["tracking"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !tracking.isEmpty
        else {
            return Self.json(400, "{\"error\":\"Invalid resource receipt\"}")
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let expiry = formatter.date(from: expiryRaw) else {
            return Self.json(400, "{\"error\":\"Invalid resource receipt\"}")
        }
        lock.lock()
        guard let index = taskRecords.firstIndex(where: { $0.channelId == channelId && $0.taskNumber == taskNumber }),
              taskRecords[index].requiresResourceReceipt
        else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Task not found\"}")
        }
        let receiptJSON = Self.serializeJSON(receipt)
        taskRecords[index].resourceReceiptJSON = receiptJSON
        taskRecords[index].revision += 1
        let task = taskRecords[index]
        let agentName = oauth.agentRuntimeInfo(id: writer.agentId)?.name ?? "agent"
        let reminder = ReminderRecord(
            id: UUID().uuidString.lowercased(),
            serverId: writer.serverId,
            ownerAgentId: writer.agentId,
            title: "Resource receipt expiry: \(objectName)",
            fireAt: expiry,
            notes: receiptJSON,
            channelId: channelId
        )
        reminderRecords.append(reminder)
        lock.unlock()
        let follow = "{\"ownerAgentId\":\(jsonString(writer.agentId)),\"owner\":\(jsonString("@" + agentName)),\"msgId\":\(jsonString(task.messageId)),\"targetChannelId\":\(jsonString(channelId)),\"reminderId\":\(jsonString(reminder.id)),\"fireAt\":\(jsonString(expiryRaw))}"
        return Self.json(200, "{\"ok\":true,\"taskNumber\":\(task.taskNumber),\"expiryFollowup\":\(follow)}")
    }

    public func agentTaskAssign(authorization: String?, body: String) -> HTTPReply {
        if let denial = agentCapabilityDenial(authorization, required: "tasks") { return denial }
        guard let credential = agentCredentialAgent(authorization),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        if let reply = agentGrantDenial(agentId: agent.id, scope: "task:write") { return reply }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let channelRef = object["channel"] as? String,
              let channelId = agentTaskChannel(serverId: agent.serverId, agentId: agent.id, reference: channelRef),
              let taskNumber = object["task_number"] as? Int,
              let rawAssignee = object["assignee"] as? String, !rawAssignee.isEmpty
        else {
            return Self.json(400, "{\"error\":\"Invalid task assign request\"}")
        }
        let handle = rawAssignee.hasPrefix("@") ? String(rawAssignee.dropFirst()) : rawAssignee
        let lowered = handle.lowercased()
        let agentMatch = oauth.channelAgentIds(channelId: channelId).compactMap { oauth.agentRuntimeInfo(id: $0) }.first {
            $0.name.lowercased() == lowered || $0.displayName.lowercased() == lowered
        }
        let humanMatch = oauth.channelHumanIds(channelId: channelId).compactMap { userId in
            accounts.values.first { $0.id == userId }
        }.first { $0.name.lowercased() == lowered }
        guard (agentMatch == nil) != (humanMatch == nil) else {
            return Self.json(404, "{\"error\":\"Assignee is not assignable\",\"code\":\"assignee_not_assignable\"}")
        }
        lock.lock()
        guard let index = taskRecords.firstIndex(where: { $0.channelId == channelId && $0.taskNumber == taskNumber }) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Task not found\",\"code\":\"assignee_not_assignable\"}")
        }
        if let agentMatch {
            taskRecords[index].assigneeId = agentMatch.id
            taskRecords[index].assigneeType = "agent"
        } else if let humanMatch {
            taskRecords[index].assigneeId = humanMatch.id
            taskRecords[index].assigneeType = "user"
        }
        taskRecords[index].claimedAt = nil
        taskRecords[index].revision += 1
        let task = taskRecords[index]
        lock.unlock()
        return Self.json(200, taskJSON(task))
    }




    public func setAgentInboxAvailableForTesting(_ value: Bool?) {
        lock.lock()
        agentInboxAvailable = value
        lock.unlock()
    }



    /// `GET /internal/agent-api/inbox/conversations`.
    public func agentInboxConversations(
        authorization: String?,
        limit rawLimit: String?,
        beforeSeq rawBefore: String?,
        view rawView: String?
    ) -> HTTPReply {
        let identity: (agentId: String, serverId: String)
        switch feedbackLocatorIdentity(authorization: authorization, capability: "read") {
        case .refused(let reply): return reply
        case .success(let agentId, let serverId): identity = (agentId, serverId)
        }
        lock.lock()
        let available = agentInboxAvailable ?? true
        lock.unlock()
        guard available else {
            return Self.json(503, "{\"error\":\"The agent inbox is unavailable\",\"code\":\"INBOX_UNAVAILABLE\",\"suggestedNextAction\":\"Retry after the inbox service recovers.\"}")
        }
        let view = rawView ?? "unread"
        guard view == "unread" || view == "mentions" else {
            return Self.json(400, "{\"error\":\"view must be unread or mentions\"}")
        }
        let limit: Int
        if let rawLimit, !rawLimit.isEmpty {
            guard let parsed = Int(rawLimit), parsed >= 1, parsed <= 100 else {
                return Self.json(400, "{\"error\":\"limit must be between 1 and 100\"}")
            }
            limit = parsed
        } else {
            limit = 20
        }
        var before: Int?
        if let rawBefore, !rawBefore.isEmpty {
            guard let parsed = Int(rawBefore), parsed > 0 else {
                return Self.json(400, "{\"error\":\"before_seq must be a positive integer\"}")
            }
            before = parsed
        }
        lock.lock()
        let serverId = identity.serverId
        let agentId = identity.agentId
        var rows: [AgentInboxRow] = []

        func latestMessage(_ storageChannelId: String) -> (seq: Int, message: StoredHumanMessage?) {
            let messages = humanMessageRows.filter { $0.channelId == storageChannelId }
            guard let last = messages.max(by: { $0.seq < $1.seq }) else { return (0, nil) }
            return (last.seq, last)
        }
        func senderName(_ message: StoredHumanMessage?) -> String? {
            guard let message else { return nil }
            if let external = message.externalSenderName { return external }
            if message.senderId == "system" { return "system" }
            return accounts.values.first { $0.id == message.senderId }?.name
                ?? oauth.agentRuntimeInfo(id: message.senderId)?.name
        }
        func mentionStats(channelId: String) -> (count: Int, maxSeq: Int?) {
            let ids = Set(storedMentions.filter {
                $0.targetType == "agent" && $0.targetId == agentId && $0.channelId == channelId
            }.map(\.messageId))
            guard !ids.isEmpty else { return (0, nil) }
            let messages = humanMessageRows.filter { $0.channelId == channelId }
            var maxSeq: Int?
            for message in messages where ids.contains(message.id) {
                maxSeq = message.seq
            }
            return (ids.count, maxSeq)
        }

        // Channel and DM rows.
        for (id, channel) in postableChannels {
            guard channel.serverId == serverId, channel.deletedAt == nil else { continue }
            let visible = channel.kind == "channel"
                || channel.memberIds.contains(agentId)
                || oauth.channelAgentIds(channelId: id).contains(agentId)
            guard visible else { continue }
            var target: String
            var kind: String
            if channel.kind == "dm", channel.name.hasPrefix("migration-receipt-"), channel.memberIds == [agentId] {
                target = "dm:@\(channel.name)"
                kind = "dm"
            } else if channel.kind == "dm" {
                let peer = channel.memberIds.compactMap { member -> (String, String)? in
                    guard member != agentId,
                          let account = accounts.values.first(where: { $0.id == member }),
                          oauth.memberRole(serverId: serverId, userId: member) != nil
                    else { return nil }
                    return (member, account.name)
                }.first
                guard let peer else { continue }
                target = "dm:@\(peer.1)"
                kind = "dm"
            } else if channel.kind == "channel" || channel.kind == "private" || channel.kind == "joint" {
                target = "#\(channel.name)"
                kind = "channel"
            } else {
                continue
            }
            let storage = jointProjections.first { $0.localChannelId == id }?.canonicalChannelId ?? id
            let latest = latestMessage(storage)
            guard latest.seq > 0 else { continue }
            let cursor = agentChannelReadCursors["\(id)\n\(agentId)"]?.seq ?? 0
            let unread = humanMessageRows.filter { $0.channelId == storage && $0.seq > cursor && $0.senderId != agentId }.count
            let mentions = mentionStats(channelId: storage)
            rows.append(AgentInboxRow(
                target: target,
                kind: kind,
                lastReadSeq: cursor,
                unread: unread,
                mentions: mentions.count,
                latestSeq: latest.seq,
                activitySeq: latest.seq,
                latestSenderName: senderName(latest.message) ?? "",
                latestAt: latest.message?.createdAt,
                joinedAt: latest.message?.createdAt ?? Date()
            ))
        }

        // Followed thread rows.
        for follow in threadFollows.values where follow.userId == agentId && follow.serverId == serverId {
            guard let thread = postableChannels[follow.threadChannelId], thread.deletedAt == nil,
                  let parentId = thread.parentChannelId,
                  let parent = postableChannels[parentId], parent.deletedAt == nil
            else { continue }
            let visible = thread.memberIds.contains(agentId)
                || oauth.channelAgentIds(channelId: follow.threadChannelId).contains(agentId)
                || parent.memberIds.contains(agentId)
                || oauth.channelAgentIds(channelId: parentId).contains(agentId)
            guard visible else { continue }
            let storage = jointProjections.first { $0.localChannelId == follow.threadChannelId }?.canonicalChannelId ?? follow.threadChannelId
            let latest = latestMessage(storage)
            guard latest.seq > 0 else { continue }
            let cursor = agentChannelReadCursors["\(follow.threadChannelId)\n\(agentId)"]?.seq ?? 0
            let unread = humanMessageRows.filter { $0.channelId == storage && $0.seq > cursor && $0.senderId != agentId }.count
            let mentions = mentionStats(channelId: storage)
            let parentShort = String((thread.parentMessageId ?? "").prefix(8))
            let target: String
            if parent.kind == "dm" {
                let peer = parent.memberIds.compactMap { member -> String? in
                    guard member != agentId,
                          let account = accounts.values.first(where: { $0.id == member }),
                          oauth.memberRole(serverId: serverId, userId: member) != nil
                    else { return nil }
                    return account.name
                }.first ?? "unknown"
                target = "dm:@\(peer):\(parentShort)"
            } else {
                target = "#\(parent.name):\(parentShort)"
            }
            rows.append(AgentInboxRow(
                target: target,
                kind: "thread",
                lastReadSeq: cursor,
                unread: unread,
                mentions: mentions.count,
                latestSeq: latest.seq,
                activitySeq: latest.seq,
                latestSenderName: senderName(latest.message) ?? "",
                latestAt: latest.message?.createdAt,
                joinedAt: threadFollowStarts["\(serverId)\n\(agentId)\n\(follow.threadChannelId)"] ?? Date()
            ))
        }
        lock.unlock()

        let totals = (
            conversations: rows.count,
            dms: rows.filter { $0.kind == "dm" }.count,
            mentions: rows.filter { $0.mentions > 0 }.count
        )
        var filtered = rows
        if view == "mentions" {
            filtered = filtered.filter { $0.mentions > 0 }
        } else {
            filtered = filtered.filter { $0.unread > 0 || $0.mentions > 0 }
        }
        if let before {
            filtered = filtered.filter { $0.activitySeq < before }
        }
        filtered.sort { left, right in
            if left.activitySeq != right.activitySeq { return left.activitySeq > right.activitySeq }
            return left.target < right.target
        }
        let hasMore = filtered.count > limit
        let page = Array(filtered.prefix(limit))
        let nextBefore = hasMore ? page.last?.activitySeq : nil
        let items = page.map { row -> String in
            let latestAt = row.latestAt.map { jsonString(Self.isoMillis($0)) } ?? "null"
            return "{\"target\":\(jsonString(row.target)),\"kind\":\(jsonString(row.kind)),\"unread\":\(row.unread),\"mentions\":\(row.mentions),\"lastReadSeq\":\(row.lastReadSeq),\"activitySeq\":\(row.activitySeq),\"latestSenderName\":\(jsonString(row.latestSenderName)),\"latestAt\":\(latestAt)}"
        }.joined(separator: ",")
        let nextJSON = nextBefore.map(String.init) ?? "null"
        return Self.json(200, "{\"view\":\(jsonString(view)),\"items\":[\(items)],\"totals\":{\"conversations\":\(totals.conversations),\"dms\":\(totals.dms),\"mentions\":\(totals.mentions)},\"hasMore\":\(hasMore),\"nextBeforeSeq\":\(nextJSON)}")
    }

    func agentHistoryThread(parentId: String, anchorMessageId: String) -> String? {
        for (id, channel) in postableChannels {
            guard channel.kind == "thread" else { continue }
            guard channel.parentChannelId == parentId else { continue }
            guard channel.parentMessageId == anchorMessageId else { continue }
            guard channel.deletedAt == nil else { continue }
            return id
        }
        return nil
    }

    func agentHistoryThreadById(parentId: String, suffix: String) -> String? {
        for (id, channel) in postableChannels {
            guard channel.kind == "thread" else { continue }
            guard channel.parentChannelId == parentId else { continue }
            guard id.hasPrefix(suffix) else { continue }
            guard channel.deletedAt == nil else { continue }
            return id
        }
        return nil
    }

    func agentHistoryThreadByAnchorPrefix(parentId: String, suffix: String) -> String? {
        for (id, channel) in postableChannels {
            guard channel.kind == "thread" else { continue }
            guard channel.parentChannelId == parentId else { continue }
            guard channel.parentMessageId?.hasPrefix(suffix) == true else { continue }
            guard channel.deletedAt == nil else { continue }
            return id
        }
        return nil
    }

    func actionCardTarget(serverId: String, agentId: String, target: String) -> (local: String, storage: String)? {
        guard target.hasPrefix("#") else { return nil }
        let name = String(target.dropFirst())
        lock.lock()
        var local: String?
        for (id, channel) in postableChannels {
            guard channel.serverId == serverId, channel.name == name, channel.deletedAt == nil,
                  channel.kind == "channel" || channel.kind == "private" || channel.kind == "joint"
            else { continue }
            if channel.kind != "channel",
               !channel.memberIds.contains(agentId),
               !oauth.channelAgentIds(channelId: id).contains(agentId) {
                continue
            }
            local = id
            break
        }
        let storage = local.flatMap { id in jointProjections.first { $0.localChannelId == id }?.canonicalChannelId } ?? local
        lock.unlock()
        guard let local, let storage else { return nil }
        return (local, storage)
    }

    /// Third-party text is rendered inert before it reaches agents: agent
    /// markup literals are escaped and `@name` refs become plain `user:name`
    /// labels, so a publisher name cannot fabricate a mention or a result tag.

    /// `@name` outside markdown code becomes the plain `user:name` label;
    /// backticked spans are literal data and keep their shape.



    func marketplaceInstallActionJSON(_ card: MarketplaceInstallCard, includeDraftHint: Bool = true) -> String {
        let scopes = card.scopes.map(jsonString).joined(separator: ",")
        let draftHint = includeDraftHint
            ? ",\"draftHint\":\(jsonString("\(card.agentName) requested \(card.clientName), which is public in the Raft Marketplace but is not installed on this Server. Installing is a Server owner/admin action; the Agent cannot install it automatically."))"
            : ""
        let setupUrl = card.setupUrl.map(jsonString) ?? "null"
        return "{\"type\":\"integration:install_marketplace_app\",\"clientId\":\(jsonString(card.clientRecordId)),\"clientKey\":\(jsonString(card.clientKey)),\"clientName\":\(jsonString(card.clientName)),\"clientNameSha256\":\(jsonString(card.clientNameSha256)),\"agentId\":\(jsonString(card.agentId)),\"agentName\":\(jsonString(card.agentName)),\"scopes\":[\(scopes)],\"setupUrl\":\(setupUrl),\"setupRevision\":\(card.setupRevision)\(draftHint)}"
    }

    func marketplaceInstallPresentationJSON(_ card: MarketplaceInstallCard) -> String {
        var items: [String] = []
        items.append("{\"key\":\"clientId\",\"value\":\(jsonString(card.clientRecordId))}")
        items.append("{\"key\":\"clientKey\",\"value\":\(jsonString(card.clientKey))}")
        items.append("{\"key\":\"clientName\",\"value\":\(jsonString(card.clientName))}")
        items.append("{\"key\":\"agentId\",\"value\":\(jsonString(card.agentId))}")
        items.append("{\"key\":\"agentName\",\"value\":\(jsonString(card.agentName))}")
        if !card.scopes.isEmpty {
            let scopes = card.scopes.map(jsonString).joined(separator: ", ")
            items.append("{\"key\":\"scopes\",\"value\":\(jsonString(scopes))}")
        }
        let warning = "This installs the Marketplace app for this Server so @\(card.agentName) can request the listed scopes."
        return "{\"title\":\(jsonString("Install \(card.clientName) on this Server")),\"confirmLabel\":\"Install App\",\"genericApprovalAllowed\":true,\"displayItems\":[\(items.joined(separator: ","))],\"warning\":\(jsonString(warning)),\"riskLevel\":\"elevated\"}"
    }

    func marketplaceInstallMetadataJSON(_ card: MarketplaceInstallCard) -> String {
        let executedAt = card.state == "executed" ? jsonString(ISO8601DateFormatter().string(from: Date())) : "null"
        let executedBy = card.executedByUserId.map(jsonString) ?? "null"
        let result = card.resultJSON ?? "null"
        return "{\"kind\":\"action-card\",\"sourceServerId\":\(jsonString(card.serverId)),\"targetServerName\":\(jsonString(actionCardServerName(card.serverId))),\"action\":\(marketplaceInstallActionJSON(card)),\"presentation\":\(marketplaceInstallPresentationJSON(card)),\"state\":\(jsonString(card.state)),\"executedAt\":\(executedAt),\"executedByUserId\":\(executedBy),\"result\":\(result)}"
    }

    /// The message projection of every prepared card, keyed by message id.
    func actionCardMetadataLocked(messageId: String) -> String? {
        if let card = marketplaceInstallCards[messageId] {
            return marketplaceInstallMetadataJSON(card)
        }
        if let card = integrationRegisterCards[messageId] {
            return integrationRegisterMetadataJSON(card)
        }
        return nil
    }

    func integrationRegisterActionJSON(_ card: IntegrationRegisterCard) -> String {
        var fields: [String] = [
            "\"type\":\"integration:register_app\"",
            "\"name\":\(jsonString(card.name))",
        ]
        if let clientKey = card.clientKey { fields.append("\"clientKey\":\(jsonString(clientKey))") }
        if let homepageUrl = card.homepageUrl { fields.append("\"homepageUrl\":\(jsonString(homepageUrl))") }
        fields.append("\"returnUrl\":\(jsonString(card.returnUrl))")
        if let agentManifestUrl = card.agentManifestUrl {
            fields.append("\"agentManifestUrl\":\(jsonString(agentManifestUrl))")
        }
        let scopes = card.scopes.map(jsonString).joined(separator: ",")
        fields.append("\"scopes\":[" + scopes + "]")
        if let setupUrl = card.setupUrl { fields.append("\"setupUrl\":\(jsonString(setupUrl))") }
        if let setupDescription = card.setupDescription { fields.append("\"setupDescription\":\(jsonString(setupDescription))") }
        return "{" + fields.joined(separator: ",") + "}"
    }

    func integrationRegisterPresentationJSON(_ card: IntegrationRegisterCard) -> String {
        var items: [String] = [
            "{\"key\":\"name\",\"value\":\(jsonString(card.name))}",
        ]
        if let clientKey = card.clientKey {
            items.append("{\"key\":\"clientKey\",\"value\":\(jsonString(clientKey))}")
        }
        items.append("{\"key\":\"returnUrl\",\"value\":\(jsonString(card.returnUrl))}")
        if !card.scopes.isEmpty {
            let scopes = card.scopes.map(jsonString).joined(separator: ", ")
            items.append("{\"key\":\"scopes\",\"value\":\(jsonString(scopes))}")
        }
        return "{\"title\":\(jsonString("Register Connected App \(card.name)")),\"confirmLabel\":\"Register App\",\"genericApprovalAllowed\":true,\"displayItems\":[\(items.joined(separator: ","))],\"warning\":\"The requesting agent becomes the initial app owner. No client secret is stored in this card.\",\"riskLevel\":\"elevated\"}"
    }

    func integrationRegisterMetadataJSON(_ card: IntegrationRegisterCard) -> String {
        let executedBy = card.executedByUserId.map(jsonString) ?? "null"
        let result = card.resultJSON ?? "null"
        return "{\"kind\":\"action-card\",\"sourceServerId\":\(jsonString(card.serverId)),\"targetServerName\":\(jsonString(actionCardServerName(card.serverId))),\"action\":\(integrationRegisterActionJSON(card)),\"presentation\":\(integrationRegisterPresentationJSON(card)),\"state\":\(jsonString(card.state)),\"executedByUserId\":\(executedBy),\"result\":\(result)}"
    }

    func prepareIntegrationRegisterCard(
        serverId: String,
        agent: OAuthLedger.AgentRuntimeInfo,
        name: String,
        clientKey: String?,
        homepageUrl: String?,
        returnUrl: String,
        agentManifestUrl: String?,
        setupUrl: String? = nil,
        setupDescription: String? = nil,
        scopes: [String],
        target: (local: String, storage: String)
    ) -> String {
        let messageId = UUID().uuidString.lowercased()
        let agentName = agent.displayName.isEmpty ? agent.name : agent.displayName
        let card = IntegrationRegisterCard(
            messageId: messageId,
            serverId: serverId,
            agentId: agent.id,
            agentName: agentName,
            storageChannelId: target.storage,
            localCarrierChannelId: target.local,
            name: name,
            clientKey: clientKey,
            homepageUrl: homepageUrl,
            returnUrl: returnUrl,
            agentManifestUrl: agentManifestUrl,
            setupUrl: setupUrl,
            setupDescription: setupDescription,
            scopes: scopes,
            state: "prepared",
            executedByUserId: nil,
            resultJSON: nil
        )
        let content = "Operation: register Login with Raft app \(name) (\(clientKey ?? "auto-generated client key"))"
        lock.lock()
        appendHumanMessageLocked(StoredHumanMessage(
            id: messageId,
            channelId: target.storage,
            senderId: agent.id,
            content: content,
            randomId: nil,
            messageType: "chat",
            senderType: "agent",
            actionKind: "action-card"
        ))
        integrationRegisterCards[messageId] = card
        lock.unlock()
        return messageId
    }


    func executeIntegrationRegisterCard(
        _ card: IntegrationRegisterCard,
        userId: String,
        serverId: String,
        body: String
    ) -> HTTPReply {
        guard card.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Action card not found\",\"code\":\"NOT_FOUND\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Only Server owners and admins can register apps\",\"errorCode\":\"FORBIDDEN\"}")
        }
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        if let expectedState = object?["expectedState"] as? String, expectedState != card.state {
            return Self.json(409, "{\"error\":\"The action card state changed\",\"code\":\"STATE_MISMATCH\"}")
        }
        if card.state == "executed" {
            return Self.json(200, "{\"messageId\":\(jsonString(card.messageId)),\"metadata\":\(integrationRegisterMetadataJSON(card))}")
        }
        guard let agent = oauth.agentRuntimeInfo(id: card.agentId), !agent.deleted else {
            return Self.json(409, "{\"error\":\"Requesting agent no longer exists; prepare a fresh request\",\"errorCode\":\"AGENT_BINDING_CHANGED\"}")
        }
        let clientKey = card.clientKey ?? Self.generatedIntegrationClientKey(card.name)
        let created: CreatedOAuthClient
        do {
            created = try oauth.createClient(
                serverId: card.serverId,
                createdByUserId: userId,
                name: card.name,
                clientId: clientKey,
                appType: "server_local",
                homepageUrl: card.homepageUrl,
                returnUrl: card.returnUrl,
                allowedScopes: card.scopes,
                agentManifestUrl: card.agentManifestUrl,
                setupUrl: card.setupUrl,
                setupDescription: card.setupDescription
            )
        } catch let error as OAuthClientRejection {
            return Self.json(409, "{\"error\":\(jsonString(error.message)),\"errorCode\":\"APP_REGISTRATION_REJECTED\"}")
        } catch {
            return Self.json(400, "{\"error\":\"Invalid app registration\",\"errorCode\":\"INVALID_APP_METADATA\"}")
        }
        oauth.addClientMaintainer(clientRecordId: created.id, agentId: card.agentId)
        let scopes = card.scopes.map(jsonString).joined(separator: ",")
        let result = "{\"kind\":\"integration-app-registration\",\"mode\":\"register\",\"clientId\":\(jsonString(created.id)),\"clientKey\":\(jsonString(created.clientId)),\"clientName\":\(jsonString(card.name)),\"scopes\":[\(scopes)]}"
        var updated = card
        updated.state = "executed"
        updated.executedByUserId = userId
        updated.resultJSON = result
        lock.lock()
        integrationRegisterCards[card.messageId] = updated
        lock.unlock()
        return Self.json(200, "{\"messageId\":\(jsonString(card.messageId)),\"metadata\":\(integrationRegisterMetadataJSON(updated))}")
    }
}

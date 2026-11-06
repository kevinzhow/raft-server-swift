import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Agent send, delivery-ack, activity ingest and agent thread routes.
///
/// These handlers were lifted from the second contiguous half of
/// `EmailLogin+ComputersUsage2.swift`. They stay on `EmailLoginDirectory`
/// because the directory owns the lock and the agent ledgers;
/// `AgentSendDeliveryService` is the named, `Sendable` handle for the domain.
public struct AgentSendDeliveryService: Sendable {
    public let directory: EmailLoginDirectory

    public init(directory: EmailLoginDirectory) {
        self.directory = directory
    }
}

extension EmailLoginDirectory {    public func agentSend(authorization: String?, agentId: String, body: String) -> HTTPReply {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return Self.json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
        }
        let apiKey = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let machine = machines.first { $0.apiKey == apiKey }
        let legacy = machineKeys[apiKey]
        lock.unlock()
        guard let machineServerId = machine?.serverId ?? legacy?.serverId else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        guard let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted, agent.serverId == machineServerId else {
            return Self.json(404, "{\"error\":\"Agent not found\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let target = object["target"] as? String,
              let content = object["content"] as? String,
              target.hasPrefix("#")
        else {
            return Self.json(400, "{\"error\":\"Invalid target\"}")
        }
        let rawName = String(target.dropFirst())
        let segments = rawName.split(separator: ":", maxSplits: 1).map(String.init)
        let name = segments.first ?? rawName
        let shortId = segments.count > 1 ? segments[1] : nil
        lock.lock()
        let candidate = postableChannels.first { channelId, channel in
            channel.serverId == agent.serverId && channel.name == name && channel.deletedAt == nil
        }
        var resolved: (String, PostableChannel)? = candidate
        if let shortId, let (parentId, parent) = candidate {
            guard oauth.channelAgentIds(channelId: parentId).contains(agent.id) else {
                lock.unlock()
                return Self.json(403, "{\"error\":\"Agent is not a member of the parent channel\"}")
            }
            resolved = postableChannels.first { _, channel in
                channel.serverId == agent.serverId
                    && channel.kind == "thread"
                    && channel.parentChannelId == parentId
                    && (channel.parentMessageId?.hasPrefix(shortId) ?? false)
                    && channel.deletedAt == nil
            }
            if resolved == nil {
                lock.unlock()
                return Self.json(404, "{\"error\":\"Thread not found\"}")
            }
        }
        lock.unlock()
        guard let (channelId, channel) = resolved else {
            return Self.json(404, "{\"error\":\"Channel not found\"}")
        }
        if shortId == nil, !oauth.channelAgentIds(channelId: channelId).contains(agent.id) {
            return Self.json(403, "{\"error\":\"Agent is not a member of this channel\"}")
        }
        if channel.archived {
            return Self.json(409, "{\"error\":\"This channel is archived\",\"code\":\"channel_archived\"}")
        }
        let messageId = UUID().uuidString.lowercased()
        lock.lock()
        appendHumanMessageLocked(StoredHumanMessage(
            id: messageId,
            channelId: channelId,
            senderId: agent.id,
            content: content,
            randomId: nil,
            senderType: "agent"
        ))
        lock.unlock()
        return Self.json(200, "{\"id\":\(jsonString(messageId)),\"channelId\":\(jsonString(channelId))}")
    }

    /// `POST /internal/agent/:agentId/receive-ack` — legacy delivery ack.
    ///
    /// The volatile delivery buffer ack is not modeled here (the port has no
    /// orchestrator). Pre-model-seen daemons additionally get the per-channel
    /// usability checkpoint this route always kept; a daemon that advertises
    /// the model-seen boundary capability is a volatile ack only, so legacy
    /// state can never masquerade as freshness proof.
    public func legacyAgentReceiveAck(authorization: String?, agentId: String, body: String) -> HTTPReply {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return Self.json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
        }
        let apiKey = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let machine = machines.first { $0.apiKey == apiKey }
        let legacy = machineKeys[apiKey]
        var capability = machineModelSeenCapability.contains(agentId)
        if let machine, machineModelSeenCapability.contains(machine.id) { capability = true }
        lock.unlock()
        guard let serverId = machine?.serverId ?? legacy?.serverId else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        if let legacy, legacy.agentId != agentId {
            return Self.json(404, "{\"error\":\"Agent not found\"}")
        }
        guard let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted, agent.serverId == serverId else {
            return Self.json(404, "{\"error\":\"Agent not found\"}")
        }
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
        var seenSeqs = Set<Int>()
        var seqs: [Int] = []
        if let raw = object["seqs"] as? [Any] {
            for item in raw {
                guard let number = item as? NSNumber, number.doubleValue.isFinite else { continue }
                let value = Int(number.doubleValue.rounded(.down))
                guard value > 0, seenSeqs.insert(value).inserted else { continue }
                seqs.append(value)
            }
        }
        let messageIds = (object["messageIds"] as? [Any])?
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []
        guard !seqs.isEmpty || !messageIds.isEmpty else {
            return Self.json(400, "{\"error\":\"seqs or messageIds must be a non-empty array\"}")
        }
        if capability || seqs.isEmpty {
            return Self.json(200, "{\"ok\":true}")
        }
        var maxSeqByChannel: [String: Int] = [:]
        lock.lock()
        for seq in seqs {
            for row in humanMessageRows where row.seq == seq {
                let storageId = row.channelId
                let localId = jointProjections.first {
                    $0.canonicalChannelId == storageId && $0.serverId == serverId
                }?.localChannelId ?? storageId
                guard let channel = postableChannels[localId] else { continue }
                let isMember: Bool
                if channel.kind == "thread", let parentId = channel.parentChannelId {
                    isMember = postableChannels[parentId]?.memberIds.contains(agentId) == true
                        || oauth.channelAgentIds(channelId: parentId).contains(agentId)
                        || threadFollows.values.contains {
                            $0.serverId == serverId && $0.userId == agentId && $0.threadChannelId == localId
                        }
                } else {
                    isMember = channel.memberIds.contains(agentId)
                        || oauth.channelAgentIds(channelId: localId).contains(agentId)
                }
                guard isMember else { continue }
                maxSeqByChannel[localId] = max(maxSeqByChannel[localId] ?? 0, seq)
            }
        }
        for (channelId, maxSeq) in maxSeqByChannel {
            let key = "\(channelId)\n\(agentId)"
            let previous = agentChannelReadCursors[key] ?? (seq: 0, version: 0)
            if maxSeq > previous.seq {
                agentChannelReadCursors[key] = (maxSeq, previous.version + 1)
            }
        }
        lock.unlock()
        return Self.json(200, "{\"ok\":true}")
    }

    public func runtimeProfileMigrationDone(authorization: String?, agentId: String, body: String) -> HTTPReply {
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return Self.json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
        }
        let apiKey = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        guard let machine = machines.first(where: { $0.apiKey == apiKey }) else {
            lock.unlock()
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        lock.unlock()
        guard let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted, agent.serverId == machine.serverId else {
            return Self.json(404, "{\"error\":\"Agent not found\"}")
        }
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        let migrationKey = (object?["migrationKey"] as? String) ?? ""
        let message = "Runtime Profile migration acknowledgments are deprecated; runtime changes reset the session automatically."
        if migrationKey.isEmpty {
            return Self.json(200, "{\"ok\":true,\"deprecated\":true,\"noop\":\"no pending migration\",\"message\":\(jsonString(message))}")
        }
        return Self.json(200, "{\"ok\":true,\"deprecated\":true,\"message\":\(jsonString(message))}")
    }

    public func markAgentHosted(agentId: String) {
        lock.lock()
        hostedAgents.insert(agentId)
        lock.unlock()
    }

    public func agentActivityIngest(authorization: String?, body: String) -> HTTPReply {
        guard let credential = agentCredentialAgent(authorization),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted,
              credential.scopes.contains("read")
        else {
            return Self.json(403, "{\"error\":\"Agent credential is not authorized for this capability\",\"code\":\"capability_not_authorized\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return Self.json(400, "{\"error\":\"Invalid activity ingest\",\"code\":\"activity_invalid\"}")
        }
        if object["schema"] as? String == "raft-agent-activity-ingest.v1" {
            guard let events = object["events"] as? [[String: Any]] else {
                return Self.json(400, "{\"error\":\"Invalid activity ingest\",\"code\":\"activity_invalid\"}")
            }
            let allowed: Set<String> = [
                "eventId", "hookEventName", "toolName", "toolInput", "truncated",
                "tool_use_id", "exit_code", "ok", "subagent",
            ]
            var ignored: Set<String> = []
            for event in events {
                for key in event.keys where !allowed.contains(key) {
                    if key == "transcript_path" {
                        return Self.json(400, "{\"error\":\"transcript_path is not accepted\",\"code\":\"transcript_path_forbidden\"}")
                    }
                    ignored.insert(key)
                }
            }
            let dropped = (object["dropped"] as? NSNumber)?.intValue ?? 0
            var fields = ""
            if !ignored.isEmpty {
                let names = ignored.sorted().map(jsonString).joined(separator: ",")
                fields = ",\"ignoredFields\":[\(names)]"
            }
            return Self.json(200, "{\"ok\":true,\"acceptedCount\":\(events.count),\"rejectedCount\":0,\"droppedCount\":\(dropped)\(fields)}")
        }
        guard let events = object["events"] as? [[String: Any]] else {
            return Self.json(400, "{\"error\":\"Invalid activity ingest\",\"code\":\"activity_invalid\"}")
        }
        let standardStatuses: Set<String> = ["working", "thinking", "online", "error", "offline"]
        var accepted = 0
        var rejected = 0
        var seen = agentActivityEventIds[agent.id] ?? []
        for event in events {
            guard let eventId = event["eventId"] as? String, !eventId.isEmpty,
                  let rawOccurred = event["occurredAt"] as? String,
                  let occurred = Self.isoDate(rawOccurred)
            else {
                rejected += 1
                continue
            }
            if seen.contains(eventId) {
                rejected += 1
                continue
            }
            let rawStatus = event["status"] as? String
            if let rawStatus, !standardStatuses.contains(rawStatus), rawStatus != "failed" {
                return Self.json(400, "{\"error\":\"Invalid agent status\",\"code\":\"status_invalid\"}")
            }
            if let detailValue = event["detail"] {
                guard let detail = detailValue as? String else {
                    return Self.json(400, "{\"error\":\"Invalid status detail\",\"code\":\"detail_invalid\"}")
                }
                if detail.count > 200 {
                    return Self.json(400, "{\"error\":\"Status detail is too long\",\"code\":\"detail_too_long\"}")
                }
            }
            let now = Date()
            let effective = min(occurred, now)
            seen.insert(eventId)
            accepted += 1
            let isStandardStatus = rawStatus.map { standardStatuses.contains($0) } ?? false
            let hookName = event["hookEventName"] as? String
            let detail = (event["detail"] as? String) ?? ""
            if isStandardStatus {
                agentStatusAdopted.insert(agent.id)
                if effective >= (agentStatusOccurredAt[agent.id] ?? .distantPast) {
                    agentStatusOccurredAt[agent.id] = effective
                    let mapped = rawStatus == "working" || rawStatus == "thinking" ? rawStatus! : rawStatus!
                    agentActivities[agent.id] = (activity: mapped, detail: detail)
                }
            } else if hookName != nil, !agentStatusAdopted.contains(agent.id) {
                let hookStatus: String
                switch hookName {
                case "PreToolUse": hookStatus = "working"
                case "PostToolUseFailure": hookStatus = "error"
                case "Stop", "SessionEnd": hookStatus = "online"
                default: hookStatus = "working"
                }
                if effective >= (agentStatusOccurredAt[agent.id] ?? .distantPast) {
                    agentStatusOccurredAt[agent.id] = effective
                    agentActivities[agent.id] = (activity: hookStatus, detail: "")
                }
            }
        }
        agentActivityEventIds[agent.id] = seen
        return Self.json(200, "{\"ok\":true,\"acceptedCount\":\(accepted),\"rejectedCount\":\(rejected),\"droppedCount\":0}")
    }

    public func followThreadForAgentTesting(
        serverId: String,
        agentId: String,
        threadChannelId: String,
        parentMessageId: String,
        reason: String = "manual",
        followedAt: Date = Date(),
        unfollowedAt: Date? = nil
    ) {
        lock.lock()
        threadFollowStore.upsert(AgentThreadFollowRecord(
            serverId: serverId,
            agentId: agentId,
            threadChannelId: threadChannelId,
            parentMessageId: parentMessageId,
            followedAt: followedAt,
            reason: reason,
            doneAt: nil,
            unfollowedAt: unfollowedAt
        ))
        lock.unlock()
    }

    public func agentThreadList(authorization: String?) -> HTTPReply {
        guard let credential = agentCredentialAgent(authorization),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        guard credential.scopes.contains("read") else {
            return Self.json(403, "{\"error\":\"Agent credential is not authorized for this capability\",\"code\":\"capability_not_authorized\"}")
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        lock.lock()
        let rows = threadFollowStore.all()
            .filter { $0.serverId == agent.serverId && $0.agentId == agent.id && $0.unfollowedAt == nil }
            .filter { messageSearchVisibleLocked(messageChannelId: $0.threadChannelId, serverId: agent.serverId, viewer: .agent(agent.id)) }
            .sorted { $0.followedAt > $1.followedAt }
            .compactMap { follow -> String? in
                guard let thread = postableChannels[follow.threadChannelId],
                      let parentChannelId = thread.parentChannelId,
                      let parent = postableChannels[parentChannelId]
                else { return nil }
                let short = String(follow.parentMessageId.prefix(8))
                let doneJSON = follow.doneAt.map { jsonString(formatter.string(from: $0)) } ?? "null"
                return "{\"target\":\(jsonString("#\(parent.name):\(short)")),\"threadChannelId\":\(jsonString(follow.threadChannelId)),\"parentChannelRef\":\(jsonString("#\(parent.name)")),\"parentMessageId\":\(jsonString(follow.parentMessageId)),\"parentMessageShortId\":\(jsonString(short)),\"followedAt\":\(jsonString(formatter.string(from: follow.followedAt))),\"reason\":\(jsonString(follow.reason)),\"doneAt\":\(doneJSON)}"
            }
        lock.unlock()
        return Self.json(200, "{\"threads\":[\(rows.joined(separator: ","))]}")
    }

    public func agentThreadUnfollow(authorization: String?, body: String, legacyAgentId: String? = nil) -> HTTPReply {
        guard let writer = agentTaskWriter(authorization, legacyAgentId: legacyAgentId),
              let agent = oauth.agentRuntimeInfo(id: writer.agentId), !agent.deleted
        else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        if let credential = agentCredentialAgent(authorization), !credential.scopes.contains("read") {
            return Self.json(403, "{\"error\":\"Agent credential is not authorized for this capability\",\"code\":\"capability_not_authorized\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let threadRef = object["thread"] as? String, !threadRef.isEmpty
        else {
            return Self.json(400, "{\"error\":\"Invalid thread unfollow request\"}")
        }
        if threadRef.hasPrefix("#"), !threadRef.contains(":") {
            return Self.json(400, "{\"error\":\"Target must be a thread\"}")
        }
        lock.lock()
        var threadId: String?
        if threadRef.hasPrefix("#"), let colon = threadRef.firstIndex(of: ":") {
            let channelName = String(threadRef[threadRef.index(after: threadRef.startIndex)..<colon])
            let short = String(threadRef[threadRef.index(after: colon)...])
            if let parent = postableChannels.first(where: { $0.value.serverId == agent.serverId && $0.value.name == channelName })?.key {
                threadId = postableChannels.first { _, candidate in
                    candidate.kind == "thread"
                        && candidate.parentChannelId == parent
                        && (candidate.parentMessageId?.hasPrefix(short) ?? false)
                }?.key
            }
        } else {
            threadId = threadRef
        }
        guard let resolved = threadId,
              let thread = postableChannels[resolved],
              thread.serverId == agent.serverId,
              thread.kind == "thread",
              thread.deletedAt == nil
        else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Thread not found\"}")
        }
        guard messageSearchVisibleLocked(messageChannelId: resolved, serverId: agent.serverId, viewer: .agent(agent.id)) else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"Thread not found\"}")
        }
        threadFollowStore.markUnfollowed(
            serverId: agent.serverId,
            agentId: agent.id,
            threadChannelId: resolved,
            at: Date()
        )
        lock.unlock()
        return Self.json(200, "{\"ok\":true}")
    }



    public func agentIntegrationList(authorization: String?) -> HTTPReply {
        guard let credential = agentCredentialAgent(authorization),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        let services = oauth.integrationServices(serverId: agent.serverId)
        lock.lock()
        let active = agentIntegrationLogins.values
            .filter { $0.serverId == agent.serverId && $0.agentId == agent.id }
            .sorted { $0.loggedInAt < $1.loggedInAt }
            .compactMap { login -> String? in
                guard let service = services.first(where: { ($0["id"] as? String) == login.clientId }) else { return nil }
                let clientId = service["clientId"] as? String ?? ""
                return "{\"clientId\":\(jsonString(clientId)),\"agentManifestUrl\":\(Self.integrationValueJSON(service, "agentManifestUrl")),\"agentManifestUrlSource\":\(Self.integrationValueJSON(service, "agentManifestUrlSource"))}"
            }
        lock.unlock()
        let servicesJSON = services.map { service -> String in
            let base = Self.integrationServiceJSON(service)
            guard let recordId = service["id"] as? String,
                  let state = oauth.getAppInstallationSetup(clientRecordId: recordId, serverId: agent.serverId)
            else { return base }
            let setup = "{\"status\":\(jsonString(state.status.rawValue)),\"url\":\(state.url.map(jsonString) ?? "null"),\"description\":\(state.description.map(jsonString) ?? "null"),\"revision\":\(state.revision)}"
            return String(base.dropLast()) + ",\"setup\":\(setup)}"
        }.joined(separator: ",")
        return Self.json(200, "{\"services\":[\(servicesJSON)],\"activeLogins\":[\(active.joined(separator: ","))]}")
    }

}

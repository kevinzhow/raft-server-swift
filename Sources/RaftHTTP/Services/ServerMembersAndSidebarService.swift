import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Server membership, invite/join-link and sidebar-order routes.
///
/// These handlers were lifted from `EmailLogin+ServerMembersAndTasks1.swift`.
/// They stay on `EmailLoginDirectory` because the directory owns the lock and
/// the server/channel ledgers; `ServerMembersAndSidebarService` is the named,
/// `Sendable` handle a caller can hold instead of reaching for the composition
/// root. The struct carries no state of its own.
public struct ServerMembersAndSidebarService: Sendable {
    public let directory: EmailLoginDirectory

    public init(directory: EmailLoginDirectory) {
        self.directory = directory
    }
}

extension EmailLoginDirectory {


    public func patchServerMemberRole(authorization: String?, serverId: String, memberId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Only the owner can change member roles\"}")
        }
        guard let targetRole = oauth.memberRole(serverId: serverId, userId: memberId) else {
            return Self.json(404, "{\"error\":\"Member not found\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let newRole = object["role"] as? String,
              ["owner", "admin", "member", "guest"].contains(newRole)
        else {
            return Self.json(400, "{\"error\":\"Invalid member role\"}")
        }
        if role == "admin", targetRole == "owner" || targetRole == "admin" || newRole == "owner" {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        if memberId == userId {
            let canSelfDemoteToGuest = targetRole == "owner" && newRole == "guest" && oauth.ownerCount(serverId: serverId) > 1
            guard canSelfDemoteToGuest else {
                return Self.json(400, "{\"error\":\"You cannot change your own role\"}")
            }
        }
        if newRole == "guest" {
            lock.lock()
            let enabled = guestRoleServers.contains(serverId)
            lock.unlock()
            guard enabled else {
                return Self.json(403, "{\"error\":\"Guest role transitions are not enabled\"}")
            }
        }
        if targetRole == "guest", newRole == "member" {
            // The seat cap and the holder count are one store critical section.
            let message = serversAndChannelsStore.seatLimitMessage(
                serverId: serverId,
                usedSeats: { [oauth] serverId in
                    oauth.memberIdsWithRoles(serverId: serverId).filter { $0.role != "guest" }.count
                }
            )
            if let message {
                return Self.json(409, "{\"error\":\(jsonString(message)),\"code\":\"human_seat_limit_reached\"}")
            }
        }
        oauth.addMember(serverId: serverId, userId: memberId, role: newRole)
        if newRole == "guest", let allChannel = oauth.allChannelId(serverId: serverId) {
            oauth.removeChannelHuman(channelId: allChannel, userId: memberId)
        }
        if newRole != targetRole {
            let payload = "{\"serverId\":\(jsonString(serverId)),\"userId\":\(jsonString(memberId)),\"previousRole\":\(jsonString(targetRole)),\"role\":\(jsonString(newRole))}"
            emitRealtime("server:\(serverId)", "server:member-updated", payload)
            lock.lock()
            recordServerMemberEvent(
                serverId: serverId, eventType: "server.member_role_changed", subjectType: "member", subjectId: memberId,
                provenanceJSON: "{\"actor_type\":\"human\",\"previous_role\":\(jsonString(targetRole)),\"principal_type\":\"human\",\"role\":\(jsonString(newRole)),\"source\":\"server_service\"}"
            )
            lock.unlock()
        }
        return Self.json(200, "{\"ok\":true,\"changed\":true}")
    }

    public func removeServerMember(authorization: String?, serverId: String, memberId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard let targetRole = oauth.memberRole(serverId: serverId, userId: memberId) else {
            return Self.json(404, "{\"error\":\"Member not found\"}")
        }
        if targetRole == "owner" {
            guard role == "owner" else {
                return Self.json(403, "{\"error\":\"Forbidden\"}")
            }
            guard oauth.ownerCount(serverId: serverId) > 1 else {
                return Self.json(400, "{\"error\":\"The last owner cannot be removed\"}")
            }
        }
        oauth.removeMember(serverId: serverId, userId: memberId)
        lock.lock()
        serverMemberStatuses["\(serverId)\n\(memberId)"] = "removed"
        lock.unlock()
        lock.lock()
        recordServerMemberEvent(
            serverId: serverId, eventType: "server.member_removed", subjectType: "member", subjectId: memberId,
            provenanceJSON: "{\"actor_type\":\"human\",\"principal_type\":\"human\",\"reason\":\"removed\",\"role\":\(jsonString(targetRole)),\"source\":\"server_service\"}"
        )
        for (threadId, thread) in postableChannels where thread.kind == "thread" && thread.serverId == serverId {
            guard let parentId = thread.parentChannelId,
                  let parent = postableChannels[parentId],
                  parent.kind == "private" || parent.kind == "dm"
            else { continue }
            threadFollows.removeValue(forKey: "\(serverId)\n\(memberId)\n\(threadId)")
        }
        removedServerMembers.insert("\(serverId)\n\(memberId)")
        lock.unlock()
        emitRealtime("server:\(serverId)", "server:member-removed", "{\"serverId\":\(jsonString(serverId)),\"userId\":\(jsonString(memberId))}")
        emitRealtime("user:\(memberId)", "server:membership-removed", "{\"serverId\":\(jsonString(serverId))}")
        return Self.json(200, "{\"ok\":true}")
    }

    public func deleteServerRoute(authorization: String?, serverId: String) -> HTTPReply {
        lock.lock()
        let alreadyDeleted = deletedServerIds.contains(serverId)
        lock.unlock()
        guard !alreadyDeleted else {
            return Self.json(200, "{\"ok\":true}")
        }
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard role == "owner" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        let memberIds = oauth.memberIdsWithRoles(serverId: serverId).map(\.id)
        let agentIds = oauth.serverAgents(serverId: serverId).map(\.id)
        lock.lock()
        for memberId in memberIds {
            recordServerMemberEvent(
                serverId: serverId, eventType: "server.member_removed", subjectType: "member", subjectId: memberId,
                provenanceJSON: "{\"actor_type\":\"human\",\"principal_type\":\"human\",\"reason\":\"server_deleted\",\"role\":\"member\",\"source\":\"server_service\"}"
            )
        }
        for agentId in agentIds {
            recordServerMemberEvent(
                serverId: serverId, eventType: "server.member_removed", subjectType: "agent", subjectId: agentId,
                provenanceJSON: "{\"actor_type\":\"human\",\"principal_type\":\"agent\",\"reason\":\"server_deleted\",\"role\":\"member\",\"source\":\"server_service\"}"
            )
        }
        lock.unlock()
        oauth.deleteServer(id: serverId)
        lock.lock()
        deletedServerIds.insert(serverId)
        lock.unlock()
        emitRealtime("server:\(serverId)", "server:deleted", "{\"serverId\":\(jsonString(serverId))}")
        for memberId in memberIds {
            emitRealtime("user:\(memberId)", "server:membership-removed", "{\"serverId\":\(jsonString(serverId))}")
        }
        return Self.json(200, "{\"ok\":true}")
    }


    func sidebarHumanDMChannelId(peerId: String, userId: String, serverId: String) -> String? {
        oauth.channelsForServer(serverId: serverId, userId: userId, includeArchived: true)
            .first {
                $0.type == "dm"
                    && oauth.channelHumanIds(channelId: $0.id).contains(userId)
                    && oauth.channelHumanIds(channelId: $0.id).contains(peerId)
                    && oauth.channelAgentIds(channelId: $0.id).isEmpty
            }?.id
    }

    func sidebarPinnedChannel(
        id: String,
        serverId: String,
        userId: String
    ) -> SidebarPinnedChannelResolution {
        guard let channel = oauth.channelInfo(id: id), channel.serverId == serverId else {
            return .missing
        }
        let type = oauth.channelType(id: id) ?? "channel"
        if type == "dm" {
            let agents = oauth.channelAgentIds(channelId: id)
            if agents.count == 1 {
                return .dm(("agent", agents[0]), legacyId: id)
            }
            let humans = oauth.channelHumanIds(channelId: id).filter { $0 != userId }
            if let peer = humans.first {
                return .dm(("human", peer), legacyId: id)
            }
            return .missing
        }
        if type == "private" && !oauth.channelHumanIds(channelId: id).contains(userId) {
            return .missing
        }
        return .channel(("channel", id))
    }

    public func patchSidebarOrder(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(404, "{\"error\":\"Server not found\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return Self.json(400, "{\"error\":\"Invalid sidebar order\"}")
        }
        let key = "\(serverId)\n\(userId)"
        lock.lock()
        var modes = sidebarModes[key] ?? ("manual", "manual", "manual", "manual", ["chat"], ["activity", "profile"])
        lock.unlock()
        func mode(_ field: String, _ current: String) -> String? {
            guard let raw = object[field] else { return current }
            guard let value = raw as? String, ["manual", "recent", "az"].contains(value) else { return nil }
            return value
        }
        guard let channel = mode("channelSortMode", modes.channel),
              let joint = mode("jointChannelSortMode", modes.joint),
              let dm = mode("dmSortMode", modes.dm),
              let pinned = mode("pinnedSortMode", modes.pinned)
        else {
            return Self.json(400, "{\"error\":\"Invalid sidebar sort mode\"}")
        }
        func tabs(_ field: String, _ current: [String], allowed: Set<String>) -> [String]? {
            guard let raw = object[field] else { return current }
            guard let values = raw as? [String] else { return nil }
            return values.filter { allowed.contains($0) }
        }
        guard let channelTabs = tabs("channelPanelTabOrder", modes.channelTabs, allowed: ["files", "tasks", "chat"]),
              let agentTabs = tabs("agentPanelTabOrder", modes.agentTabs, allowed: ["activity", "integrations", "profile"])
        else {
            return Self.json(400, "{\"error\":\"Invalid sidebar panel order\"}")
        }
        lock.lock()
        var sections = sidebarSections[key] ?? ([], ["system:pinned", "system:joint", "system:channels", "system:dms"], [], 0)
        lock.unlock()
        let hasSectionFields = object["customSections"] != nil || object["sectionOrder"] != nil || object["sectionPlacements"] != nil
        if hasSectionFields {
            if let rawVersion = object["sectionsVersion"] {
                guard let version = rawVersion as? Int, version == sections.version else {
                    return Self.json(409, "{\"error\":\"Sidebar sections changed\",\"code\":\"SIDEBAR_SECTIONS_VERSION_CONFLICT\"}")
                }
            }
            if let rawSections = object["customSections"] {
                guard let entries = rawSections as? [[String: Any]] else {
                    return Self.json(400, "{\"error\":\"Invalid custom sections\"}")
                }
                var parsed: [(id: String, name: String, emoji: String?, sortMode: String)] = []
                for entry in entries {
                    guard let id = entry["id"] as? String, !id.isEmpty,
                          let name = entry["name"] as? String
                    else { return Self.json(400, "{\"error\":\"Invalid custom sections\"}") }
                    let emoji: String?
                    if let raw = entry["emoji"], !(raw is NSNull) {
                        guard let value = raw as? String else { return Self.json(400, "{\"error\":\"Invalid custom sections\"}") }
                        emoji = value
                    } else {
                        emoji = nil
                    }
                    let sortMode = (entry["sortMode"] as? String) ?? "manual"
                    guard ["manual", "recent", "az"].contains(sortMode) else {
                        return Self.json(400, "{\"error\":\"Invalid custom sections\"}")
                    }
                    parsed.append((id, name.trimmingCharacters(in: .whitespacesAndNewlines), emoji, sortMode))
                }
                sections.sections = parsed
            }
            if let rawOrder = object["sectionOrder"] {
                guard let requested = rawOrder as? [String] else {
                    return Self.json(400, "{\"error\":\"Invalid section order\"}")
                }
                var order = requested
                for system in ["system:pinned", "system:joint", "system:channels", "system:dms"] where !order.contains(system) {
                    order.append(system)
                }
                sections.order = order
            }
            if let rawPlacements = object["sectionPlacements"] {
                guard let entries = rawPlacements as? [[String: Any]] else {
                    return Self.json(400, "{\"error\":\"Invalid section placements\"}")
                }
                var placements: [(kind: String, id: String, sectionId: String, position: Int)] = []
                for entry in entries {
                    guard let kind = entry["kind"] as? String, ["channel", "agent"].contains(kind),
                          let id = entry["id"] as? String,
                          let sectionId = entry["sectionId"] as? String
                    else { return Self.json(400, "{\"error\":\"Invalid section placements\"}") }
                    if kind == "channel" {
                        lock.lock()
                        let exists = postableChannels[id]?.deletedAt == nil && postableChannels[id] != nil
                        lock.unlock()
                        guard exists else { continue }
                    }
                    placements.append((kind, id, sectionId, placements.count))
                }
                sections.placements = placements
            }
            sections.version += 1
        }
        lock.lock()
        var pinnedState = sidebarPinnedRefs[key] ?? ([], [], [], 0)
        lock.unlock()
        var pinnedChanged = false
        if let rawPinned = object["pinned"] {
            guard object["pinnedChannelIds"] == nil else {
                return Self.json(400, "{\"error\":\"Invalid sidebar pinned references\"}")
            }
            guard let entries = rawPinned as? [[String: Any]] else {
                return Self.json(400, "{\"error\":\"Invalid sidebar pinned references\"}")
            }
            var refs: [(kind: String, id: String)] = []
            var channelIds: [String] = []
            var agentIds: [String] = []
            for entry in entries {
                guard let kind = entry["kind"] as? String,
                      ["channel", "agent", "human"].contains(kind),
                      let id = entry["id"] as? String,
                      !id.isEmpty
                else {
                    return Self.json(400, "{\"error\":\"Invalid sidebar pinned references\"}")
                }
                if kind == "channel" {
                    switch sidebarPinnedChannel(id: id, serverId: serverId, userId: userId) {
                    case .missing:
                        continue
                    case .channel(let canonical):
                        refs.append(canonical)
                        channelIds.append(id)
                    case .dm(let canonical, let legacyId):
                        refs.append(canonical)
                        channelIds.append(legacyId)
                    }
                } else if kind == "agent" {
                    guard let agent = oauth.agentRuntimeInfo(id: id), agent.serverId == serverId else { continue }
                    refs.append(("agent", id))
                    agentIds.append(id)
                } else {
                    lock.lock()
                    let exists = accounts.values.contains { $0.id == id }
                    lock.unlock()
                    guard exists else { continue }
                    refs.append(("human", id))
                    if let dm = sidebarHumanDMChannelId(peerId: id, userId: userId, serverId: serverId) {
                        channelIds.append(dm)
                    }
                }
            }
            var seen = Set<String>()
            refs = refs.filter { seen.insert("\($0.kind)\n\($0.id)").inserted }
            var channelSeen = Set<String>()
            channelIds = channelIds.filter { channelSeen.insert($0).inserted }
            var agentSeen = Set<String>()
            agentIds = agentIds.filter { agentSeen.insert($0).inserted }
            pinnedChanged = refs.map { "\($0.kind)\n\($0.id)" } != pinnedState.refs.map { "\($0.kind)\n\($0.id)" }
            if pinnedChanged {
                pinnedState = (refs, channelIds, agentIds, pinnedState.version + 1)
            }
        } else if object["pinnedChannelIds"] != nil || object["pinnedAgentIds"] != nil || object["pinnedOrder"] != nil {
            func stringArray(_ field: String) -> [String]? {
                guard let raw = object[field] else { return [] }
                return raw as? [String]
            }
            guard let requestedChannels = stringArray("pinnedChannelIds"),
                  let requestedAgents = stringArray("pinnedAgentIds"),
                  let requestedOrder = object["pinnedOrder"] == nil ? nil : stringArray("pinnedOrder")
            else {
                return Self.json(400, "{\"error\":\"Invalid sidebar pinned references\"}")
            }
            var refs = pinnedState.refs.filter { $0.kind == "human" }
            var channelIds: [String] = []
            var agentIds: [String] = []
            let channelSource = requestedChannels.isEmpty && object["pinnedChannelIds"] == nil
                ? (requestedOrder ?? []).filter { oauth.channelInfo(id: $0) != nil }
                : requestedChannels
            for id in channelSource {
                switch sidebarPinnedChannel(id: id, serverId: serverId, userId: userId) {
                case .missing:
                    continue
                case .channel(let canonical):
                    refs.append(canonical)
                    channelIds.append(id)
                case .dm(let canonical, let legacyId):
                    refs.append(canonical)
                    channelIds.append(legacyId)
                }
            }
            let agentSource = requestedAgents.isEmpty && object["pinnedAgentIds"] == nil
                ? (requestedOrder ?? []).filter { oauth.agentRuntimeInfo(id: $0)?.serverId == serverId }
                : requestedAgents
            for id in agentSource {
                guard let agent = oauth.agentRuntimeInfo(id: id), agent.serverId == serverId else { continue }
                refs.append(("agent", id))
                agentIds.append(id)
            }
            var seen = Set<String>()
            refs = refs.filter { seen.insert("\($0.kind)\n\($0.id)").inserted }
            var channelSeen = Set<String>()
            channelIds = channelIds.filter { channelSeen.insert($0).inserted }
            var agentSeen = Set<String>()
            agentIds = agentIds.filter { agentSeen.insert($0).inserted }
            pinnedChanged = refs.map { "\($0.kind)\n\($0.id)" } != pinnedState.refs.map { "\($0.kind)\n\($0.id)" }
            if pinnedChanged {
                pinnedState = (refs, channelIds, agentIds, pinnedState.version + 1)
            }
        }
        lock.lock()
        if pinnedChanged { sidebarPinnedRefs[key] = pinnedState }
        sidebarModes[key] = (channel, joint, dm, pinned, channelTabs, agentTabs)
        if hasSectionFields { sidebarSections[key] = sections }
        lock.unlock()
        if pinnedChanged {
            let refsJSON = pinnedState.refs.map { "{\"kind\":\(jsonString($0.kind)),\"id\":\(jsonString($0.id))}" }.joined(separator: ",")
            emitRealtime("user:\(userId)", "pinned:updated", "{\"pinned\":[\(refsJSON)],\"pinnedVersion\":\(pinnedState.version)}")
        }
        return sidebarOrder(authorization: authorization, serverId: serverId)
    }

    public func sidebarOrder(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        let order = oauth.sanitizedSidebarOrder(serverId: serverId, userId: userId)
        lock.lock()
        let visibleChannelOrder = order.channelOrder.filter { postableChannels[$0]?.deletedAt == nil }
        lock.unlock()
        func array(_ values: [String]) -> String {
            values.map { jsonString($0) }.joined(separator: ",")
        }
        lock.lock()
        let modes = sidebarModes["\(serverId)\n\(userId)"] ?? ("manual", "manual", "manual", "manual", ["chat"], ["activity", "profile"])
        let sections = sidebarSections["\(serverId)\n\(userId)"] ?? ([], [], [], 0)
        let storedPinned = sidebarPinnedRefs["\(serverId)\n\(userId)"]
        lock.unlock()
        let pinnedState: (refs: [(kind: String, id: String)], channelIds: [String], agentIds: [String], version: Int)
        if let storedPinned {
            pinnedState = storedPinned
        } else {
            var refs: [(kind: String, id: String)] = []
            var channelIds: [String] = []
            var agentIds: [String] = []
            for id in order.pinnedOrder {
                if oauth.agentRuntimeInfo(id: id)?.serverId == serverId {
                    refs.append(("agent", id))
                    agentIds.append(id)
                } else if oauth.channelInfo(id: id)?.serverId == serverId {
                    refs.append(("channel", id))
                    channelIds.append(id)
                } else {
                    refs.append(("human", id))
                }
            }
            pinnedState = (refs, channelIds, agentIds, 0)
        }
        let pinnedJSON = pinnedState.refs.map {
            "{\"kind\":\(jsonString($0.kind)),\"id\":\(jsonString($0.id))}"
        }.joined(separator: ",")
        let legacyPinnedOrder = storedPinned == nil ? order.pinnedOrder : (pinnedState.channelIds + pinnedState.agentIds)
        let sectionJSON = sections.sections.map { section -> String in
            "{\"id\":\(jsonString(section.id)),\"name\":\(jsonString(section.name)),\"emoji\":\(section.emoji.map { jsonString($0) } ?? "null"),\"sortMode\":\(jsonString(section.sortMode))}"
        }.joined(separator: ",")
        let placementJSON = sections.placements.map { placement in
            "{\"kind\":\(jsonString(placement.kind)),\"id\":\(jsonString(placement.id)),\"sectionId\":\(jsonString(placement.sectionId)),\"position\":\(placement.position)}"
        }.joined(separator: ",")
        return Self.json(200, "{\"channelOrder\":[\("\(array(visibleChannelOrder))")],\"agentOrder\":[\("\(array(order.agentOrder))")],\"dmOrder\":[\("\(array(order.dmOrder))")],\"pinned\":[\(pinnedJSON)],\"pinnedChannelIds\":[\("\(array(pinnedState.channelIds))")],\"pinnedAgentIds\":[\("\(array(pinnedState.agentIds))")],\"pinnedOrder\":[\("\(array(legacyPinnedOrder))")],\"pinnedVersion\":\(pinnedState.version),\"hiddenDmIds\":[\("\(array(order.hiddenDmIds))")],\"channelSortMode\":\(jsonString(modes.channel)),\"jointChannelSortMode\":\(jsonString(modes.joint)),\"dmSortMode\":\(jsonString(modes.dm)),\"pinnedSortMode\":\(jsonString(modes.pinned)),\"channelPanelTabOrder\":[\("\(array(modes.channelTabs))")],\"agentPanelTabOrder\":[\("\(array(modes.agentTabs))")],\"customSections\":[\("\(sectionJSON)")],\"sectionOrder\":[\("\(array(sections.order.isEmpty ? ["system:pinned", "system:joint", "system:channels", "system:dms"] : sections.order))")],\"sectionPlacements\":[\("\(placementJSON)")],\"sectionsVersion\":\(sections.version)}")
    }

    public func addTaskSnapshot(
        channelId: String,
        title: String,
        status: String,
        createdAt: Date,
        updatedAt: Date,
        completedAt: Date? = nil
    ) {
        lock.lock()
        let taskNumber = taskRecords.filter { $0.channelId == channelId }.count + 1
        taskRecords.append(TaskRecord(
            id: UUID().uuidString.lowercased(),
            channelId: channelId,
            title: title,
            description: nil,
            status: status,
            taskNumber: taskNumber,
            messageId: UUID().uuidString.lowercased(),
            createdAt: createdAt,
            completedAt: completedAt,
            updatedAt: updatedAt
        ))
        lock.unlock()
    }

    public func addCompletedTask(
        channelId: String,
        title: String,
        createdAt: Date,
        completedAt: Date
    ) {
        lock.lock()
        let taskNumber = taskRecords.filter { $0.channelId == channelId }.count + 1
        taskRecords.append(TaskRecord(
            id: UUID().uuidString.lowercased(),
            channelId: channelId,
            title: title,
            description: nil,
            status: "done",
            taskNumber: taskNumber,
            messageId: UUID().uuidString.lowercased(),
            createdAt: createdAt,
            completedAt: completedAt
        ))
        lock.unlock()
    }

    public func addTask(channelId: String, title: String, description: String?) -> String {
        lock.lock()
        defer { lock.unlock() }
        let taskNumber = taskRecords.filter { $0.channelId == channelId }.count + 1
        let id = UUID().uuidString.lowercased()
        taskRecords.append(TaskRecord(
            id: id,
            channelId: channelId,
            title: title,
            description: description,
            status: "todo",
            taskNumber: taskNumber,
            messageId: UUID().uuidString.lowercased(),
            createdAt: Date()
        ))
        return id
    }

    public func addTasks(
        channelId: String, titles: [String], descriptions: [String?]? = nil,
        creatorId: String? = nil, creatorType: String = "user"
    ) -> [String] {
        // The directory lock keeps this append ordered with the readers that
        // still snapshot `taskRecords`; the store method itself is one locked
        // read-modify-write for the row array. `creatorType` is accepted for
        // callers but the row has no column for it, as before.
        lock.lock()
        defer { lock.unlock() }
        return tasksAndRemindersStore.appendTasks(
            channelId: channelId,
            titles: titles,
            descriptions: descriptions,
            creatorId: creatorId
        )
    }


    func taskChannelAccess(serverId: String, channelId: String, userId: String) -> TaskChannelAccess {
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            return .missing
        }
        if oauth.isChannelParticipant(channelId: channelId, userId: userId) {
            return .write
        }
        let type = oauth.channelType(id: channelId) ?? "channel"
        return type == "channel" ? .readOnly : .missing
    }

    /// Public view of `taskChannelAccess` for the channel-messaging service
    /// until the channel policy moves into its own store. Keeping the decision
    /// here avoids a second copy of the participant/read-only rule.
    public func channelTaskAccess(serverId: String, channelId: String, userId: String) -> ChannelTaskAccess {
        switch taskChannelAccess(serverId: serverId, channelId: channelId, userId: userId) {
        case .missing:
            .missing
        case .readOnly:
            .readOnly
        case .write:
            .write
        }
    }



    func taskJSON(_ task: TaskRecord) -> String {
        let assignee = task.assigneeId.map { jsonString($0) } ?? "null"
        let assigneeType = task.assigneeType.map { jsonString($0) } ?? "null"
        let claimed = task.claimedAt.map { jsonString(ISO8601DateFormatter().string(from: $0)) } ?? "null"
        return "{\"id\":\(jsonString(task.id)),\"channelId\":\(jsonString(task.channelId)),\"messageId\":\(jsonString(task.messageId)),\"title\":\(jsonString(task.title)),\"status\":\(jsonString(task.status)),\"taskNumber\":\(task.taskNumber),\"claimedById\":\(assignee),\"claimedByType\":\(assigneeType),\"claimedAt\":\(claimed),\"revision\":\(task.revision)\(task.requiresResourceReceipt ? ",\"requiresResourceReceipt\":true" : "")}"
    }

    func labsJSON(serverId: String, userId: String, role: String, state: ServerLabsState) -> String {
        let labs = Self.labDefinitions
            .filter { $0.state == "open" || $0.state == "paused" }
            .map { lab -> String in
                let enrolled = state.enrolled.contains(lab.key)
                let effective = state.accessEnabled && lab.state == "open" && enrolled
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let updated = state.updatedAt[lab.key].map { jsonString(formatter.string(from: $0)) } ?? "null"
                return "{\"labKey\":\(jsonString(lab.key)),\"name\":\(jsonString(lab.name)),\"description\":\(jsonString(lab.description)),\"state\":\(jsonString(lab.state)),\"enrolled\":\(enrolled),\"effective\":\(effective),\"updatedAt\":\(updated)}"
            }
            .joined(separator: ",")
        let canManageAccess = role == "owner"
        let canManageEnrollments = role == "owner" || role == "admin"
        return "{\"accessEnabled\":\(state.accessEnabled),\"version\":\(state.version),\"canManageAccess\":\(canManageAccess),\"canManageEnrollments\":\(canManageEnrollments),\"labs\":[\(labs)]}"
    }

    public func getServerLabs(authorization: String?, serverId: String, headerServerId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard headerServerId == serverId else {
            return Self.json(403, "{\"error\":\"Server scope forbidden\",\"code\":\"server_scope_forbidden\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        lock.lock()
        let state = serverLabsState[serverId] ?? ServerLabsState()
        lock.unlock()
        return Self.json(200, labsJSON(serverId: serverId, userId: userId, role: role, state: state))
    }

    public func patchServerLabsAccess(authorization: String?, serverId: String, headerServerId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard headerServerId == serverId else {
            return Self.json(403, "{\"error\":\"Server scope forbidden\",\"code\":\"server_scope_forbidden\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard role == "owner" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let enabled = object["enabled"] as? Bool,
              let expectedVersion = object["expectedVersion"] as? Int
        else {
            return Self.json(400, "{\"error\":\"Invalid labs access request\"}")
        }
        lock.lock()
        var state = serverLabsState[serverId] ?? ServerLabsState()
        if expectedVersion != state.version {
            let current = state.version
            lock.unlock()
            return Self.json(409, "{\"error\":\"Server Labs version changed\",\"code\":\"server_labs_version_conflict\",\"currentVersion\":\(current)}")
        }
        let applied = state.accessEnabled != enabled
        if applied {
            state.accessEnabled = enabled
            state.version += 1
        }
        serverLabsState[serverId] = state
        lock.unlock()
        var replyState = state
        if !applied {
            replyState.version = state.version
        }
        let json = labsJSON(serverId: serverId, userId: userId, role: role, state: replyState)
        return Self.json(200, "{\"applied\":\(applied),\"accessEnabled\":\(state.accessEnabled),\"version\":\(state.version),\"labs\":\(labsOnlyJSON(json))}")
    }

    func labsOnlyJSON(_ labs: String) -> String {
        guard let range = labs.range(of: "\"labs\":[") else { return "[]" }
        let suffix = labs[range.upperBound...]
        guard let end = suffix.lastIndex(of: "]") else { return "[]" }
        return "[" + String(suffix[..<end]) + "]"
    }

    public func putServerLabEnrollment(authorization: String?, serverId: String, headerServerId: String, labKey: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard headerServerId == serverId else {
            return Self.json(403, "{\"error\":\"Server scope forbidden\",\"code\":\"server_scope_forbidden\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard let definition = Self.labDefinitions.first(where: { $0.key == labKey }),
              definition.state == "open" || definition.state == "paused"
        else {
            return Self.json(404, "{\"error\":\"Lab not found\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let enabled = object["enabled"] as? Bool,
              let expectedVersion = object["expectedVersion"] as? Int
        else {
            return Self.json(400, "{\"error\":\"Invalid lab enrollment request\"}")
        }
        lock.lock()
        var state = serverLabsState[serverId] ?? ServerLabsState()
        if expectedVersion != state.version {
            let current = state.version
            lock.unlock()
            return Self.json(409, "{\"error\":\"Server Labs version changed\",\"code\":\"server_labs_version_conflict\",\"currentVersion\":\(current)}")
        }
        guard state.accessEnabled else {
            lock.unlock()
            return Self.json(409, "{\"error\":\"Server Labs access is disabled\",\"code\":\"server_labs_access_disabled\"}")
        }
        guard definition.state == "open" else {
            lock.unlock()
            return Self.json(409, "{\"error\":\"Lab is not open\",\"code\":\"lab_not_open\"}")
        }
        let isEnrolled = state.enrolled.contains(labKey)
        let applied = isEnrolled != enabled
        if applied {
            if enabled {
                state.enrolled.insert(labKey)
                state.updatedAt[labKey] = Date()
            } else {
                state.enrolled.remove(labKey)
            }
            state.version += 1
        }
        serverLabsState[serverId] = state
        lock.unlock()
        let json = labsJSON(serverId: serverId, userId: userId, role: role, state: state)
        return Self.json(200, "{\"applied\":\(applied),\"version\":\(state.version),\"labs\":\(labsOnlyJSON(json))}")
    }

    public func taskSnapshotMetrics(authorization: String?, serverId: String, rawQuery: String?) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        var channelFilter: String?
        for pair in (rawQuery ?? "").split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[0] == "channelId" {
                let rawChannel = parts[1].removingPercentEncoding ?? parts[1]
                guard UUID(uuidString: rawChannel) != nil,
                      let channel = oauth.channelInfo(id: rawChannel), channel.serverId == serverId
                else {
                    return Self.json(404, "{\"error\":\"Channel not found\"}")
                }
                if (oauth.channelType(id: rawChannel) ?? "channel") != "channel",
                   !oauth.isChannelParticipant(channelId: rawChannel, userId: userId) {
                    return Self.json(404, "{\"error\":\"Channel not found\"}")
                }
                channelFilter = rawChannel
            }
        }
        let visible = Set(oauth.channelsForServer(serverId: serverId, userId: userId).filter { $0.joined }.map { $0.id })
        lock.lock()
        let rows = taskRecords.filter { task in
            channelFilter.map({ $0 == task.channelId }) ?? visible.contains(task.channelId)
        }
        lock.unlock()
        let inReview = rows.filter { $0.status == "in_review" }.count
        let done = rows.filter { $0.status == "done" }.count
        let durations = rows.compactMap { task -> Double? in
            guard let completedAt = task.completedAt else { return nil }
            return completedAt.timeIntervalSince(task.createdAt) / 3600
        }.sorted()
        func percentile(_ value: Double) -> Double {
            guard !durations.isEmpty else { return 0 }
            let index = max(0, min(durations.count - 1, Int(ceil(value * Double(durations.count))) - 1))
            return durations[index]
        }
        let median = percentile(0.5)
        let p90 = percentile(0.9)
        func number(_ value: Double) -> String {
            value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let firstCreatedAt = rows.compactMap { $0.createdAt }.min()
        let latestUpdatedAt = rows.compactMap { $0.updatedAt ?? $0.completedAt ?? $0.createdAt }.max()
        let firstJSON = firstCreatedAt.map { jsonString(formatter.string(from: $0)) } ?? "null"
        let latestJSON = latestUpdatedAt.map { jsonString(formatter.string(from: $0)) } ?? "null"
        return Self.json(200, "{\"total\":\(rows.count),\"inReview\":\(inReview),\"done\":\(done),\"durationSamples\":\(durations.count),\"medianHours\":\(number(median)),\"p90Hours\":\(number(p90)),\"firstCreatedAt\":\(firstJSON),\"latestUpdatedAt\":\(latestJSON)}")
    }

    public func taskPeriodMetrics(authorization: String?, serverId: String, rawQuery: String?) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        var params: [String: String] = [:]
        for pair in (rawQuery ?? "").split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { params[parts[0]] = parts[1].removingPercentEncoding ?? parts[1] }
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallback = ISO8601DateFormatter()
        func parse(_ value: String?) -> Date? {
            guard let value else { return nil }
            return formatter.date(from: value) ?? fallback.date(from: value)
        }
        guard let from = parse(params["from"]), let midpoint = parse(params["midpoint"]), let to = parse(params["to"]) else {
            return Self.json(400, "{\"error\":\"Invalid metrics window\"}")
        }
        let week: TimeInterval = 7 * 24 * 60 * 60
        guard abs(midpoint.timeIntervalSince(from) - week) < 1,
              abs(to.timeIntervalSince(midpoint) - week) < 1
        else {
            return Self.json(400, "{\"error\":\"Invalid metrics window\"}")
        }
        var channelFilter: String?
        if let rawChannel = params["channelId"] {
            guard UUID(uuidString: rawChannel) != nil else {
                return Self.json(400, "{\"error\":\"Invalid channelId\"}")
            }
            guard let channel = oauth.channelInfo(id: rawChannel), channel.serverId == serverId else {
                return Self.json(404, "{\"error\":\"Channel not found\"}")
            }
            if (oauth.channelType(id: rawChannel) ?? "channel") != "channel",
               !oauth.isChannelParticipant(channelId: rawChannel, userId: userId) {
                return Self.json(404, "{\"error\":\"Channel not found\"}")
            }
            channelFilter = rawChannel
        }
        let visible = Set(oauth.channelsForServer(serverId: serverId, userId: userId).filter { $0.joined }.map { $0.id })
        lock.lock()
        let rows = taskRecords.filter { task in
            guard let completedAt = task.completedAt else { return false }
            guard channelFilter.map({ $0 == task.channelId }) ?? visible.contains(task.channelId) else { return false }
            return completedAt >= from && completedAt < to
        }
        lock.unlock()
        func metrics(_ start: Date, _ end: Date) -> String {
            let window = rows.filter { task in
                guard let completedAt = task.completedAt else { return false }
                return completedAt >= start && completedAt < end
            }
            let durations = window.compactMap { task -> Double? in
                guard let completedAt = task.completedAt else { return nil }
                return completedAt.timeIntervalSince(task.createdAt) / 3600
            }.sorted()
            let mean = durations.isEmpty ? 0 : durations.reduce(0, +) / Double(durations.count)
            let median: Double
            if durations.isEmpty {
                median = 0
            } else if durations.count % 2 == 1 {
                median = durations[durations.count / 2]
            } else {
                median = (durations[durations.count / 2 - 1] + durations[durations.count / 2]) / 2
            }
            func number(_ value: Double) -> String {
                value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
            }
            return "{\"completed\":\(window.count),\"durationSamples\":\(durations.count),\"meanHours\":\(number(mean)),\"medianHours\":\(number(median))}"
        }
        return Self.json(200, "{\"current\":\(metrics(midpoint, to)),\"previous\":\(metrics(from, midpoint))}")
    }

}

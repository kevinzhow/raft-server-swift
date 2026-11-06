import Foundation

extension ServersAndChannelsStore {
    func appendServerMemberEvent(
        serverId: String,
        eventType: String,
        subjectType: String,
        subjectId: String,
        provenanceJSON: String
    ) {
        lock.lock()
        defer { lock.unlock() }
        storage.serverMemberEvents.append(ServerMemberEvent(
            serverId: serverId,
            eventType: eventType,
            subjectType: subjectType,
            subjectId: subjectId,
            provenanceJSON: provenanceJSON,
            deliveryQueued: true
        ))
    }

    /// The member-leaves write: status row, removed-member marker and the
    /// queued member event are one critical section.
    func markMemberLeft(serverId: String, userId: String, provenanceJSON: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.serverMemberStatuses["\(serverId)\n\(userId)"] = "left"
        storage.removedServerMembers.insert("\(serverId)\n\(userId)")
        storage.serverMemberEvents.append(ServerMemberEvent(
            serverId: serverId,
            eventType: "server.member_removed",
            subjectType: "member",
            subjectId: userId,
            provenanceJSON: provenanceJSON,
            deliveryQueued: true
        ))
    }

    /// Server role used by the hidden human directory. Only `member` is hidden
    /// on #all.
    func setServerMemberRole(serverId: String, userId: String, role: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.serverMemberRoles["\(serverId)\n\(userId)"] = role
    }

    func setHideHumansFromMembers(serverId: String, hidden: Bool) {
        lock.lock()
        defer { lock.unlock() }
        storage.hideHumansFromMembers[serverId] = hidden
    }

    // MARK: - Server member removal

    /// The member-removal write: status row, removed-member marker and the
    /// queued event are one critical section, matching the one directory lock
    /// the retired handler held across them.
    func markMemberRemoved(serverId: String, userId: String, provenanceJSON: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.serverMemberStatuses["\(serverId)\n\(userId)"] = "removed"
        storage.removedServerMembers.insert("\(serverId)\n\(userId)")
        storage.serverMemberEvents.append(ServerMemberEvent(
            serverId: serverId,
            eventType: "server.member_removed",
            subjectType: "member",
            subjectId: userId,
            provenanceJSON: provenanceJSON,
            deliveryQueued: true
        ))
    }

    /// Queues the member-removed events for a whole server deletion in one
    /// critical section.
    func appendServerMemberEvents(_ events: [ServerMemberEvent]) {
        guard !events.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        storage.serverMemberEvents.append(contentsOf: events)
    }

    /// Whether the member was removed from the server (and not re-added).
    func isMemberRemoved(serverId: String, userId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage.removedServerMembers.contains("\(serverId)\n\(userId)")
    }
}

import Crypto
import Foundation
import RaftShared

extension OAuthLedger {
    public struct ChannelListInfo: Sendable {
        public var id: String
        public var name: String
        public var type: String
        public var joined: Bool
        public var lastMessageAt: Date?
        public var activityMuted: Bool
        public var muteFromSeq: Int?
        public var prefsVersion: Int
    }

    public struct ChannelNotificationPrefs: Sendable {
        public var activityMuted: Bool = false
        public var muteFromSeq: Int? = nil
        public var prefsVersion: Int = 0
    }

    public func createChannel(serverId: String, name: String, creatorUserId: String, type: String = "channel", description: String? = nil) -> String {
        let id = UUID().uuidString.lowercased()
        lock.lock()
        channelRecords.append(ChannelRecord(id: id, serverId: serverId, name: name, type: type, description: description))
        if type == "channel" {
            channelHumans.insert("\(id)\n\(creatorUserId)")
        }
        lock.unlock()
        return id
    }

    public func addChannelAgent(channelId: String, agentId: String) {
        lock.lock()
        channelAgents.insert("\(channelId)\n\(agentId)")
        lock.unlock()
    }

    public func removeChannelAgent(channelId: String, agentId: String) {
        lock.lock()
        channelAgents.remove("\(channelId)\n\(agentId)")
        lock.unlock()
    }

    public func channelAgentIds(channelId: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return channelAgents
            .filter { $0.hasPrefix("\(channelId)\n") }
            .compactMap { $0.split(separator: "\n", maxSplits: 1).last.map(String.init) }
            .sorted()
    }

    public func channelServerId(channelId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return channelRecords.first(where: { $0.id == channelId })?.serverId
    }

    public func channelKind(channelId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return channelRecords.first(where: { $0.id == channelId })?.type
    }

    public func channelHumanIds(channelId: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return channelHumans
            .filter { $0.hasPrefix("\(channelId)\n") }
            .compactMap { $0.split(separator: "\n", maxSplits: 1).last.map(String.init) }
            .sorted()
    }

    public func addChannelHuman(channelId: String, userId: String) {
        lock.lock()
        channelHumans.insert("\(channelId)\n\(userId)")
        lock.unlock()
    }
    public func createDirectChannel(serverId: String, firstUserId: String, secondUserId: String) -> String {
        lock.lock()
        if firstUserId != secondUserId, let existing = channelRecords.first(where: {
            $0.serverId == serverId && $0.type == "dm"
                && channelHumans.contains("\($0.id)\n\(firstUserId)")
                && channelHumans.contains("\($0.id)\n\(secondUserId)")
        }) {
            lock.unlock()
            return existing.id
        }
        let id = UUID().uuidString.lowercased()
        channelRecords.append(ChannelRecord(id: id, serverId: serverId, name: "", type: "dm"))
        channelHumans.insert("\(id)\n\(firstUserId)")
        channelHumans.insert("\(id)\n\(secondUserId)")
        lock.unlock()
        return id
    }

    public func channelReadCursor(channelId: String, userId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return channelReadCursors["\(channelId)\n\(userId)"] ?? 0
    }

    public func setChannelReadCursor(channelId: String, userId: String, seq: Int) {
        lock.lock()
        channelReadCursors["\(channelId)\n\(userId)"] = seq
        lock.unlock()
    }

    public struct ChannelUnreadInfo: Sendable {
        public var unreadCount: Int
        public var maxReadSeq: Int
        public var latestMessageId: String?
        public var latestSeq: Int?
    }

    public func firstUnreadMessageId(channelId: String, userId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let cursor = channelReadCursors["\(channelId)\n\(userId)"] ?? 0
        return channelMessages
            .filter { $0.channelId == channelId && $0.senderId != userId && $0.seq > cursor }
            .min { $0.seq < $1.seq }?.id
    }

    public func latestPeerMessageSeq(channelId: String, excluding userId: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return channelMessages
            .filter { $0.channelId == channelId && $0.senderId != userId }
            .map(\.seq)
            .max()
    }

    public func channelUnreadInfo(channelId: String, userId: String) -> ChannelUnreadInfo {
        lock.lock()
        defer { lock.unlock() }
        let cursor = channelReadCursors["\(channelId)\n\(userId)"] ?? 0
        let messages = channelMessages.filter { $0.channelId == channelId }
        let unread = messages.filter { $0.senderId != userId && $0.seq > cursor }.count
        let latest = messages.max { $0.seq < $1.seq }
        return ChannelUnreadInfo(
            unreadCount: unread,
            maxReadSeq: cursor,
            latestMessageId: latest?.id,
            latestSeq: latest?.seq
        )
    }

    public struct ChannelDisplayPrefs: Sendable {
        public var collapseLongMessages: Bool = true
        public var prefsVersion: Int = 0
    }

    @discardableResult
    public func renameChannel(id: String, name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let index = channelRecords.firstIndex(where: { $0.id == id }) else { return false }
        channelRecords[index].name = name
        return true
    }


    public func setChannelType(id: String, type: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let index = channelRecords.firstIndex(where: { $0.id == id }) else { return false }
        channelRecords[index].type = type
        return true
    }
    public func allChannelId(serverId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return channelRecords.first(where: { $0.serverId == serverId && $0.name == "all" })?.id
    }

    /// `all` is implicit for every Server human; other channels require membership.
    public func canAccessChannelPrefs(channelId: String, userId: String, serverId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let channel = channelRecords.first(where: { $0.id == channelId }), channel.serverId == serverId else {
            return false
        }
        if channel.name == "all" { return true }
        return channelHumans.contains("\(channelId)\n\(userId)")
    }

    public func channelDisplayPrefs(channelId: String, userId: String) -> ChannelDisplayPrefs {
        lock.lock()
        defer { lock.unlock() }
        return channelDisplayPrefs["\(channelId)\n\(userId)"] ?? ChannelDisplayPrefs()
    }

    public func setCollapseLongMessages(channelId: String, userId: String, collapse: Bool) -> ChannelDisplayPrefs {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(channelId)\n\(userId)"
        var prefs = channelDisplayPrefs[key] ?? ChannelDisplayPrefs()
        if prefs.collapseLongMessages != collapse {
            prefs.collapseLongMessages = collapse
            prefs.prefsVersion += 1
            channelDisplayPrefs[key] = prefs
        }
        return prefs
    }

    public func channelServerId(_ channelId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return channelRecords.first(where: { $0.id == channelId })?.serverId
    }

    public func removeChannelHuman(channelId: String, userId: String) {
        lock.lock()
        channelHumans.remove("\(channelId)\n\(userId)")
        lock.unlock()
    }

    public func isChannelParticipant(channelId: String, userId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return channelHumans.contains("\(channelId)\n\(userId)")
    }

    public func setChannelArchived(id: String, archivedAt: Date?) {
        lock.lock()
        if let index = channelRecords.firstIndex(where: { $0.id == id }) {
            channelRecords[index].archived = archivedAt != nil
            channelRecords[index].archivedAt = archivedAt
            if let parent = channelRecords[index].parentChannelId,
               let parentIndex = channelRecords.firstIndex(where: { $0.id == parent }),
               archivedAt != nil {
                channelRecords[parentIndex].archived = true
            }
        }
        lock.unlock()
    }

    public func channelArchivedAt(id: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return channelRecords.first(where: { $0.id == id })?.archivedAt
    }

    /// Parent channel of a thread; nil for any other channel kind.
    public func channelParentChannelId(id: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return channelRecords.first { $0.id == id }?.parentChannelId
    }

    public func channelInfo(id: String) -> (serverId: String, name: String, description: String?)? {
        lock.lock()
        defer { lock.unlock() }
        guard let channel = channelRecords.first(where: { $0.id == id }) else { return nil }
        return (channel.serverId, channel.name, channel.description)
    }

    @discardableResult
    public func updateChannel(id: String, name: String?, description: String?, systemMessage: String?) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = channelRecords.firstIndex(where: { $0.id == id }) else { return nil }
        if let name { channelRecords[index].name = name }
        if let description { channelRecords[index].description = description }
        guard let systemMessage else { return nil }
        let seq = channelMessages.filter { $0.channelId == id }.count + channelSystemMessages.filter { $0.channelId == id }.count + 1
        channelSystemMessages.append(ChannelSystemMessageRecord(
            channelId: id,
            content: systemMessage,
            seq: seq,
            createdAt: Date()
        ))
        return seq
    }

    public func systemMessages(channelId: String) -> [(id: String, content: String, seq: Int)] {
        lock.lock()
        defer { lock.unlock() }
        return channelSystemMessages
            .filter { $0.channelId == channelId }
            .map { (UUID().uuidString.lowercased(), $0.content, $0.seq) }
    }

    struct ChannelSystemMessageRecord: Sendable {
        var channelId: String
        var content: String
        var seq: Int
        var createdAt: Date
    }

    public func channelType(id: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return channelRecords.first(where: { $0.id == id })?.type
    }

    public func latestChannelSeq(channelId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let messages = channelMessages.filter { $0.channelId == channelId }.count
        let systems = channelSystemMessages.filter { $0.channelId == channelId }.count
        return messages + systems
    }

    public func notificationPrefs(channelId: String, userId: String) -> ChannelNotificationPrefs {
        lock.lock()
        defer { lock.unlock() }
        return channelNotificationPrefs["\(channelId)\n\(userId)"] ?? ChannelNotificationPrefs()
    }

    /// Receiver-keyed activity mute with an explicit subscribe boundary. Agents
    /// and humans share this per-receiver prefs store.
    public func setActivityMuted(
        channelId: String,
        receiverId: String,
        muted: Bool,
        muteFromSeq: Int?
    ) -> (prefs: ChannelNotificationPrefs, changed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(channelId)\n\(receiverId)"
        var prefs = channelNotificationPrefs[key] ?? ChannelNotificationPrefs()
        if prefs.activityMuted == muted && prefs.muteFromSeq == muteFromSeq {
            return (prefs, false)
        }
        prefs.activityMuted = muted
        prefs.muteFromSeq = muted ? muteFromSeq : nil
        prefs.prefsVersion += 1
        channelNotificationPrefs[key] = prefs
        return (prefs, true)
    }

    public func setActivityMuted(channelId: String, userId: String, muted: Bool) -> (prefs: ChannelNotificationPrefs, changed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(channelId)\n\(userId)"
        var prefs = channelNotificationPrefs[key] ?? ChannelNotificationPrefs()
        if prefs.activityMuted == muted {
            return (prefs, false)
        }
        prefs.activityMuted = muted
        prefs.muteFromSeq = muted ? latestChannelSeqLocked(channelId: channelId) + 1 : nil
        prefs.prefsVersion += 1
        channelNotificationPrefs[key] = prefs
        return (prefs, true)
    }

    func latestChannelSeqLocked(channelId: String) -> Int {
        channelMessages.filter { $0.channelId == channelId }.count
            + channelSystemMessages.filter { $0.channelId == channelId }.count
    }

    public func channelsForServer(serverId: String, userId: String, includeArchived: Bool = false) -> [ChannelListInfo] {
        lock.lock()
        defer { lock.unlock() }
        return channelRecords
            .filter { $0.serverId == serverId && (includeArchived || !$0.archived) }
            .filter { channel in
                if channel.type == "private" || channel.type == "dm" {
                    return channelHumans.contains("\(channel.id)\n\(userId)")
                }
                return true
            }
            .map { channel in
                let last = channelMessages
                    .filter { $0.channelId == channel.id }
                    .map { $0.createdAt }
                    .max()
                let prefs = channelNotificationPrefs["\(channel.id)\n\(userId)"] ?? ChannelNotificationPrefs()
                return ChannelListInfo(
                    id: channel.id,
                    name: channel.name,
                    type: channel.type,
                    joined: channelHumans.contains("\(channel.id)\n\(userId)"),
                    lastMessageAt: last,
                    activityMuted: prefs.activityMuted,
                    muteFromSeq: prefs.muteFromSeq,
                    prefsVersion: prefs.prefsVersion
                )
            }
    }
}

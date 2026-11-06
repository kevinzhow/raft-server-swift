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
        self.state.withLock { ledgerState in
            ledgerState.channelRecords.append(ChannelRecord(id: id, serverId: serverId, name: name, type: type, description: description))
            if type == "channel" {
                ledgerState.channelHumans.insert("\(id)\n\(creatorUserId)")
            }
        }
        return id
    }

    public func addChannelAgent(channelId: String, agentId: String) {
        _ = self.state.withLock { ledgerState in
            ledgerState.channelAgents.insert("\(channelId)\n\(agentId)")
        }
    }

    public func removeChannelAgent(channelId: String, agentId: String) {
        _ = self.state.withLock { ledgerState in
            ledgerState.channelAgents.remove("\(channelId)\n\(agentId)")
        }
    }

    public func channelAgentIds(channelId: String) -> [String] {
        return self.state.withLock { ledgerState in
            return ledgerState.channelAgents
                .filter { $0.hasPrefix("\(channelId)\n") }
                .compactMap { $0.split(separator: "\n", maxSplits: 1).last.map(String.init) }
                .sorted()
        }
    }

    public func channelServerId(channelId: String) -> String? {
        return self.state.withLock { ledgerState in
            return ledgerState.channelRecords.first(where: { $0.id == channelId })?.serverId
        }
    }

    public func channelKind(channelId: String) -> String? {
        return self.state.withLock { ledgerState in
            return ledgerState.channelRecords.first(where: { $0.id == channelId })?.type
        }
    }

    public func channelHumanIds(channelId: String) -> [String] {
        return self.state.withLock { ledgerState in
            return ledgerState.channelHumans
                .filter { $0.hasPrefix("\(channelId)\n") }
                .compactMap { $0.split(separator: "\n", maxSplits: 1).last.map(String.init) }
                .sorted()
        }
    }

    public func addChannelHuman(channelId: String, userId: String) {
        _ = self.state.withLock { ledgerState in
            ledgerState.channelHumans.insert("\(channelId)\n\(userId)")
        }
    }
    public func createDirectChannel(serverId: String, firstUserId: String, secondUserId: String) -> String {
        return self.state.withLock { ledgerState in
            if firstUserId != secondUserId, let existing = ledgerState.channelRecords.first(where: {
                $0.serverId == serverId && $0.type == "dm"
                    && ledgerState.channelHumans.contains("\($0.id)\n\(firstUserId)")
                    && ledgerState.channelHumans.contains("\($0.id)\n\(secondUserId)")
            }) {
                return existing.id
            }
            let id = UUID().uuidString.lowercased()
            ledgerState.channelRecords.append(ChannelRecord(id: id, serverId: serverId, name: "", type: "dm"))
            ledgerState.channelHumans.insert("\(id)\n\(firstUserId)")
            ledgerState.channelHumans.insert("\(id)\n\(secondUserId)")
            return id
        }
    }

    public func channelReadCursor(channelId: String, userId: String) -> Int {
        return self.state.withLock { ledgerState in
            return ledgerState.channelReadCursors["\(channelId)\n\(userId)"] ?? 0
        }
    }

    public func setChannelReadCursor(channelId: String, userId: String, seq: Int) {
        self.state.withLock { ledgerState in
            ledgerState.channelReadCursors["\(channelId)\n\(userId)"] = seq
        }
    }

    public struct ChannelUnreadInfo: Sendable {
        public var unreadCount: Int
        public var maxReadSeq: Int
        public var latestMessageId: String?
        public var latestSeq: Int?
    }

    public func firstUnreadMessageId(channelId: String, userId: String) -> String? {
        return self.state.withLock { ledgerState in
            let cursor = ledgerState.channelReadCursors["\(channelId)\n\(userId)"] ?? 0
            return ledgerState.channelMessages
                .filter { $0.channelId == channelId && $0.senderId != userId && $0.seq > cursor }
                .min { $0.seq < $1.seq }?.id
        }
    }

    public func latestPeerMessageSeq(channelId: String, excluding userId: String) -> Int? {
        return self.state.withLock { ledgerState in
            return ledgerState.channelMessages
                .filter { $0.channelId == channelId && $0.senderId != userId }
                .map(\.seq)
                .max()
        }
    }

    public func channelUnreadInfo(channelId: String, userId: String) -> ChannelUnreadInfo {
        return self.state.withLock { ledgerState in
            let cursor = ledgerState.channelReadCursors["\(channelId)\n\(userId)"] ?? 0
            let messages = ledgerState.channelMessages.filter { $0.channelId == channelId }
            let unread = messages.filter { $0.senderId != userId && $0.seq > cursor }.count
            let latest = messages.max { $0.seq < $1.seq }
            return ChannelUnreadInfo(
                unreadCount: unread,
                maxReadSeq: cursor,
                latestMessageId: latest?.id,
                latestSeq: latest?.seq
            )
        }
    }

    public struct ChannelDisplayPrefs: Sendable {
        public var collapseLongMessages: Bool = true
        public var prefsVersion: Int = 0
    }

    @discardableResult
    public func renameChannel(id: String, name: String) -> Bool {
        return self.state.withLock { ledgerState in
            guard let index = ledgerState.channelRecords.firstIndex(where: { $0.id == id }) else { return false }
            ledgerState.channelRecords[index].name = name
            return true
        }
    }


    public func setChannelType(id: String, type: String) -> Bool {
        return self.state.withLock { ledgerState in
            guard let index = ledgerState.channelRecords.firstIndex(where: { $0.id == id }) else { return false }
            ledgerState.channelRecords[index].type = type
            return true
        }
    }
    public func allChannelId(serverId: String) -> String? {
        return self.state.withLock { ledgerState in
            return ledgerState.channelRecords.first(where: { $0.serverId == serverId && $0.name == "all" })?.id
        }
    }

    /// `all` is implicit for every Server human; other channels require membership.
    public func canAccessChannelPrefs(channelId: String, userId: String, serverId: String) -> Bool {
        return self.state.withLock { ledgerState in
            guard let channel = ledgerState.channelRecords.first(where: { $0.id == channelId }), channel.serverId == serverId else {
                return false
            }
            if channel.name == "all" { return true }
            return ledgerState.channelHumans.contains("\(channelId)\n\(userId)")
        }
    }

    public func channelDisplayPrefs(channelId: String, userId: String) -> ChannelDisplayPrefs {
        return self.state.withLock { ledgerState in
            return ledgerState.channelDisplayPrefs["\(channelId)\n\(userId)"] ?? ChannelDisplayPrefs()
        }
    }

    public func setCollapseLongMessages(channelId: String, userId: String, collapse: Bool) -> ChannelDisplayPrefs {
        return self.state.withLock { ledgerState in
            let key = "\(channelId)\n\(userId)"
            var prefs = ledgerState.channelDisplayPrefs[key] ?? ChannelDisplayPrefs()
            if prefs.collapseLongMessages != collapse {
                prefs.collapseLongMessages = collapse
                prefs.prefsVersion += 1
                ledgerState.channelDisplayPrefs[key] = prefs
            }
            return prefs
        }
    }

    public func channelServerId(_ channelId: String) -> String? {
        return self.state.withLock { ledgerState in
            return ledgerState.channelRecords.first(where: { $0.id == channelId })?.serverId
        }
    }

    public func removeChannelHuman(channelId: String, userId: String) {
        _ = self.state.withLock { ledgerState in
            ledgerState.channelHumans.remove("\(channelId)\n\(userId)")
        }
    }

    public func isChannelParticipant(channelId: String, userId: String) -> Bool {
        return self.state.withLock { ledgerState in
            return ledgerState.channelHumans.contains("\(channelId)\n\(userId)")
        }
    }

    public func setChannelArchived(id: String, archivedAt: Date?) {
        self.state.withLock { ledgerState in
            if let index = ledgerState.channelRecords.firstIndex(where: { $0.id == id }) {
                ledgerState.channelRecords[index].archived = archivedAt != nil
                ledgerState.channelRecords[index].archivedAt = archivedAt
                if let parent = ledgerState.channelRecords[index].parentChannelId,
                   let parentIndex = ledgerState.channelRecords.firstIndex(where: { $0.id == parent }),
                   archivedAt != nil {
                    ledgerState.channelRecords[parentIndex].archived = true
                }
            }
        }
    }

    public func channelArchivedAt(id: String) -> Date? {
        return self.state.withLock { ledgerState in
            return ledgerState.channelRecords.first(where: { $0.id == id })?.archivedAt
        }
    }

    /// Parent channel of a thread; nil for any other channel kind.
    public func channelParentChannelId(id: String) -> String? {
        return self.state.withLock { ledgerState in
            return ledgerState.channelRecords.first { $0.id == id }?.parentChannelId
        }
    }

    public func channelInfo(id: String) -> (serverId: String, name: String, description: String?)? {
        return self.state.withLock { ledgerState in
            guard let channel = ledgerState.channelRecords.first(where: { $0.id == id }) else { return nil }
            return (channel.serverId, channel.name, channel.description)
        }
    }

    @discardableResult
    public func updateChannel(id: String, name: String?, description: String?, systemMessage: String?) -> Int? {
        return self.state.withLock { ledgerState in
            guard let index = ledgerState.channelRecords.firstIndex(where: { $0.id == id }) else { return nil }
            if let name { ledgerState.channelRecords[index].name = name }
            if let description { ledgerState.channelRecords[index].description = description }
            guard let systemMessage else { return nil }
            let seq = ledgerState.channelMessages.filter { $0.channelId == id }.count + ledgerState.channelSystemMessages.filter { $0.channelId == id }.count + 1
            ledgerState.channelSystemMessages.append(ChannelSystemMessageRecord(
                channelId: id,
                content: systemMessage,
                seq: seq,
                createdAt: Date()
            ))
            return seq
        }
    }

    public func systemMessages(channelId: String) -> [(id: String, content: String, seq: Int)] {
        return self.state.withLock { ledgerState in
            return ledgerState.channelSystemMessages
                .filter { $0.channelId == channelId }
                .map { (UUID().uuidString.lowercased(), $0.content, $0.seq) }
        }
    }

    struct ChannelSystemMessageRecord: Sendable {
        var channelId: String
        var content: String
        var seq: Int
        var createdAt: Date
    }

    public func channelType(id: String) -> String? {
        return self.state.withLock { ledgerState in
            return ledgerState.channelRecords.first(where: { $0.id == id })?.type
        }
    }

    public func latestChannelSeq(channelId: String) -> Int {
        return self.state.withLock { ledgerState in
            let messages = ledgerState.channelMessages.filter { $0.channelId == channelId }.count
            let systems = ledgerState.channelSystemMessages.filter { $0.channelId == channelId }.count
            return messages + systems
        }
    }

    public func notificationPrefs(channelId: String, userId: String) -> ChannelNotificationPrefs {
        return self.state.withLock { ledgerState in
            return ledgerState.channelNotificationPrefs["\(channelId)\n\(userId)"] ?? ChannelNotificationPrefs()
        }
    }

    /// Receiver-keyed activity mute with an explicit subscribe boundary. Agents
    /// and humans share this per-receiver prefs store.
    public func setActivityMuted(
        channelId: String,
        receiverId: String,
        muted: Bool,
        muteFromSeq: Int?
    ) -> (prefs: ChannelNotificationPrefs, changed: Bool) {
        return self.state.withLock { ledgerState in
            let key = "\(channelId)\n\(receiverId)"
            var prefs = ledgerState.channelNotificationPrefs[key] ?? ChannelNotificationPrefs()
            if prefs.activityMuted == muted && prefs.muteFromSeq == muteFromSeq {
                return (prefs, false)
            }
            prefs.activityMuted = muted
            prefs.muteFromSeq = muted ? muteFromSeq : nil
            prefs.prefsVersion += 1
            ledgerState.channelNotificationPrefs[key] = prefs
            return (prefs, true)
        }
    }

    public func setActivityMuted(channelId: String, userId: String, muted: Bool) -> (prefs: ChannelNotificationPrefs, changed: Bool) {
        return self.state.withLock { ledgerState in
            let key = "\(channelId)\n\(userId)"
            var prefs = ledgerState.channelNotificationPrefs[key] ?? ChannelNotificationPrefs()
            if prefs.activityMuted == muted {
                return (prefs, false)
            }
            prefs.activityMuted = muted
            prefs.muteFromSeq = muted ? latestChannelSeqLocked(channelId: channelId, state: ledgerState) + 1 : nil
            prefs.prefsVersion += 1
            ledgerState.channelNotificationPrefs[key] = prefs
            return (prefs, true)
        }
    }

    func latestChannelSeqLocked(channelId: String, state ledgerState: State) -> Int {
        ledgerState.channelMessages.filter { $0.channelId == channelId }.count
            + ledgerState.channelSystemMessages.filter { $0.channelId == channelId }.count
    }

    public func channelsForServer(serverId: String, userId: String, includeArchived: Bool = false) -> [ChannelListInfo] {
        return self.state.withLock { ledgerState in
            return ledgerState.channelRecords
                .filter { $0.serverId == serverId && (includeArchived || !$0.archived) }
                .filter { channel in
                    if channel.type == "private" || channel.type == "dm" {
                        return ledgerState.channelHumans.contains("\(channel.id)\n\(userId)")
                    }
                    return true
                }
                .map { channel in
                    let last = ledgerState.channelMessages
                        .filter { $0.channelId == channel.id }
                        .map { $0.createdAt }
                        .max()
                    let prefs = ledgerState.channelNotificationPrefs["\(channel.id)\n\(userId)"] ?? ChannelNotificationPrefs()
                    return ChannelListInfo(
                        id: channel.id,
                        name: channel.name,
                        type: channel.type,
                        joined: ledgerState.channelHumans.contains("\(channel.id)\n\(userId)"),
                        lastMessageAt: last,
                        activityMuted: prefs.activityMuted,
                        muteFromSeq: prefs.muteFromSeq,
                        prefsVersion: prefs.prefsVersion
                    )
                }
        }
    }
}

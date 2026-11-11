import Foundation

// MARK: - Injected dependencies

/// Every cross-domain decision the announcements/unread/agent-user surface
/// needs.
///
/// The session lookup, the agent credential resolution and the human-message
/// append belong to unmigrated domains and stay behind closures; the stores and
/// the OAuth ledger are held directly. `DirectoryServiceAccessors.swift` wires
/// the closures to the existing directory entry points.
struct ManagedMCPOAuthDependencies: Sendable {
    var sessionUserId: @Sendable (String?) -> String?
    /// The agent behind a bearer credential that holds `capability`.
    var agentIdentity: @Sendable (_ authorization: String?, _ capability: String) -> (agentId: String, serverId: String)?
    /// The scopes of the credential behind the bearer token.
    var agentScopes: @Sendable (String?) -> [String]?
    /// Guests may only see channels they joined; the rule lives with the
    /// channel-agent routes.
    var guestDeniedHiddenChannel: @Sendable (_ channelId: String, _ serverId: String, _ userId: String) -> Bool
    /// Appends one human-message row (sequence stamping and the ledger mirror
    /// belong to the message domain).
    var appendMessage: @Sendable (StoredHumanMessage) -> Void
    var oauth: OAuthLedger
    var notifications: NotificationsStore
    var messages: MessagesAndThreadsStore
    var channels: ServersAndChannelsStore
    var feedback: FeedbackStore
    var profiles: AuthProfileStore
    var now: @Sendable () -> Date
}

extension ManagedMCPOAuthDependencies {
    init(
        auth: AuthCoreService,
        locator: FeedbackLocatorService,
        visibility: ManagedMCPChannelVisibility,
        oauth: OAuthLedger,
        notifications: NotificationsStore,
        messages: MessagesAndThreadsStore,
        channels: ServersAndChannelsStore,
        feedback: FeedbackStore,
        profiles: AuthProfileStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let ledger = MessageLedgerPort(oauth: oauth)
        self.init(
            sessionUserId: { try? auth.authenticate($0) },
            agentIdentity: locator.optionalAgentIdentity,
            agentScopes: locator.credentialScopes,
            guestDeniedHiddenChannel: visibility.guestDeniedHiddenChannel,
            appendMessage: { messages.appendMessage($0, ledger: ledger, mirrorSystemMetadata: true) },
            oauth: oauth,
            notifications: notifications,
            messages: messages,
            channels: channels,
            feedback: feedback,
            profiles: profiles,
            now: now
        )
    }
}

// MARK: - Service

/// Announcements, external avatars, channel unread, notification settings, the
/// agent user lookups and the app-installation reminder write.
///
/// The service owns the orchestration and returns published
/// `JSONBodyConvertible` DTOs; every refusal is a `ManagedMCPOAuthError`. It
/// builds no HTTP reply, header set or body text.
public struct ManagedMCPOAuthService: Sendable {
    private let dependencies: ManagedMCPOAuthDependencies

    init(dependencies: ManagedMCPOAuthDependencies) {
        self.dependencies = dependencies
    }

    private var oauth: OAuthLedger { dependencies.oauth }

    /// Human read authority for this service's channel-scoped writes. A thread
    /// resolves through its parent message's channel, like
    /// `canUserAccessChannel` (`channelService.ts:4994-5016`).
    private func canReadChannel(channelId: String, serverId: String, userId: String) -> Bool {
        var visited: Set<String> = []
        func visit(_ id: String) -> Bool {
            guard visited.count < 64, visited.insert(id).inserted,
                  let channel = dependencies.channels.postableChannels[id],
                  channel.serverId == serverId, channel.deletedAt == nil
            else { return false }
            switch channel.kind {
            case "channel":
                return true
            case "thread":
                if let parentId = channel.parentChannelId, visit(parentId) { return true }
                guard let parentMessageId = channel.parentMessageId,
                      let parentChannelId = dependencies.messages.humanMessageRows
                          .first(where: { $0.id == parentMessageId })?.channelId
                else { return false }
                return visit(parentChannelId)
            default:
                return channel.memberIds.contains(userId)
                    || oauth.channelType(id: id) == "channel"
                    || oauth.isChannelParticipant(channelId: id, userId: userId)
            }
        }
        if visit(channelId) { return true }
        guard dependencies.channels.postableChannel(id: channelId) == nil else { return false }
        return LedgerChannelReadFallback.canReadHuman(
            channelId: channelId, serverId: serverId, userId: userId, oauth: oauth)
    }

    private func requireUser(_ authorization: String?) throws -> String {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw ManagedMCPOAuthError.unauthorized
        }
        return userId
    }

    // MARK: - GET /api/external-avatars/:file

    public func externalAvatar(file: String) throws -> ManagedMCPAssetResponse {
        guard file.hasSuffix(".webp") else { throw ManagedMCPOAuthError.avatarNotFound }
        let id = String(file.dropLast(".webp".count))
        guard ServerScope.isUUID(id) else { throw ManagedMCPOAuthError.avatarNotFound }
        let snapshot = dependencies.messages.externalAvatarSnapshot(id: id)
        guard let asset = snapshot.asset, asset.active else { throw ManagedMCPOAuthError.avatarNotFound }
        guard snapshot.storageAvailable else { throw ManagedMCPOAuthError.avatarStorageUnavailable }
        return ManagedMCPAssetResponse(
            headers: .exact([
                "Content-Type": asset.contentType,
                "Content-Disposition": "inline",
                "Cache-Control": "public, no-cache, must-revalidate",
                "ETag": "\"sha256-\(asset.sourceDigest)\"",
                "X-Content-Type-Options": "nosniff",
                "Cross-Origin-Resource-Policy": "cross-origin",
            ]),
            text: String(decoding: asset.bytes, as: UTF8.self)
        )
    }

    // MARK: - GET /api/announcements/images/:id

    public func announcementImage(id: String) throws -> ManagedMCPAssetResponse {
        guard ServerScope.isUUID(id) else { throw ManagedMCPOAuthError.announcementImageNotFound }
        let snapshot = dependencies.notifications.announcementImageSnapshot(imageId: id)
        guard let asset = snapshot.asset, let announcement = snapshot.announcement,
              announcement.publishedAt != nil,
              announcement.status != "draft",
              announcement.startsAt <= dependencies.now()
        else { throw ManagedMCPOAuthError.announcementImageNotFound }
        guard snapshot.storageAvailable else { throw ManagedMCPOAuthError.announcementImageStorageUnavailable }
        return ManagedMCPAssetResponse(
            headers: .exact([
                "Content-Type": asset.contentType,
                "Cache-Control": "public, max-age=31536000, immutable",
                "Cross-Origin-Resource-Policy": "cross-origin",
            ]),
            text: String(decoding: asset.bytes, as: UTF8.self)
        )
    }

    // MARK: - GET /api/announcements/active

    public func activeAnnouncements(
        authorization: String?,
        after: String?,
        query: String?
    ) throws -> ActiveAnnouncementsResponse {
        let userId = try requireUser(authorization)
        if let after, !after.isEmpty, !ServerScope.isUUID(after) {
            throw ManagedMCPOAuthError.invalidAnnouncementCursor
        }
        let scopedServer = try Self.announcementScope(query: query, headerServerId: nil)
        // Drafts never surface; a published row only surfaces once published
        // and until it expires. Expiring the newest row falls through to the
        // next unread one, which is what makes scheduled windows queue.
        let row = dependencies.notifications.firstActiveAnnouncement(
            userId: userId, after: after, now: dependencies.now()
        ) { announcementVisible($0, userId: userId, serverId: scopedServer) }
        return ActiveAnnouncementsResponse(announcements: row.map {
            [ActiveAnnouncementsResponse.Document(id: $0.id, title: $0.title, pages: $0.pages)]
        } ?? [])
    }

    // MARK: - POST /api/announcements/:id/dismiss

    public func dismissAnnouncement(
        authorization: String?,
        announcementId: String,
        query: String?,
        headerServerId: String?
    ) throws -> OkResponse {
        let userId = try requireUser(authorization)
        let scopedServer = try Self.announcementScope(query: query, headerServerId: headerServerId)
        guard let announcement = dependencies.notifications.announcement(id: announcementId),
              announcementVisible(announcement, userId: userId, serverId: scopedServer)
        else { throw ManagedMCPOAuthError.announcementNotFound }
        dependencies.notifications.insertAnnouncementDismissal(userId: userId, announcementId: announcementId)
        return OkResponse()
    }

    /// A targeted announcement is only visible inside one of its servers; the
    /// audience itself is never echoed to the client.
    private func announcementVisible(
        _ announcement: NotificationsStore.AnnouncementRow,
        userId: String,
        serverId: String?
    ) -> Bool {
        guard !announcement.audienceServerIds.isEmpty else { return true }
        guard let serverId else { return false }
        return announcement.audienceServerIds.contains(serverId)
            && oauth.memberRole(serverId: serverId, userId: userId) != nil
    }

    /// `server_id` must appear at most once and be a UUID; a duplicate or a
    /// malformed value never degrades into an unscoped answer.
    private static func announcementScope(query: String?, headerServerId: String?) throws -> String? {
        let values = (query ?? "").split(separator: "&").compactMap { pair -> String? in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.first == "server_id" else { return nil }
            return parts.count > 1 ? String(parts[1]).removingPercentEncoding ?? String(parts[1]) : ""
        }
        if values.count > 1 { throw ManagedMCPOAuthError.announcementServerIdRepeated }
        if let value = values.first {
            guard ServerScope.isUUID(value) else { throw ManagedMCPOAuthError.announcementServerIdInvalid }
            return value
        }
        return headerServerId
    }

    // MARK: - POST /api/channels/:id/unread

    public func markChannelUnread(
        authorization: String?,
        serverId: String,
        channelId: String
    ) throws -> ChannelMarkedUnreadResponse {
        let userId = try requireUser(authorization)
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            throw ManagedMCPOAuthError.notAMember
        }
        if dependencies.guestDeniedHiddenChannel(channelId, serverId, userId) {
            throw ManagedMCPOAuthError.channelNotFound
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            throw ManagedMCPOAuthError.channelNotFound
        }
        guard canReadChannel(channelId: channelId, serverId: serverId, userId: userId) else {
            throw ManagedMCPOAuthError.channelNotFound
        }
        let cursor = max(0, (oauth.latestPeerMessageSeq(channelId: channelId, excluding: userId) ?? 1) - 1)
        oauth.setChannelReadCursor(channelId: channelId, userId: userId, seq: cursor)
        let info = oauth.channelUnreadInfo(channelId: channelId, userId: userId)
        return ChannelMarkedUnreadResponse(
            channelId: channelId, unreadCount: info.unreadCount, maxReadSeq: info.maxReadSeq
        )
    }

    // MARK: - GET /api/channels/unread

    public func channelUnread(
        authorization: String?,
        serverId: String,
        summary: Bool
    ) throws -> ChannelUnreadResponse {
        let userId = try requireUser(authorization)
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            throw ManagedMCPOAuthError.notAMember
        }
        let channels = oauth.channelsForServer(serverId: serverId, userId: userId).filter { channel in
            guard channel.joined else { return false }
            if let thread = dependencies.channels.threadParentSnapshot(channelId: channel.id), thread.kind == "thread" {
                return thread.parentChannelId != nil && thread.parentDeleted == false
            }
            return true
        }
        if !summary {
            return .counts(channels.compactMap { channel in
                let info = oauth.channelUnreadInfo(channelId: channel.id, userId: userId)
                return info.unreadCount > 0 ? (channelId: channel.id, count: info.unreadCount) : nil
            })
        }
        var entries: [ChannelUnreadResponse.SummaryEntry] = []
        var threadUnread: [String: (count: Int, hasMention: Bool)] = [:]
        for channel in channels {
            let info = oauth.channelUnreadInfo(channelId: channel.id, userId: userId)
            let thread = dependencies.channels.threadParentSnapshot(channelId: channel.id).flatMap {
                $0.kind == "thread" ? $0 : nil
            }
            if thread != nil {
                guard dependencies.messages.followsActiveThread(
                    serverId: serverId, userId: userId, threadChannelId: channel.id
                ) else { continue }
            }
            let threadReplies = thread == nil ? [] : dependencies.messages.threadUnreadFacts(channelId: channel.id)
            var unreadCount = info.unreadCount
            var latestMessageId = info.latestMessageId
            var latestSeq = info.latestSeq
            if !threadReplies.isEmpty {
                unreadCount = threadReplies.filter { $0.seq > info.maxReadSeq && $0.senderId != userId }.count
                latestMessageId = threadReplies.last?.id
                latestSeq = threadReplies.count
            }
            let hasAny = dependencies.messages.userMentionExists(channelId: channel.id, userId: userId)
            if let thread, unreadCount > 0, let parentId = thread.parentChannelId {
                var aggregate = threadUnread[parentId] ?? (count: 0, hasMention: false)
                aggregate.count += 1
                aggregate.hasMention = aggregate.hasMention || hasAny
                threadUnread[parentId] = aggregate
            }
            guard unreadCount > 0 else { continue }
            let parentId = thread?.parentChannelId
            entries.append(ChannelUnreadResponse.SummaryEntry(
                channelId: channel.id,
                unreadCount: unreadCount,
                hasMention: hasAny,
                maxReadSeq: info.maxReadSeq,
                latestMessageId: latestMessageId,
                latestSeq: latestSeq,
                parentChannelId: parentId,
                parentMessageId: parentId == nil ? nil : thread?.parentMessageId
            ))
        }
        return .summary(
            entries: entries,
            threadUnread: threadUnread.map {
                ChannelUnreadResponse.ThreadAggregate(
                    parentChannelId: $0.key, count: $0.value.count, hasMention: $0.value.hasMention
                )
            }
        )
    }

    // MARK: - Channel notification settings

    public func channelNotificationSettings(
        authorization: String?,
        serverId: String,
        channelId: String
    ) throws -> ChannelNotificationSettingsResponse {
        let userId = try requireUser(authorization)
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            throw ManagedMCPOAuthError.notAMember
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            throw ManagedMCPOAuthError.channelNotFound
        }
        let channelType = oauth.channelType(id: channelId) ?? "channel"
        guard channelType != "thread" else { throw ManagedMCPOAuthError.threadsUseFollow }
        let prefs = oauth.notificationPrefs(channelId: channelId, userId: userId)
        let muted = prefs.activityMuted && prefs.muteFromSeq != nil
        return ChannelNotificationSettingsResponse(
            activityMuted: muted,
            muteFromSeq: muted ? prefs.muteFromSeq : nil,
            prefsVersion: prefs.prefsVersion,
            activityMuteSupported: ChannelActivityMuteSupport.supports(channelType)
        )
    }

    public func patchChannelNotificationSettings(
        authorization: String?,
        serverId: String,
        channelId: String,
        body: LenientJSONObjectRequest?
    ) throws -> ChannelNotificationSettingsResponse {
        let userId = try requireUser(authorization)
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            throw ManagedMCPOAuthError.notAMember
        }
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId else {
            throw ManagedMCPOAuthError.channelNotFound
        }
        guard oauth.channelArchivedAt(id: channelId) == nil else { throw ManagedMCPOAuthError.channelArchived }
        let channelType = oauth.channelType(id: channelId) ?? "channel"
        guard channelType != "thread" else { throw ManagedMCPOAuthError.threadsUseFollow }
        guard let muted = body?["activityMuted"]?.legacyBool else {
            throw ManagedMCPOAuthError.activityMutedNotBoolean
        }
        let result = oauth.setActivityMuted(channelId: channelId, userId: userId, muted: muted)
        let appliedMute = result.prefs.activityMuted && result.prefs.muteFromSeq != nil
        return ChannelNotificationSettingsResponse(
            activityMuted: appliedMute,
            muteFromSeq: appliedMute ? result.prefs.muteFromSeq : nil,
            prefsVersion: result.prefs.prefsVersion,
            activityMuteSupported: ChannelActivityMuteSupport.supports(channelType)
        )
    }

    // MARK: - Agent user lookups

    /// The agent credential gates both lookups share: identity, `read`
    /// capability, then the two required scopes.
    private func agentIdentity(authorization: String?) throws -> (agentId: String, serverId: String) {
        guard let identity = dependencies.agentIdentity(authorization, "channels") else {
            throw ManagedMCPOAuthError.agentAuthRequired
        }
        guard dependencies.agentScopes(authorization)?.contains("read") == true else {
            throw ManagedMCPOAuthError.capabilityNotAuthorized
        }
        let scopes = dependencies.agentScopes(authorization) ?? []
        for required in ["channel:read", "server:read"] where !scopes.contains(required) {
            throw ManagedMCPOAuthError.missingScope(required)
        }
        return identity
    }

    public func agentUserChannels(
        authorization: String?,
        name: String,
        limit: String?,
        offset: String?
    ) throws -> AgentUserChannelsResponse {
        let identity = try agentIdentity(authorization: authorization)
        guard Self.agentUserPageValues(limit: limit, offset: offset) != nil else {
            throw ManagedMCPOAuthError.invalidPageWindow(
                Self.agentUserPageIssues(limit: limit, offset: offset)
            )
        }
        guard let payload = agentUserChannelsPayload(identity: identity, name: name, limit: limit, offset: offset) else {
            throw ManagedMCPOAuthError.userNotFound
        }
        return payload
    }

    /// The text projection of the same lookup.
    public func agentUserInfo(
        authorization: String?,
        name: String,
        limit: String?,
        offset: String?
    ) throws -> ManagedMCPAssetResponse {
        let identity = try agentIdentity(authorization: authorization)
        let normalized = name.hasPrefix("@") ? String(name.dropFirst()) : name
        if normalized.isEmpty || Self.agentUserPageValues(limit: limit, offset: offset) == nil {
            throw ManagedMCPOAuthError.userNotFoundBadRequest
        }
        guard let payload = agentUserChannelsPayload(identity: identity, name: name, limit: limit, offset: offset) else {
            throw ManagedMCPOAuthError.userNotFound
        }
        return ManagedMCPAssetResponse(
            headers: .exact(["Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store"]),
            text: payload.text
        )
    }

    /// Pinned `agentApiUserChannelsQuerySchema`: both members are trimmed
    /// strings matched against a regular expression, so ` 200 ` is valid and
    /// `01`, `0200`, `+1` and `200.0` are not.
    private static let offsetPattern = #"^(0|[1-9][0-9]*)$"#
    private static let limitPattern = #"^([1-9]|[1-9][0-9]|1[0-9][0-9]|200)$"#

    private static func agentUserPageValues(limit: String?, offset: String?) -> (limit: Int, offset: Int)? {
        let resolvedLimit: Int
        if let limit {
            let trimmed = limit.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.range(of: limitPattern, options: .regularExpression) != nil,
                  let value = Int(trimmed)
            else { return nil }
            resolvedLimit = value
        } else {
            resolvedLimit = 50
        }
        let resolvedOffset: Int
        if let offset {
            let trimmed = offset.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.range(of: offsetPattern, options: .regularExpression) != nil,
                  let value = Int(trimmed)
            else { return nil }
            resolvedOffset = value
        } else {
            resolvedOffset = 0
        }
        return (resolvedLimit, resolvedOffset)
    }

    /// The zod issues of the two optional query members, in shape order.
    private static func agentUserPageIssues(limit: String?, offset: String?) -> [AuthRequestIssue] {
        var issues: [AuthRequestIssue] = []
        if let offset {
            let trimmed = offset.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.range(of: offsetPattern, options: .regularExpression) == nil {
                issues.append(AuthRequestIssue(path: "offset", message: "must be a non-negative integer"))
            }
        }
        if let limit {
            let trimmed = limit.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.range(of: limitPattern, options: .regularExpression) == nil {
                issues.append(AuthRequestIssue(path: "limit", message: "must be an integer from 1 to 200"))
            }
        }
        return issues
    }

    private func agentUserChannelsPayload(
        identity: (agentId: String, serverId: String),
        name: String,
        limit: String?,
        offset: String?
    ) -> AgentUserChannelsResponse? {
        let normalized = name.hasPrefix("@") ? String(name.dropFirst()) : name
        guard !normalized.isEmpty else { return nil }
        guard let page = Self.agentUserPageValues(limit: limit, offset: offset) else { return nil }
        let snapshot = dependencies.channels.postableAndJointSnapshot()
        let hidden = snapshot.hideHumans[identity.serverId] ?? false
        let callerAgentRole = oauth.agentRole(serverId: identity.serverId, agentId: identity.agentId) ?? "member"
        guard let subject = dependencies.profiles.firstAccount(exactName: normalized) else { return nil }
        if hidden, callerAgentRole != "owner", callerAgentRole != "admin" { return nil }
        guard oauth.memberRole(serverId: identity.serverId, userId: subject.id) != nil else { return nil }
        var unchecked = 0
        let callerReadsRoster: (String) -> Bool = { [oauth] channelId in
            if snapshot.postable[channelId]?.memberIds.contains(identity.agentId) == true { return true }
            return oauth.channelAgentIds(channelId: channelId).contains(identity.agentId)
        }
        var rows: [AgentUserChannelsResponse.Membership] = []
        for channel in oauth.channelsForServer(serverId: identity.serverId, userId: subject.id, includeArchived: false) {
            let type = oauth.channelType(id: channel.id) ?? channel.type
            if type == "joint" {
                guard let link = snapshot.joint.first(where: {
                          $0.localChannelId == channel.id && $0.serverId == identity.serverId
                      }),
                      link.status == "active",
                      callerReadsRoster(channel.id)
                else {
                    unchecked += 1
                    continue
                }
            }
            var role: String?
            if (type == "channel" || type == "private"), channel.name != "all" {
                let channelRole = dependencies.channels.channelHumanRole(channelId: channel.id, userId: subject.id)
                role = channelRole == "admin" ? "admin" : "member"
            }
            rows.append(AgentUserChannelsResponse.Membership(
                id: channel.id, name: channel.name, type: type, joined: channel.joined, channelRole: role
            ))
        }
        return AgentUserChannelsResponse(
            name: subject.name,
            uncheckedCount: unchecked,
            page: Array(rows.dropFirst(page.offset).prefix(page.limit)),
            total: rows.count,
            offset: page.offset,
            limit: page.limit
        )
    }

    // MARK: - App-installation reminders

    public func appAgentReminderMessage(
        authorization: String?,
        body: LenientJSONObjectRequest?
    ) throws -> AppAgentReminderResponse {
        guard let access = oauth.appInstallationAccess(authorization: authorization) else {
            throw ManagedMCPOAuthError.invalidInstallationCredential
        }
        guard access.official, access.groups.contains("agent_reminder_write") else {
            throw ManagedMCPOAuthError.reminderWriteNotAuthorized
        }
        guard let object = body,
              let agentId = object["agentId"]?.legacyString, ServerScope.isUUID(agentId),
              let key = object["idempotencyKey"]?.legacyString, (1...200).contains(key.count),
              let text = object["text"]?.legacyString, (1...8000).contains(text.count)
        else { throw ManagedMCPOAuthError.invalidAgentReminderRequest }
        guard let agent = oauth.agentRuntimeInfo(id: agentId), !agent.deleted, agent.serverId == access.serverId else {
            throw ManagedMCPOAuthError.agentNotFound
        }
        let ledgerKey = "\(access.clientId)\n\(agentId)\n\(key)"
        if let existing = dependencies.feedback.appAgentReminderMessageId(ledgerKey: ledgerKey) {
            return AppAgentReminderResponse(created: false, messageId: existing)
        }
        var channelId = dependencies.feedback.agentReminderSurfaceChannelId(agentId: agentId)
        if let existing = channelId,
           dependencies.channels.postableChannel(id: existing)?.deletedAt != nil {
            dependencies.feedback.clearAgentReminderSurface(agentId: agentId, ifChannelId: existing)
            channelId = nil
        }
        if channelId == nil {
            let createdChannel = oauth.createChannel(
                serverId: access.serverId, name: "reminders", creatorUserId: agentId, type: "dm"
            )
            oauth.addChannelAgent(channelId: createdChannel, agentId: agentId)
            dependencies.channels.addPostableChannel(
                serverId: access.serverId, channelId: createdChannel, memberId: agentId,
                kind: "dm", name: "reminders"
            )
            dependencies.feedback.setAgentReminderSurface(agentId: agentId, channelId: createdChannel)
            channelId = createdChannel
        }
        guard let channelId else { throw ManagedMCPOAuthError.reminderSurfaceUnavailable }
        let messageId = UUID().uuidString.lowercased()
        dependencies.appendMessage(StoredHumanMessage(
            id: messageId,
            channelId: channelId,
            senderId: "system",
            content: text,
            randomId: nil,
            messageType: "system",
            senderType: "user",
            systemSubtype: "agent.reminder_due"
        ))
        dependencies.feedback.recordAppAgentReminder(ledgerKey: ledgerKey, messageId: messageId)
        return AppAgentReminderResponse(created: true, messageId: messageId)
    }
}

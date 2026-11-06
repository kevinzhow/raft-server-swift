import Foundation

/// `POST /api/public-visits/:slug` and the `visitorIdMode` on the public page.
///
/// Every visit response is an empty 204. A same-site body that names a public
/// server with counting on is recorded: the server decides the visitor class,
/// and a sharing signed-in visitor is the only one who carries an analytics id.
/// The page offers a visitor id only when that id would be kept.

public struct PublicVisitRow: Equatable, Sendable {
    public var event: String
    public var visitor: String
    public var serverId: String
    public var source: String
    public var analyticsId: String?
    public var clientSessionId: String?
    public var channelId: String?
    public var threadChannelId: String?
    public var entry: String?
    public var referrerDomain: String?
    public var utmSource: String?
    public var utmMedium: String?
    public var utmCampaign: String?
    public var hasVisitorId: Bool?
    public var uuid: String?
    public var browser: String?
    public var browserVersion: Int?
    public var os: String?
    public var deviceType: String?
    public var country: String?

    public init(
        event: String,
        visitor: String,
        serverId: String,
        source: String,
        analyticsId: String?,
        clientSessionId: String?,
        channelId: String?,
        threadChannelId: String? = nil,
        entry: String? = nil,
        referrerDomain: String? = nil,
        utmSource: String? = nil,
        utmMedium: String? = nil,
        utmCampaign: String? = nil,
        hasVisitorId: Bool? = nil,
        uuid: String? = nil,
        browser: String? = nil,
        browserVersion: Int? = nil,
        os: String? = nil,
        deviceType: String? = nil,
        country: String? = nil
    ) {
        self.event = event
        self.visitor = visitor
        self.serverId = serverId
        self.source = source
        self.analyticsId = analyticsId
        self.clientSessionId = clientSessionId
        self.channelId = channelId
        self.threadChannelId = threadChannelId
        self.entry = entry
        self.referrerDomain = referrerDomain
        self.utmSource = utmSource
        self.utmMedium = utmMedium
        self.utmCampaign = utmCampaign
        self.hasVisitorId = hasVisitorId
        self.uuid = uuid
        self.browser = browser
        self.browserVersion = browserVersion
        self.os = os
        self.deviceType = deviceType
        self.country = country
    }
}

public struct PublicVisitorRow: Equatable, Sendable {
    public var uuid: String
    public var event: String
    public var serverId: String
    public var anonymousId: String

    public init(uuid: String, event: String, serverId: String, anonymousId: String) {
        self.uuid = uuid
        self.event = event
        self.serverId = serverId
        self.anonymousId = anonymousId
    }
}

public struct PublicJoinAudit: Equatable, Sendable {
    public var source: String
    public var agreementId: String
    public var subjectId: String

    public init(source: String, agreementId: String, subjectId: String) {
        self.source = source
        self.agreementId = agreementId
        self.subjectId = subjectId
    }
}

public struct PublicVisitUser: Equatable, Sendable {
    public var id: String
    public var shareUsageData: Bool?
    public var analyticsId: String?

    public init(id: String, shareUsageData: Bool?, analyticsId: String?) {
        self.id = id
        self.shareUsageData = shareUsageData
        self.analyticsId = analyticsId
    }
}

public final class PublicVisitDirectory: @unchecked Sendable {
    public static let defaultDailyCap = 20_000
    private let lock = NSLock()
    private var dailyCap: Int
    private var servers: [String: Server] = [:]
    private var users: [String: PublicVisitUser] = [:]
    private var tokens: [String: String] = [:]
    private var seen: Set<String> = []
    private var daily: [String: Int] = [:]
    private var recorded: [PublicVisitRow] = []
    private var visitorRows: [PublicVisitorRow] = []
    private var translationProviderConfigured = false
    private var llmTranslationUnavailable = false
    private var history: [String: [PublicHistoryMessage]] = [:]
    private var channelMembers: [String: [String]] = [:]
    private var attachments: [String: StoredAttachment] = [:]
    private var objects: [String: String] = [:]
    private var presignTarget: String?
    private var recordedPresigns: [PublicPresignRequest] = []

    public init(dailyCap: Int = PublicVisitDirectory.defaultDailyCap) {
        self.dailyCap = dailyCap
    }

    public func addServer(
        id: String,
        slug: String,
        publiclyVisible: Bool = true,
        productAnalyticsEnabled: Bool = true,
        publicEnabled: Bool = true,
        countsEnabled: Bool = true,
        visitorIdEnabled: Bool = false,
        memberIds: Set<String> = [],
        guestChannelIds: Set<String> = [],
        name: String = "",
        guestJoinEnabled: Bool = false,
        guestRolloutEnabled: Bool = false,
        translationEnabled: Bool = false,
        avatarUrl: String? = nil
    ) {
        lock.lock()
        servers[slug] = Server(
            id: id,
            name: name.isEmpty ? slug : name,
            publiclyVisible: publiclyVisible,
            productAnalyticsEnabled: productAnalyticsEnabled,
            publicEnabled: publicEnabled,
            countsEnabled: countsEnabled,
            visitorIdEnabled: visitorIdEnabled,
            guestJoinEnabled: guestJoinEnabled,
            guestRolloutEnabled: guestRolloutEnabled,
            translationEnabled: translationEnabled,
            avatarUrl: avatarUrl,
            memberIds: memberIds,
            guestChannelIds: Set(guestChannelIds.map { $0.lowercased() }),
            guestChannelNames: Dictionary(uniqueKeysWithValues: guestChannelIds.map { ($0.lowercased(), $0.lowercased()) }),
            channelTypes: Dictionary(uniqueKeysWithValues: guestChannelIds.map { ($0.lowercased(), "channel") }),
            threads: [:],
            archivedChannelIds: [],
            mentionMembers: [],
            mentionAgents: [],
            memberRoles: Dictionary(uniqueKeysWithValues: memberIds.map { ($0, "member") }),
            agreement: nil,
            joinAudits: []
        )
        lock.unlock()
    }

    public func addThread(slug: String, id: String, parentChannelId: String, archived: Bool = false) {
        lock.lock()
        servers[slug]?.threads[id.lowercased()] = Thread(
            parentChannelId: parentChannelId.lowercased(),
            archived: archived
        )
        lock.unlock()
    }

    public func addUser(_ user: PublicVisitUser) {
        lock.lock()
        users[user.id] = user
        lock.unlock()
    }

    public func addToken(_ token: String, userId: String) {
        lock.lock()
        tokens[token] = userId
        lock.unlock()
    }

    public func addMentionMember(slug: String, userId: String, name: String, displayName: String) {
        lock.lock()
        servers[slug]?.mentionMembers.append(MentionPerson(
            name: name,
            displayName: displayName,
            actorId: userId,
            deleted: false,
            member: true
        ))
        lock.unlock()
    }

    public func addMentionAgent(slug: String, agentId: String, name: String, displayName: String, deleted: Bool = false) {
        lock.lock()
        servers[slug]?.mentionAgents.append(MentionPerson(
            name: name,
            displayName: displayName,
            actorId: agentId,
            deleted: deleted,
            member: false
        ))
        lock.unlock()
    }

    /// A handle that exists somewhere else. It is not a member of this server, so a typed `@name` does not highlight it.
    public func addMentionOutsider(slug: String, userId: String, name: String, displayName: String) {
        lock.lock()
        servers[slug]?.mentionMembers.append(MentionPerson(
            name: name,
            displayName: displayName,
            actorId: userId,
            deleted: false,
            member: false
        ))
        lock.unlock()
    }

    public func archiveChannel(slug: String, id: String) {
        lock.lock()
        servers[slug]?.archivedChannelIds.insert(id.lowercased())
        lock.unlock()
    }

    /// Object storage that can sign a URL. The next readable download redirects instead of streaming bytes.
    public func enablePresign(_ url: String) {
        lock.lock()
        presignTarget = url
        lock.unlock()
    }

    public var presignCalls: [PublicPresignRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedPresigns
    }

    public func putPublicObject(key: String, bytes: String) {
        lock.lock()
        objects[key] = bytes
        lock.unlock()
    }

    public func addPublicAttachment(
        id: String,
        channelId: String,
        messageId: String?,
        filename: String,
        mimeType: String,
        storageKey: String
    ) {
        lock.lock()
        attachments[id.lowercased()] = StoredAttachment(
            channelId: channelId.lowercased(),
            messageId: messageId,
            filename: filename,
            mimeType: mimeType,
            storageKey: storageKey
        )
        lock.unlock()
    }

    public func publicAttachment(
        slug: String,
        attachmentId: String,
        forceDownload: Bool,
        inlineDisposition: Bool = false,
        frameAncestors: [String] = []
    ) throws -> PublicAttachmentResponse {
        guard ServerScope.isUUID(attachmentId) else { throw PublicAttachments.missing(attachmentId: attachmentId) }
        lock.lock()
        let attachment = attachments[attachmentId.lowercased()]
        let server = servers[slug]
        let bytes = attachment.flatMap { objects[$0.storageKey] }
        let readable = attachment.map { attachmentIsReadable($0, server: server) } ?? false
        let presignTarget = self.presignTarget
        lock.unlock()
        guard readable, let attachment else {
            throw PublicAttachments.missing(attachmentId: attachmentId)
        }
        if let presignTarget {
            let request = PublicAttachments.presignRequest(
                key: attachment.storageKey,
                filename: attachment.filename,
                mimeType: attachment.mimeType,
                forceDownload: forceDownload,
                inlineDisposition: inlineDisposition
            )
            lock.lock()
            recordedPresigns.append(request)
            lock.unlock()
            return PublicAttachments.redirect(location: presignTarget)
        }
        guard let bytes else {
            throw PublicAttachments.missing(attachmentId: attachmentId)
        }
        return PublicAttachments.file(
            bytes: bytes,
            filename: attachment.filename,
            mimeType: attachment.mimeType,
            forceDownload: forceDownload,
            inlineDisposition: inlineDisposition,
            frameAncestors: frameAncestors
        )
    }

    public func addGuestChannel(slug: String, id: String, name: String, type: String = "channel") {
        lock.lock()
        let key = id.lowercased()
        servers[slug]?.guestChannelIds.insert(key)
        servers[slug]?.guestChannelNames[key] = name
        servers[slug]?.channelTypes[key] = type
        lock.unlock()
    }

    public func setTranslationAvailable(_ enabled: Bool) {
        lock.lock()
        translationProviderConfigured = enabled
        lock.unlock()
    }

    public func setLlmTranslationUnavailable(_ unavailable: Bool) {
        lock.lock()
        llmTranslationUnavailable = unavailable
        lock.unlock()
    }

    public func translationGate(slug: String) -> PublicTranslations.Gate? {
        lock.lock()
        defer { lock.unlock() }
        guard let server = servers[slug] else { return nil }
        return PublicTranslations.Gate(
            publiclyVisible: server.publiclyVisible,
            publicEnabled: server.publicEnabled,
            translationEnabled: server.translationEnabled,
            providerConfigured: translationProviderConfigured,
            llmUnavailable: llmTranslationUnavailable
        )
    }

    public func publicTranslationResults(slug: String, targetLanguage: String, messageIds: [String]) -> [[String: String]] {
        lock.lock()
        defer { lock.unlock() }
        guard let server = servers[slug], let messages = history[slug] else {
            return messageIds.map { ["messageId": $0, "status": "not_found", "targetLanguage": targetLanguage] }
        }
        let byId = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        return messageIds.map { id in
            guard let message = byId[id] else {
                return ["messageId": id, "status": "not_found", "targetLanguage": targetLanguage]
            }
            let visibleChannel = server.guestChannelIds.contains(message.channelId.lowercased())
                || server.threads[message.channelId.lowercased()].map { server.guestChannelIds.contains($0.parentChannelId) } == true
            guard visibleChannel, !server.archivedChannelIds.contains(message.channelId.lowercased()) else {
                return ["messageId": id, "status": "not_found", "targetLanguage": targetLanguage]
            }
            let source = PublicTranslations.detectSourceLanguage(message.content)
            if source == targetLanguage {
                return ["messageId": id, "status": "skipped", "reason": "target_is_source", "sourceLanguage": source, "targetLanguage": targetLanguage]
            }
            return [
                "messageId": id,
                "status": "translated",
                "sourceLanguage": source,
                "targetLanguage": targetLanguage,
                "translatedContent": "[\(targetLanguage)] \(message.content)",
                "provider": "fake",
                "providerVersion": "fake@v0+fake-v0",
            ]
        }
    }

    public func setServerCard(
        slug: String,
        guestJoinEnabled: Bool? = nil,
        guestRolloutEnabled: Bool? = nil,
        translationEnabled: Bool? = nil,
        avatarUrl: String? = nil
    ) {
        lock.lock()
        if let guestJoinEnabled { servers[slug]?.guestJoinEnabled = guestJoinEnabled }
        if let guestRolloutEnabled { servers[slug]?.guestRolloutEnabled = guestRolloutEnabled }
        if let translationEnabled { servers[slug]?.translationEnabled = translationEnabled }
        if let avatarUrl { servers[slug]?.avatarUrl = avatarUrl }
        lock.unlock()
    }

    public func setPubliclyVisible(slug: String, visible: Bool) {
        lock.lock()
        servers[slug]?.publiclyVisible = visible
        lock.unlock()
    }

    public func setPublicEnabled(slug: String, enabled: Bool) {
        lock.lock()
        servers[slug]?.publicEnabled = enabled
        lock.unlock()
    }

    public func addMember(slug: String, userId: String) {
        lock.lock()
        servers[slug]?.memberIds.insert(userId)
        lock.unlock()
    }

    public func addChannelMember(channelId: String, userId: String) {
        lock.lock()
        let key = channelId.lowercased()
        var members = channelMembers[key] ?? []
        if !members.contains(userId) { members.append(userId) }
        channelMembers[key] = members
        lock.unlock()
    }

    public func channelMemberIds(channelId: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return channelMembers[channelId.lowercased()] ?? []
    }

    public func messageCount(slug: String, channelId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let id = channelId.lowercased()
        return (history[slug] ?? []).filter { $0.channelId.lowercased() == id }.count
    }

    public func setVisitorIdEnabled(slug: String, enabled: Bool) {
        lock.lock()
        servers[slug]?.visitorIdEnabled = enabled
        lock.unlock()
    }

    public func setProductAnalyticsEnabled(slug: String, enabled: Bool) {
        lock.lock()
        servers[slug]?.productAnalyticsEnabled = enabled
        lock.unlock()
    }

    public var rows: [PublicVisitRow] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    public var visitors: [PublicVisitorRow] {
        lock.lock()
        defer { lock.unlock() }
        return visitorRows
    }

    public func record(
        slug: String,
        site: String?,
        authorization: String?,
        body: String,
        userAgent: String? = nil,
        country: String? = nil,
        now: Date = Date()
    ) {
        guard site == "same-origin" || site == "same-site" else { return }
        guard Data(body.utf8).count <= 1024 else { return }
        guard let visit = PublicVisits.parse(body) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let server = servers[slug], server.publiclyVisible, server.publicEnabled, server.countsEnabled else { return }
        guard server.productAnalyticsEnabled else { return }
        let channelId = visit.channelId?.lowercased()
        if visit.event == "public_page_channel_opened" {
            guard let channelId, Self.isOrdinaryGuestChannel(server, channelId) else { return }
        }
        var threadChannelId: String?
        if visit.event == "public_page_thread_opened" {
            guard let channelId, let rawThread = visit.threadChannelId else { return }
            threadChannelId = rawThread.lowercased()
            guard Self.isOrdinaryGuestChannel(server, channelId),
                  let thread = server.threads[threadChannelId!],
                  !thread.archived,
                  thread.parentChannelId == channelId
            else { return }
        }
        let kept = PublicVisits.kept(visit, channelId: channelId, threadChannelId: threadChannelId)
        guard seen.insert(visit.uuid).inserted else { return }
        let day = PublicVisits.utcDay(now)
        let slotKey = "\(server.id):\(day)"
        let used = (daily[slotKey] ?? 0) + 1
        guard used <= dailyCap else { return }
        daily[slotKey] = used
        let userId = bearerUserId(authorization)
        let context = PublicVisits.requestContext(userAgent: userAgent, country: country)
        var visitor = "anonymous"
        var analyticsId: String?
        if let userId, let user = users[userId] {
            visitor = server.memberIds.contains(userId) ? "signed_in_member" : "signed_in_non_member"
            if user.shareUsageData == true {
                analyticsId = user.analyticsId
            }
        }
        if visitor == "anonymous", server.visitorIdEnabled, let anonymousId = PublicVisits.visitorId(visit.anonymousId) {
            visitorRows.append(PublicVisitorRow(
                uuid: visit.uuid,
                event: visit.event,
                serverId: server.id,
                anonymousId: anonymousId
            ))
        }
        recorded.append(PublicVisitRow(
            event: visit.event,
            visitor: visitor,
            serverId: server.id,
            source: "server",
            analyticsId: analyticsId,
            clientSessionId: nil,
            channelId: kept.channelId,
            threadChannelId: kept.threadChannelId,
            entry: kept.entry,
            referrerDomain: kept.referrerDomain,
            utmSource: kept.utmSource,
            utmMedium: kept.utmMedium,
            utmCampaign: kept.utmCampaign,
            browser: context.browser,
            browserVersion: context.browserVersion,
            os: context.os,
            deviceType: context.deviceType,
            country: context.country
        ))
    }

    public func setAgreement(slug: String, id: String, title: String, bodyMarkdown: String) {
        lock.lock()
        servers[slug]?.agreement = StoredAgreement(
            id: id,
            title: title,
            bodyMarkdown: bodyMarkdown,
            version: 1,
            enabled: true
        )
        lock.unlock()
    }

    public func serverMemberRole(slug: String, userId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard servers[slug]?.memberIds.contains(userId) == true else { return nil }
        return servers[slug]?.memberRoles[userId] ?? "member"
    }

    public func joinAudits(slug: String) -> [PublicJoinAudit] {
        lock.lock()
        defer { lock.unlock() }
        return servers[slug]?.joinAudits.map {
            PublicJoinAudit(source: $0.source, agreementId: $0.agreementId, subjectId: $0.subjectId)
        } ?? []
    }

    public func join(slug: String, authorization: String?, body: String) throws -> PublicJoinResponse {
        lock.lock()
        defer { lock.unlock() }
        guard let userId = bearerUserId(authorization), users[userId] != nil else {
            throw PublicVisits.authRequired(authorization: authorization)
        }
        guard var server = servers[slug],
              server.publiclyVisible,
              server.publicEnabled,
              server.guestRolloutEnabled,
              server.guestJoinEnabled
        else {
            throw PublicVisitError.notFound
        }
        let already = server.memberIds.contains(userId)
        if !already {
            if let agreement = server.agreement, agreement.enabled {
                let sent = Self.agreementId(body)
                if sent == nil {
                    throw Self.agreementRequired(agreement)
                }
                if sent != agreement.id {
                    throw Self.agreementChanged(agreement)
                }
            }
            server.memberIds.insert(userId)
            server.memberRoles[userId] = "guest"
            if let agreement = server.agreement, agreement.enabled {
                server.joinAudits.append(JoinAudit(subjectId: userId, source: "join", agreementId: agreement.id))
            }
            servers[slug] = server
            recordJoin(server: server, userId: userId, body: body)
        }
        let role = server.memberRoles[userId] ?? "guest"
        return PublicJoinResponse(
            serverId: server.id, serverName: server.name, serverSlug: slug, role: role, joined: !already
        )
    }

    public func page(slug: String, country: String?, region: String?, gpc: String?) throws -> PublicPageResponse {
        lock.lock()
        let server = servers[slug]
        let translationAvailable = translationProviderConfigured
        lock.unlock()
        guard let server, server.publiclyVisible, server.publicEnabled else {
            throw PublicVisitError.notFound
        }
        let offered = server.countsEnabled && server.productAnalyticsEnabled && server.visitorIdEnabled
        let mode = offered ? PublicVisitorRegion.visitorIdMode(country: country, region: region, gpc: gpc) : nil
        let channelIds = server.guestChannelIds.filter { Self.isOrdinaryGuestChannel(server, $0) }.sorted {
            let left = server.guestChannelNames[$0] ?? $0
            let right = server.guestChannelNames[$1] ?? $1
            return left == right ? $0 < $1 : left < right
        }
        return try PublicVisits.pageReply(
            found: true,
            mode: mode,
            channelIds: channelIds,
            channelNames: server.guestChannelNames,
            serverId: server.id,
            serverName: server.name,
            slug: slug,
            avatarUrl: server.avatarUrl,
            translationEnabled: server.translationEnabled,
            canJoinAsGuest: server.guestJoinEnabled && server.guestRolloutEnabled,
            translationAvailable: translationAvailable
        )
    }

    /// Member server list. `publicPageLive` is the anonymous page gate
    /// (`publiclyVisible` and the rollout flag). The stored switch itself is omitted.
    public func serverList(authorization: String?) throws -> PublicServerListResponse {
        lock.lock()
        defer { lock.unlock() }
        guard let userId = bearerUserId(authorization), users[userId] != nil else {
            throw PublicVisits.authRequired(authorization: authorization)
        }
        let rows = servers
            .filter { $0.value.memberIds.contains(userId) }
            .sorted { $0.value.id < $1.value.id }
        return PublicServerListResponse(servers: rows.map { slug, server in
            .init(id: server.id, slug: slug, role: server.memberRoles[userId] ?? "member",
                  publicPageLive: server.publiclyVisible && server.publicEnabled)
        })
    }

    public func joinCommunity(userId: String, slug rawSlug: String?) throws -> PublicServerJoinedResponse {
        let slug = rawSlug ?? "community"
        guard slug == "community" || slug == "community-cn" else {
            throw PublicVisitError.unsupportedCommunity
        }
        lock.lock()
        guard var server = servers[slug] else {
            lock.unlock()
            throw PublicVisitError.communityUnavailable
        }
        guard !server.memberIds.contains(userId) else {
            lock.unlock()
            throw PublicVisitError.alreadyMember
        }
        server.memberIds.insert(userId)
        server.memberRoles[userId] = "member"
        servers[slug] = server
        lock.unlock()
        return PublicServerJoinedResponse(serverId: server.id, serverName: server.name)
    }

    public func addPublicMessage(slug: String, message: PublicHistoryMessage) {
        lock.lock()
        history[slug, default: []].append(message)
        lock.unlock()
    }

    public func addPublicReply(slug: String, parentMessageId: String, threadId: String, reply: PublicHistoryReply) {
        lock.lock()
        guard var messages = history[slug], let index = messages.firstIndex(where: { $0.id == parentMessageId }) else {
            lock.unlock()
            return
        }
        messages[index].threadId = threadId
        messages[index].replies.append(reply)
        history[slug] = messages
        lock.unlock()
    }

    public func channelMessages(slug: String, channelId: String, limit: Int = 50, beforeMessageId: String? = nil) throws -> PublicHistoryResponse {
        let id = channelId.lowercased()
        lock.lock()
        let server = servers[slug]
        let messages = history[slug] ?? []
        lock.unlock()
        guard let server, server.publiclyVisible, server.publicEnabled, Self.isOrdinaryGuestChannel(server, id) else {
            throw PublicServerMessages.channel(channelId: channelId)
        }
        let rows = messages.filter { $0.channelId.lowercased() == id }
        guard let page = PublicHistoryProjection.page(rows, limit: limit, beforeId: beforeMessageId) else {
            throw PublicServerMessages.channel(channelId: channelId)
        }
        return PublicHistoryResponse(
            messages: page,
            serverId: server.id,
            mentions: mentionDirectory(for: server)
        )
    }

    public func threadMessages(slug: String, threadId: String, limit: Int = 50, beforeMessageId: String? = nil) throws -> PublicHistoryResponse {
        let id = threadId.lowercased()
        lock.lock()
        let server = servers[slug]
        let messages = history[slug] ?? []
        lock.unlock()
        guard let server, server.publiclyVisible, server.publicEnabled,
              let thread = server.threads[id],
              Self.isOrdinaryGuestChannel(server, thread.parentChannelId)
        else {
            throw PublicServerMessages.thread(threadChannelId: threadId)
        }
        let replies = messages.first { $0.threadId?.lowercased() == id }?.replies ?? []
        guard let page = PublicHistoryProjection.page(replies, limit: limit, beforeId: beforeMessageId) else {
            throw PublicServerMessages.thread(threadChannelId: threadId)
        }
        let projected = page.map { reply in
            PublicHistoryMessage(
                id: reply.id,
                channelId: id,
                content: reply.content,
                createdAt: reply.createdAt,
                seq: reply.seq,
                senderType: reply.senderType,
                sender: reply.sender
            )
        }
        return PublicHistoryResponse(
            messages: projected,
            serverId: server.id,
            mentions: mentionDirectory(for: server)
        )
    }

    /// Agents first, then members, so a human wins a shared name. Outsiders and deleted agents are absent.
    private func mentionDirectory(for server: Server) -> PublicMentionDirectory {
        var entries: [String: PublicMentionDirectory.Entry] = [:]
        for agent in server.mentionAgents where !agent.deleted {
            let display = agent.displayName.isEmpty ? agent.name : agent.displayName
            entries[agent.name] = PublicMentionDirectory.Entry(type: "agent", displayName: display)
        }
        for member in server.mentionMembers where member.member {
            let display = member.displayName.isEmpty ? member.name : member.displayName
            entries[member.name] = PublicMentionDirectory.Entry(type: "user", displayName: display)
        }
        return PublicMentionDirectory(entries: entries)
    }

    private func attachmentIsReadable(_ attachment: StoredAttachment, server: Server?) -> Bool {
        guard let server, server.publiclyVisible, server.publicEnabled else { return false }
        guard attachment.messageId != nil else { return false }
        if Self.isOrdinaryGuestChannel(server, attachment.channelId) { return true }
        if let thread = server.threads[attachment.channelId],
           !thread.archived,
           Self.isOrdinaryGuestChannel(server, thread.parentChannelId) {
            return true
        }
        return false
    }

    private func recordJoin(server: Server, userId: String, body: String) {
        guard server.countsEnabled, server.productAnalyticsEnabled else { return }
        guard let user = users[userId], user.shareUsageData == true, let analyticsId = user.analyticsId else { return }
        let anonymousId = PublicVisits.visitorId(PublicVisits.anonymousId(body))
        let hasVisitorId = anonymousId != nil && server.visitorIdEnabled
        let uuid = UUID().uuidString.lowercased()
        recorded.append(PublicVisitRow(
            event: "public_page_server_joined",
            visitor: "",
            serverId: server.id,
            source: "server",
            analyticsId: analyticsId,
            clientSessionId: nil,
            channelId: nil,
            hasVisitorId: hasVisitorId,
            uuid: uuid
        ))
        if hasVisitorId, let anonymousId {
            visitorRows.append(PublicVisitorRow(
                uuid: uuid,
                event: "public_page_server_joined",
                serverId: server.id,
                anonymousId: anonymousId
            ))
        }
    }

    private func bearerUserId(_ authorization: String?) -> String? {
        guard let authorization else { return nil }
        let prefix = "Bearer "
        guard authorization.hasPrefix(prefix) else { return nil }
        return tokens[String(authorization.dropFirst(prefix.count))]
    }

    private struct Server {
        var id: String
        var name: String
        var publiclyVisible: Bool
        var productAnalyticsEnabled: Bool
        var publicEnabled: Bool
        var countsEnabled: Bool
        var visitorIdEnabled: Bool
        var guestJoinEnabled: Bool
        var guestRolloutEnabled: Bool
        var translationEnabled: Bool
        var avatarUrl: String?
        var memberIds: Set<String>
        var guestChannelIds: Set<String>
        var guestChannelNames: [String: String]
        var channelTypes: [String: String]
        var threads: [String: Thread]
        var archivedChannelIds: Set<String>
        var mentionMembers: [MentionPerson]
        var mentionAgents: [MentionPerson]
        var memberRoles: [String: String]
        var agreement: StoredAgreement?
        var joinAudits: [JoinAudit]
    }

    private struct StoredAgreement {
        var id: String
        var title: String
        var bodyMarkdown: String
        var version: Int
        var enabled: Bool
    }

    private struct JoinAudit {
        var subjectId: String
        var source: String
        var agreementId: String
    }

    private static func agreementId(_ body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["agreementId"] as? String,
              !id.isEmpty
        else { return nil }
        return id
    }

    private static func agreementCard(_ agreement: StoredAgreement) -> PublicAgreementDTO {
        PublicAgreementDTO(id: agreement.id, version: agreement.version, title: agreement.title,
                           bodyMarkdown: agreement.bodyMarkdown)
    }

    private static func agreementRequired(_ agreement: StoredAgreement) -> PublicVisitError {
        .agreementRequired(agreementCard(agreement))
    }

    private static func agreementChanged(_ agreement: StoredAgreement) -> PublicVisitError {
        .agreementChanged(agreementCard(agreement))
    }

    private struct StoredAttachment {
        var channelId: String
        var messageId: String?
        var filename: String
        var mimeType: String
        var storageKey: String
    }

    private struct MentionPerson {
        var name: String
        var displayName: String
        var actorId: String
        var deleted: Bool
        var member: Bool
    }

    private static func isOrdinaryGuestChannel(_ server: Server, _ id: String) -> Bool {
        server.guestChannelIds.contains(id)
            && (server.channelTypes[id] ?? "channel") == "channel"
            && !server.archivedChannelIds.contains(id)
    }

    private struct Thread {
        var parentChannelId: String
        var archived: Bool
    }
}

public enum PublicVisits {
    struct RequestContext {
        var browser: String
        var browserVersion: Int?
        var os: String
        var deviceType: String
        var country: String?
    }

    /// Coarse browser, OS, device and country. The raw User-Agent is not returned.
    static func requestContext(userAgent: String?, country: String?) -> RequestContext {
        var browser = "other"
        var browserVersion: Int?
        var os = "other"
        var deviceType = "other"
        if let userAgent, !userAgent.isEmpty {
            let lower = userAgent.lowercased()
            if lower.contains("iphone") || lower.contains("ipad") || lower.contains("ipod") {
                os = "ios"
                deviceType = lower.contains("ipad") ? "tablet" : "mobile"
            } else if lower.contains("android") {
                os = "android"
                deviceType = lower.contains("mobile") ? "mobile" : "tablet"
            } else if lower.contains("cros") {
                os = "chromeos"
                deviceType = "desktop"
            } else if lower.contains("windows") {
                os = "windows"
                deviceType = "desktop"
            } else if lower.contains("mac os x") || lower.contains("macintosh") {
                os = "macos"
                deviceType = "desktop"
            } else if lower.contains("linux") {
                os = "linux"
                deviceType = "desktop"
            }
            if lower.contains("edg/") || lower.contains("edge/") {
                browser = "edge"
                browserVersion = majorVersion(userAgent, ["Edg/", "Edge/"])
            } else if lower.contains("opr/") || lower.contains("opera") {
                browser = "opera"
                browserVersion = majorVersion(userAgent, ["OPR/", "Opera/"])
            } else if lower.contains("samsungbrowser") {
                browser = "samsung_internet"
                browserVersion = majorVersion(userAgent, ["SamsungBrowser/"])
            } else if lower.contains("crios/") || lower.contains("chrome/") {
                browser = "chrome"
                browserVersion = majorVersion(userAgent, ["CriOS/", "Chrome/"])
            } else if lower.contains("fxios/") || lower.contains("firefox/") {
                browser = "firefox"
                browserVersion = majorVersion(userAgent, ["FxiOS/", "Firefox/"])
            } else if lower.contains("safari"), lower.contains("version/") {
                browser = "safari"
                browserVersion = majorVersion(userAgent, ["Version/"])
            }
            if browser == "other" { browserVersion = nil }
        }
        let storedCountry = country?.wholeMatch(of: /^[A-Z]{2}$/) == nil ? nil : country
        return RequestContext(
            browser: browser,
            browserVersion: browserVersion,
            os: os,
            deviceType: deviceType,
            country: storedCountry
        )
    }

    private static func majorVersion(_ userAgent: String, _ prefixes: [String]) -> Int? {
        for prefix in prefixes {
            guard let range = userAgent.range(of: prefix) else { continue }
            let digits = userAgent[range.upperBound...].prefix { $0.isNumber }
            if let value = Int(digits), value > 0, value < 1000 { return value }
        }
        return nil
    }

    static func anonymousId(_ body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["anonymous_id"] as? String
        else { return nil }
        return id
    }

    public static func authRequired(authorization: String?) -> PublicVisitError {
        .authentication(invalidToken: authorization?.hasPrefix("Bearer ") == true)
    }

    public static func reply() -> NoContentResponse { NoContentResponse() }

    public static func pageReply(
        found: Bool,
        mode: String?,
        channelIds: [String] = [],
        channelNames: [String: String] = [:],
        serverId: String = "",
        serverName: String = "",
        slug: String = "",
        avatarUrl: String? = nil,
        translationEnabled: Bool = false,
        canJoinAsGuest: Bool = false,
        translationAvailable: Bool = false
    ) throws -> PublicPageResponse {
        guard found else { throw PublicVisitError.notFound }
        return PublicPageResponse(
            serverId: serverId, serverName: serverName, slug: slug,
            avatarUrl: publicAvatar(avatarUrl, serverId: serverId), translationEnabled: translationEnabled,
            channels: channelIds.map { .init(id: $0, name: channelNames[$0] ?? $0) },
            canJoinAsGuest: canJoinAsGuest, translationAvailable: translationAvailable, visitorIdMode: mode
        )
    }

    static func publicAvatar(_ avatarUrl: String?, serverId: String) -> String? {
        guard let avatarUrl, !avatarUrl.isEmpty else { return nil }
        let pathname: String
        if avatarUrl.hasPrefix("/") {
            pathname = String(avatarUrl.split(separator: "?", maxSplits: 1)[0])
        } else if let url = URL(string: avatarUrl) {
            pathname = url.path
        } else {
            return nil
        }
        let scope = NSRegularExpression.escapedPattern(for: "server-\(serverId)")
        let pattern = "^/(?:api/)?avatars/\(scope)/[0-9a-fA-F]{32}\\.webp$"
        guard pathname.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return avatarUrl
    }

    /// Registrable domain under an ICANN suffix. A URL, IP, or unknown suffix is dropped.
    public static func referrerSite(_ host: String) -> String? {
        guard host.wholeMatch(of: /^(?=.{1,253}$)[a-z0-9-]+(?:\.[a-z0-9-]+)+$/) != nil else { return nil }
        guard host.wholeMatch(of: /^\d+(?:\.\d+){3}$/) == nil else { return nil }
        let labels = host.split(separator: ".").map(String.init)
        let suffixes: [[String]] = [
            ["co", "uk"],
            ["com"], ["co"], ["io"], ["site"], ["app"], ["uk"],
        ]
        for suffix in suffixes where labels.count > suffix.count && Array(labels.suffix(suffix.count)) == suffix {
            return labels[(labels.count - suffix.count - 1)...].joined(separator: ".")
        }
        return nil
    }

    fileprivate struct ParsedVisit {
        var uuid: String
        var event: String
        var channelId: String?
        var threadChannelId: String?
        var entry: String?
        var referrerDomain: String?
        var utmSource: String?
        var utmMedium: String?
        var utmCampaign: String?
        var anonymousId: String?
    }

    fileprivate struct KeptFields {
        var channelId: String?
        var threadChannelId: String?
        var entry: String?
        var referrerDomain: String?
        var utmSource: String?
        var utmMedium: String?
        var utmCampaign: String?
    }

    fileprivate static func kept(_ visit: ParsedVisit, channelId: String?, threadChannelId: String?) -> KeptFields {
        if visit.event == "public_page_viewed" {
            let referrer = visit.referrerDomain.flatMap(referrerSite)
            return KeptFields(
                channelId: nil,
                threadChannelId: nil,
                entry: visit.entry,
                referrerDomain: referrer.flatMap { hostname($0) ? $0 : nil },
                utmSource: campaignToken(visit.utmSource),
                utmMedium: campaignToken(visit.utmMedium),
                utmCampaign: campaignToken(visit.utmCampaign)
            )
        }
        return KeptFields(
            channelId: channelId,
            threadChannelId: visit.event == "public_page_thread_opened" ? threadChannelId : nil,
            entry: nil,
            referrerDomain: nil,
            utmSource: nil,
            utmMedium: nil,
            utmCampaign: nil
        )
    }

    private static func campaignToken(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 64,
              value.wholeMatch(of: /^[a-z0-9_-]+$/) != nil
        else { return nil }
        return value
    }

    private static func hostname(_ host: String) -> Bool {
        host.wholeMatch(of: /^(?=.{1,253}$)[a-z0-9-]+(?:\.[a-z0-9-]+)+$/) != nil
            && host.wholeMatch(of: /^\d+(?:\.\d+){3}$/) == nil
    }

    fileprivate static func parse(_ body: String) -> ParsedVisit? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let allowed: Set<String> = [
            "uuid", "event", "channel_id", "thread_channel_id", "entry",
            "referrer_domain", "utm_source", "utm_medium", "utm_campaign", "anonymous_id",
        ]
        guard Set(object.keys).isSubset(of: allowed) else { return nil }
        guard let uuid = object["uuid"] as? String, ServerScope.isUUID(uuid) else { return nil }
        guard let event = object["event"] as? String,
              ["public_page_viewed", "public_page_channel_opened", "public_page_thread_opened"].contains(event)
        else { return nil }
        if let channel = object["channel_id"] {
            guard let channel = channel as? String, ServerScope.isUUID(channel) else { return nil }
        }
        if let thread = object["thread_channel_id"] {
            guard let thread = thread as? String, ServerScope.isUUID(thread) else { return nil }
        }
        if let entry = object["entry"] {
            guard let entry = entry as? String, entry == "landing" || entry == "in_app" else { return nil }
        }
        if !bounded(object["referrer_domain"], 253) || !bounded(object["utm_source"], 64)
            || !bounded(object["utm_medium"], 64) || !bounded(object["utm_campaign"], 64)
            || !bounded(object["anonymous_id"], 64)
        {
            return nil
        }
        return ParsedVisit(
            uuid: uuid,
            event: event,
            channelId: object["channel_id"] as? String,
            threadChannelId: object["thread_channel_id"] as? String,
            entry: object["entry"] as? String,
            referrerDomain: object["referrer_domain"] as? String,
            utmSource: object["utm_source"] as? String,
            utmMedium: object["utm_medium"] as? String,
            utmCampaign: object["utm_campaign"] as? String,
            anonymousId: object["anonymous_id"] as? String
        )
    }

    fileprivate static func visitorId(_ value: String?) -> String? {
        guard let value else { return nil }
        let id = value.lowercased()
        return ServerScope.isUUID(id) ? id : nil
    }

    fileprivate static func utcDay(_ date: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        var calendarUTC = calendar
        calendarUTC.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = calendarUTC.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func bounded(_ value: Any?, _ max: Int) -> Bool {
        guard let value else { return true }
        guard let text = value as? String else { return false }
        return text.utf8.count <= max
    }
}

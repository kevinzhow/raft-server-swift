import Foundation

/// Read mutations, joint-invite accept, the channel list, profile completion
/// and the server create/details/analytics routes.
///
/// The service owns the orchestration and returns the published
/// `JSONBodyConvertible` DTOs; refusals are typed domain errors, including the
/// shared human admission before server creation.
/// It builds no HTTP reply, header set or response body. The conversation
/// read-all and the read-mutation admission are one store critical section
/// each (`MessagesAndThreadsStore`), and profile completion is one
/// `AuthProfileStore` critical section.
///
/// The human session lookup belongs to the unmigrated auth domain and enters as
/// a closure; the wiring lives in `DirectoryServiceAccessors.swift`.
public struct ManagedMCPLifecycleService: Sendable {
    private let sessionUserId: @Sendable (String?) -> String?
    private let oauth: OAuthLedger
    private let messages: MessagesAndThreadsStore
    private let channels: ServersAndChannelsStore
    private let profiles: AuthProfileStore
    private let now: @Sendable () -> Date

    init(
        sessionUserId: @escaping @Sendable (String?) -> String?,
        oauth: OAuthLedger,
        messages: MessagesAndThreadsStore,
        channels: ServersAndChannelsStore,
        profiles: AuthProfileStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.sessionUserId = sessionUserId
        self.oauth = oauth
        self.messages = messages
        self.channels = channels
        self.profiles = profiles
        self.now = now
    }

    private func requireUser(_ authorization: String?) throws -> String {
        guard let userId = sessionUserId(authorization) else {
            throw ManagedMCPLifecycleError.unauthorized
        }
        return userId
    }

    // MARK: - POST /api/channels/:id/conversation-read-all

    public func conversationReadAll(
        authorization: String?,
        serverId: String,
        channelId: String
    ) throws -> ConversationReadAllResponse {
        let userId = try requireUser(authorization)
        guard channels.sidebarReadAllEnabled else { throw ManagedMCPLifecycleError.notFound }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil,
              let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId
        else { throw ManagedMCPLifecycleError.channelNotFound }
        let hasAccess = channels.isPostableMember(channelId: channelId, userId: userId)
            || oauth.channelHumanIds(channelId: channelId).contains(userId)
            || oauth.channelType(id: channelId) == "channel"
        guard hasAccess else { throw ManagedMCPLifecycleError.channelNotFound }
        return ConversationReadAllResponse(
            serverId: serverId,
            scopes: messages.advanceConversationReadAll(userId: userId, channelId: channelId)
        )
    }

    // MARK: - POST /api/messages/read-mutations

    public func postReadMutation(
        authorization: String?,
        serverId: String,
        body: LenientJSONObjectRequest?
    ) throws -> ReadMutationResponse {
        let userId = try requireUser(authorization)
        guard let object = body,
              let mutationId = object["mutationId"]?.legacyString,
              ServerScope.isUUID(mutationId),
              mutationId != "00000000-0000-1000-8000-000000000000"
        else { throw ManagedMCPLifecycleError.invalidMutationId }
        guard let rawKind = object["kind"]?.legacyString else {
            throw ManagedMCPLifecycleError.invalidMutationPayload
        }
        let rawScope = object["scopeId"]?.legacyString.flatMap { ServerScope.isUUID($0) ? $0 : nil }
        let rawThrough = object["throughSeq"].flatMap(Self.numberOrString)
        let fingerprint = "\(rawKind):\(rawScope ?? ""):\(rawThrough ?? "")"
        let key = "\(serverId)\n\(userId)\n\(mutationId)"
        if let replay = messages.readMutationReplay(key: key, fingerprint: fingerprint, userId: userId) {
            return try Self.response(for: replay)
        }
        guard rawKind == "global_read_all" || rawKind == "channel_read_all" else {
            throw ManagedMCPLifecycleError.invalidMutationPayload
        }
        var scopeId: String?
        if rawKind == "channel_read_all" {
            guard let rawScope else { throw ManagedMCPLifecycleError.invalidMutationPayload }
            guard let channelType = oauth.channelType(id: rawScope), oauth.channelInfo(id: rawScope) != nil else {
                throw ManagedMCPLifecycleError.channelNotFound
            }
            let hasOwnedCursor = messages.hasUserReadCursor(userId: userId, scopeId: rawScope)
            let isMember = oauth.memberRole(serverId: serverId, userId: userId) != nil
            let visible = channels.isPostableMember(channelId: rawScope, userId: userId)
                || oauth.channelHumanIds(channelId: rawScope).contains(userId)
                || (channelType == "channel" && isMember)
                || (hasOwnedCursor && isMember)
            guard visible else { throw ManagedMCPLifecycleError.channelNotFound }
            scopeId = rawScope
        }
        let admission = messages.admitReadMutation(
            key: key,
            sequenceKey: "\(serverId)\n\(userId)",
            userId: userId,
            fingerprint: fingerprint
        ) { seq in
            ReadMutationRecord(
                mutationId: mutationId, serverId: serverId, principalId: userId,
                kind: rawKind, scopeId: scopeId, fingerprint: fingerprint,
                authoritySeq: seq, state: "admitted"
            )
        }
        switch admission {
        case .admitted(let seq):
            return .admitted(serverId: serverId, principalId: userId, authoritySeq: seq, mutationId: mutationId)
        case .replay(let replay):
            return try Self.response(for: replay)
        }
    }

    private static func response(for replay: ReadMutationReplay) throws -> ReadMutationResponse {
        switch replay {
        case .payloadMismatch:
            throw ManagedMCPLifecycleError.mutationPayloadMismatch
        case .alreadyTerminal(let scopeId, let cursor):
            return .alreadyTerminal(scopeId: scopeId, cursor: cursor)
        case .alreadyAdmitted:
            return .alreadyAdmitted
        }
    }

    /// The legacy `as? NSNumber` `.stringValue`, else `as? String`.
    private static func numberOrString(_ value: JSONScalarValue) -> String? {
        switch value {
        case .integer(let number): NSNumber(value: number).stringValue
        case .number(let number): NSNumber(value: number).stringValue
        case .bool(let flag): NSNumber(value: flag).stringValue
        case .string(let text): text
        case .null, .other: nil
        }
    }

    // MARK: - GET /api/messages/read-mutations/frontier

    public func readMutationFrontier(
        authorization: String?,
        scopeIds: String?
    ) throws -> ReadMutationFrontierResponse {
        let userId = try requireUser(authorization)
        let scopes = scopeIds.map { $0.split(separator: ",").map(String.init) }
        return ReadMutationFrontierResponse(
            snapshot: messages.readMutationFrontier(userId: userId, scopeIds: scopes)
        )
    }

    // MARK: - POST /api/channels/joint-invites/:id/accept

    public func acceptJointChannelInvite(
        authorization: String?,
        inviteId: String
    ) throws -> JointInviteAcceptedResponse {
        let userId = try requireUser(authorization)
        guard let invite = channels.jointInvite(id: inviteId) else {
            throw ManagedMCPLifecycleError.inviteNotFound
        }
        guard oauth.memberRole(serverId: invite.targetServerId, userId: userId) != nil else {
            throw ManagedMCPLifecycleError.notAMember
        }
        oauth.addChannelHuman(channelId: invite.targetChannelId, userId: userId)
        let name = channels.acceptJointInvite(id: inviteId, userId: userId) ?? ""
        return JointInviteAcceptedResponse(channelId: invite.targetChannelId, name: name)
    }

    // MARK: - GET /api/channels

    public func listChannels(
        authorization: String?,
        serverId: String,
        archived: String?
    ) throws -> ManagedMCPChannelListResponse {
        let userId = try requireUser(authorization)
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            throw ManagedMCPLifecycleError.notAMember
        }
        let facts = channels.channelListFacts()
        let includeArchived = archived == "include"
        let serverAdmin = role == "owner" || role == "admin"
        let rows = oauth.channelsForServer(serverId: serverId, userId: userId, includeArchived: includeArchived)
            .filter { includeArchived || oauth.channelArchivedAt(id: $0.id) == nil }
            .filter { role != "guest" || (facts.guestVisible[$0.id] ?? true) }
            .map { channel -> ManagedMCPChannelListResponse.Row in
                let displayPrefs = oauth.channelDisplayPrefs(channelId: channel.id, userId: userId)
                let localRole = facts.humanRoles["\(channel.id)\n\(userId)"]
                let capability = localRole == "admin" || serverAdmin
                let basis: String? = localRole == "admin" ? "channel_role" : (serverAdmin ? "server_role" : nil)
                return ManagedMCPChannelListResponse.Row(
                    id: channel.id,
                    name: channel.name,
                    type: channel.type,
                    joined: channel.joined,
                    archivedAt: oauth.channelArchivedAt(id: channel.id),
                    lastMessageAt: channel.lastMessageAt,
                    activityMuted: channel.activityMuted,
                    muteFromSeq: channel.muteFromSeq,
                    prefsVersion: channel.prefsVersion,
                    collapseLongMessages: displayPrefs.collapseLongMessages,
                    displayPrefsVersion: displayPrefs.prefsVersion,
                    channelRole: basis == nil ? "member" : "admin",
                    channelAdminBasis: basis,
                    capability: capability,
                    isJoint: facts.jointLocalChannelIds.contains(channel.id),
                    serverAdmin: serverAdmin
                )
            }
        return ManagedMCPChannelListResponse(rows: rows)
    }

    // MARK: - POST /api/auth/me/complete-profile

    public func completeProfile(
        authorization: String?,
        body: LenientJSONObjectRequest?
    ) throws -> ProfileCompletionResponse {
        let userId = try requireUser(authorization)
        guard let object = body,
              let rawName = object["name"]?.legacyString,
              let rawDisplay = object["displayName"]?.legacyString
        else { throw ManagedMCPLifecycleError.profileSetupInvalid }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = rawDisplay.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !displayName.isEmpty else {
            throw ManagedMCPLifecycleError.profileSetupInvalid
        }
        let lowered = name.lowercased()
        if lowered.hasPrefix("pending_") || AccountNaming.reservedAgentNames.contains(lowered) {
            throw ManagedMCPLifecycleError.profileSetupNameReserved
        }
        let completedAt = now()
        switch profiles.completeProfile(userId: userId, name: name, displayName: displayName, now: completedAt) {
        case .unknownAccount:
            throw ManagedMCPLifecycleError.unauthorized
        case .alreadyCompleted:
            throw ManagedMCPLifecycleError.profileSetupAlreadyCompleted
        case .nameTaken:
            throw ManagedMCPLifecycleError.profileSetupNameTaken
        case .replay(let account):
            return ProfileCompletionResponse(
                name: account.name,
                displayName: account.displayName ?? account.name,
                completedAt: account.profileSetupCompletedAt ?? completedAt,
                user: AuthUserDTO(account: account)
            )
        case .completed(let account):
            return ProfileCompletionResponse(
                name: name,
                displayName: displayName,
                completedAt: account.profileSetupCompletedAt ?? completedAt,
                user: AuthUserDTO(account: account)
            )
        }
    }

    // MARK: - POST /api/servers

    public func createServer(
        authorization: String?,
        body: LenientJSONObjectRequest?
    ) throws -> ServerCreatedResponse {
        let userId = try AuthCoreService(store: profiles, now: now)
            .admitHuman(authorization: authorization).userId
        guard let object = body,
              let rawName = object["name"]?.legacyString,
              let rawSlug = object["slug"]?.legacyString
        else { throw ManagedMCPLifecycleError.invalidServerRequest }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = rawSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !slug.isEmpty else { throw ManagedMCPLifecycleError.invalidServerRequest }
        if let existing = oauth.serverIdForSlug(slug) {
            if let profile = oauth.serverProfile(id: existing),
               let role = oauth.memberRole(serverId: existing, userId: userId) {
                return ServerCreatedResponse(id: profile.id, name: profile.name, slug: profile.slug, role: role)
            }
            throw ManagedMCPLifecycleError.slugTaken
        }
        guard slug.count >= 5 else { throw ManagedMCPLifecycleError.slugTooShort }
        let serverId = UUID().uuidString.lowercased()
        oauth.addOwnedServer(id: serverId, slug: slug, name: name, ownerId: userId)
        // The implicit public channel participates in this same creation UoW.
        if let allChannelId = oauth.allChannelId(serverId: serverId) {
            channels.insertOwnedChannel(channelId: allChannelId, serverId: serverId, userId: userId, name: "all")
        }
        return ServerCreatedResponse(id: serverId, name: name, slug: slug, role: "owner")
    }

    // MARK: - Product analytics settings

    public func serverProductAnalyticsSettings(
        authorization: String?,
        serverId: String
    ) throws -> ProductAnalyticsSettingsResponse {
        let userId = try requireUser(authorization)
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            throw ManagedMCPLifecycleError.notAMember
        }
        return ProductAnalyticsSettingsResponse(
            enabled: oauth.serverAnalyticsAllowed(id: serverId) ?? true,
            canManage: role == "owner" || role == "admin"
        )
    }

    public func patchServerProductAnalyticsSettings(
        authorization: String?,
        serverId: String,
        body: LenientJSONObjectRequest?
    ) throws -> ProductAnalyticsSettingsResponse {
        let userId = try requireUser(authorization)
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            throw ManagedMCPLifecycleError.notAMember
        }
        guard role == "owner" || role == "admin" else { throw ManagedMCPLifecycleError.forbidden }
        guard let enabled = body?["productAnalyticsEnabled"]?.legacyBool else {
            throw ManagedMCPLifecycleError.productAnalyticsNotBoolean
        }
        oauth.setServerProductAnalytics(id: serverId, enabled: enabled)
        return ProductAnalyticsSettingsResponse(enabled: enabled, canManage: true)
    }

    // MARK: - GET /api/servers/:id

    public func serverDetails(authorization: String?, serverId: String) throws -> ServerDetailsResponse {
        let userId = try requireUser(authorization)
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            throw ManagedMCPLifecycleError.notAMember
        }
        guard let profile = oauth.serverProfile(id: serverId) else {
            throw ManagedMCPLifecycleError.serverNotFound
        }
        if role == "guest" {
            return .guest(id: profile.id, name: profile.name, slug: profile.slug)
        }
        return .member(profile)
    }
}

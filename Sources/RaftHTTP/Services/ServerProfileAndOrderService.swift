import Foundation

/// Server profile, switcher order, pre-join agreement, translation settings,
/// the member directory, scope attestations and the shared-artifact pages.
///
/// The service owns the orchestration and returns published `JSONBodyConvertible`
/// DTOs; every refusal is a `ServerProfileAndOrderError`. It builds no HTTP
/// reply, header set or JSON text. The switcher-order read and write are one
/// store critical section each, so two concurrent patches cannot both accept the
/// same stored version; the translation, attestation and share operations live
/// in `ServerProfileAndOrder{Translation,Attestation}.swift` as extensions of
/// this type.
public struct ServerProfileAndOrderService: Sendable {
    let dependencies: ServerProfileAndOrderDependencies

    /// Production wiring.
    public init(directory: EmailLoginDirectory) {
        self.init(dependencies: .live(directory: directory))
    }

    init(dependencies: ServerProfileAndOrderDependencies) {
        self.dependencies = dependencies
    }

    // MARK: - Session helpers

    /// The plain `{"error":"Unauthorized"}` refusal the profile routes use.
    func requireUser(_ authorization: String?) throws -> String {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw ServerProfileAndOrderError.unauthorized
        }
        return userId
    }

    /// The `auth_required` refusal the order and member-directory routes use.
    func requireUserWithCode(_ authorization: String?) throws -> String {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw ServerProfileAndOrderError.authRequired(
                bearerPresent: authorization?.hasPrefix("Bearer ") == true
            )
        }
        return userId
    }

    /// The caller's role in the server, or the published 403.
    func requireRole(serverId: String, userId: String) throws -> String {
        guard let role = dependencies.oauth.memberRole(serverId: serverId, userId: userId) else {
            throw ServerProfileAndOrderError.notAMember
        }
        return role
    }

    // MARK: - GET /share/:id and GET /share/:id.png

    private static func isArtifactId(_ id: String) -> Bool {
        id.wholeMatch(of: /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) != nil
    }

    /// The public page for one uploaded share artifact. The page carries the
    /// canonical OG metadata for the configured share host and image host; a
    /// malformed or unknown id is nil (the route answers its plain 404).
    public func shareArtifactPage(
        id: String,
        serverBase: String,
        shareBase: String,
        cdnBase: String?
    ) -> ShareArtifactPageOutput? {
        guard Self.isArtifactId(id) else { return nil }
        guard let artifact = dependencies.messages.shareArtifact(id: id.lowercased()) else { return nil }
        let shareURL = ShareArtifactURL.share(id: id, shareBase: shareBase)
        let imageURL = ShareArtifactURL.image(
            id: id,
            serverId: artifact.serverId,
            serverBase: serverBase,
            cdnBase: cdnBase
        )
        let title = "Slock conversation screenshot"
        let description = "A conversation screenshot shared from Slock."
        let html = """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(Self.escapeHTML(title))</title>
          <meta name="robots" content="noindex, nofollow">
          <meta property="og:type" content="article">
          <meta property="og:title" content="\(Self.escapeHTML(title))">
          <meta property="og:description" content="\(Self.escapeHTML(description))">
          <meta property="og:url" content="\(Self.escapeHTML(shareURL))">
          <meta property="og:image" content="\(Self.escapeHTML(imageURL))">
          <meta property="og:image:secure_url" content="\(Self.escapeHTML(imageURL))">
          <meta property="og:image:type" content="image/png">
          <meta property="og:image:width" content="\(artifact.width)">
          <meta property="og:image:height" content="\(artifact.height)">
          <meta name="twitter:card" content="summary_large_image">
          <meta name="twitter:title" content="\(Self.escapeHTML(title))">
          <meta name="twitter:description" content="\(Self.escapeHTML(description))">
          <meta name="twitter:image" content="\(Self.escapeHTML(imageURL))">
          <meta name="twitter:image:alt" content="\(Self.escapeHTML(title))">
          <style>
            body { margin: 0; font-family: ui-sans-serif, system-ui, sans-serif; background: #fffdf4; color: #111; }
            main { min-height: 100vh; display: grid; place-items: center; padding: 24px; box-sizing: border-box; }
            .share-card { width: min(100%, 960px); margin-inline: auto; }
            img { display: block; width: 100%; height: auto; border: 2px solid #111; box-shadow: 4px 4px 0 #111; background: #fff; box-sizing: border-box; }
            p { font-size: 13px; color: rgba(0,0,0,.6); margin-top: 16px; }
          </style>
        </head>
        <body>
          <main>
            <div class="share-card">
              <img src="\(Self.escapeHTML(imageURL))" alt="\(Self.escapeHTML(title))">
              <p>Shared from Slock.</p>
            </div>
          </main>
        </body>
        </html>
        """
        return ShareArtifactPageOutput(html: html)
    }

    /// The uploaded bytes for `GET /share/:id.png`; nil for a malformed or
    /// unknown id.
    public func shareArtifactImage(id: String) -> ShareArtifactImageOutput? {
        guard Self.isArtifactId(id) else { return nil }
        guard let artifact = dependencies.messages.shareArtifact(id: id.lowercased()) else { return nil }
        return ShareArtifactImageOutput(bytes: artifact.bytes, width: artifact.width, height: artifact.height)
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    // MARK: - GET /api/servers/unread-summary

    public func serversUnreadSummary(authorization: String?) throws -> ServerUnreadSummaryResponse {
        let userId = try requireUser(authorization)
        let oauth = dependencies.oauth
        let entries = oauth.serverIdsForMember(userId: userId).map { serverId in
            let joined = oauth.channelsForServer(serverId: serverId, userId: userId).filter {
                $0.joined && ($0.type == "channel" || $0.type == "")
            }
            let total = joined.reduce(0) { sum, channel in
                sum + oauth.channelUnreadInfo(channelId: channel.id, userId: userId).unreadCount
            }
            return ServerUnreadSummaryEntry(
                serverId: serverId,
                unreadCount: total,
                serverPushMuted: oauth.isServerPushMuted(serverId: serverId, userId: userId)
            )
        }
        return ServerUnreadSummaryResponse(entries: entries)
    }

    // MARK: - Server switcher order

    /// `GET /api/servers/order`.
    public func serverOrder(authorization: String?) throws -> ServerOrderResponse {
        let userId = try requireUserWithCode(authorization)
        let oauth = dependencies.oauth
        let snapshot = dependencies.channels.serverOrder(
            userId: userId,
            memberIds: { oauth.serverIdsForMember(userId: userId) }
        )
        return ServerOrderResponse(serverOrder: snapshot.ids, serverOrderVersion: snapshot.version)
    }

    /// `PATCH /api/servers/order`. A body that does not carry a string array
    /// `serverOrder` is the published 400; the sanitizing, the version bump and
    /// the store are one store critical section.
    public func patchServerOrder(
        authorization: String?,
        body: ServerOrderPatchDTO?
    ) throws -> ServerOrderResponse {
        let userId = try requireUserWithCode(authorization)
        guard let requested = body?.serverOrder else {
            throw ServerProfileAndOrderError.invalidServerOrder
        }
        let oauth = dependencies.oauth
        let result = dependencies.channels.updateServerOrder(
            userId: userId,
            requested: requested,
            memberIds: { oauth.serverIdsForMember(userId: userId) }
        )
        return ServerOrderResponse(serverOrder: result.ids, serverOrderVersion: result.version)
    }

    /// `GET /api/servers` for a caller with at least one membership. A caller
    /// without a session or without memberships is nil, and the route keeps its
    /// existing public-server fallback.
    public func orderedServerList(authorization: String?) -> OrderedServerListResponse? {
        guard let userId = dependencies.sessionUserId(authorization) else { return nil }
        let oauth = dependencies.oauth
        guard !oauth.serverIdsForMember(userId: userId).isEmpty else { return nil }
        let snapshot = dependencies.channels.serverOrder(
            userId: userId,
            memberIds: { oauth.serverIdsForMember(userId: userId) }
        )
        let rows = snapshot.ids.compactMap { serverId -> OrderedServerListEntry? in
            guard let details = oauth.serverDetailsValue(id: serverId) else { return nil }
            return OrderedServerListEntry(
                id: serverId,
                slug: details.slug,
                role: oauth.memberRole(serverId: serverId, userId: userId) ?? "member",
                serverOrderVersion: snapshot.version
            )
        }
        return OrderedServerListResponse(servers: rows)
    }

    // MARK: - GET /api/servers/:id/apps

    public func serverApps(authorization: String?, serverId: String) throws -> ServerAppsResponse {
        let userId = try requireUserWithCode(authorization)
        _ = try requireRole(serverId: serverId, userId: userId)
        guard dependencies.channels.isComposerResourceEnabled(serverId: serverId) else {
            throw ServerProfileAndOrderError.notFound
        }
        return ServerAppsResponse(apps: [
            ServerAppsResponse.App(appId: "system.cleaner", displayName: "Memory Cleaner"),
            ServerAppsResponse.App(appId: "system.reminder", displayName: "Reminder"),
        ])
    }

    // MARK: - Pre-join agreement

    /// `PUT /api/servers/:id/agreement`. An owner or admin writes a new active
    /// agreement, or disables the active one when `enabled` is false.
    public func putServerAgreement(
        authorization: String?,
        serverId: String,
        body: ServerAgreementPutRequest?
    ) throws -> ServerAgreementResponse {
        let userId = try requireUser(authorization)
        let role = try requireRole(serverId: serverId, userId: userId)
        guard role == "owner" || role == "admin" else {
            throw ServerProfileAndOrderError.agreementManageForbidden
        }
        guard let enabled = body?.enabled,
              let title = body?.title,
              let bodyMarkdown = body?.bodyMarkdown
        else {
            throw ServerProfileAndOrderError.invalidAgreementRequest
        }
        guard bodyMarkdown.count <= 5000 else {
            throw ServerProfileAndOrderError.agreementTooLong
        }
        guard enabled else {
            return ServerAgreementResponse(agreement: nil)
        }
        let agreement = dependencies.oauth.putServerAgreement(
            serverId: serverId,
            title: title,
            bodyMarkdown: bodyMarkdown
        )
        return ServerAgreementResponse(agreement: ServerAgreementDTO(agreement))
    }

    /// `GET /api/servers/:id/agreement`.
    public func getServerAgreement(
        authorization: String?,
        serverId: String
    ) throws -> ServerAgreementResponse {
        let userId = try requireUser(authorization)
        _ = try requireRole(serverId: serverId, userId: userId)
        return ServerAgreementResponse(
            agreement: dependencies.oauth.activeServerAgreement(serverId: serverId).map(ServerAgreementDTO.init)
        )
    }

    // MARK: - PATCH /api/servers/:id

    /// Renames the server and/or flips the human-directory flag. The body must
    /// be a JSON object; a present `name` must be a non-blank string and a
    /// present `hideHumansFromMembers` must read as a boolean.
    public func patchServerProfile(
        authorization: String?,
        serverId: String,
        body: ServerProfilePatchRequest?
    ) throws -> ServerProfilePatchResponse {
        let userId = try requireUser(authorization)
        let role = try requireRole(serverId: serverId, userId: userId)
        guard role == "owner" || role == "admin" else {
            throw ServerProfileAndOrderError.forbidden
        }
        guard let body, let profile = dependencies.oauth.serverProfile(id: serverId) else {
            throw ServerProfileAndOrderError.invalidServerUpdate
        }
        var name = profile.name
        switch body.name {
        case .absent:
            break
        case .invalid:
            throw ServerProfileAndOrderError.serverNameRequired
        case .value(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw ServerProfileAndOrderError.serverNameRequired
            }
            name = trimmed
        }
        var hidden: Bool?
        switch body.hideHumansFromMembers {
        case .absent:
            break
        case .invalid:
            throw ServerProfileAndOrderError.hideHumansNotBoolean
        case .value(let value):
            hidden = value
        }
        dependencies.oauth.updateServer(id: serverId, name: name, avatarUrl: profile.avatarUrl)
        let hiddenValue = dependencies.channels.updateHideHumans(serverId: serverId, hidden: hidden)
        return ServerProfilePatchResponse(
            id: serverId,
            name: name,
            slug: profile.slug,
            avatarUrl: profile.avatarUrl,
            hideHumansFromMembers: hiddenValue
        )
    }

    // MARK: - POST /api/servers/:id/avatar

    public func uploadServerAvatar(
        authorization: String?,
        serverId: String
    ) throws -> ServerAvatarUploadResponse {
        let userId = try requireUserWithCode(authorization)
        let role = try requireRole(serverId: serverId, userId: userId)
        guard role == "owner" || role == "admin" else {
            throw ServerProfileAndOrderError.forbidden
        }
        let key = dependencies.makeUUID().replacingOccurrences(of: "-", with: "")
        let avatarUrl = "/api/avatars/server-\(serverId)/\(key).webp"
        dependencies.oauth.setServerAvatar(id: serverId, avatarUrl: avatarUrl)
        return ServerAvatarUploadResponse(avatarUrl: avatarUrl)
    }

    // MARK: - Member directory

    /// `GET /api/servers/:id/members/:memberId/profile`.
    public func memberProfile(
        authorization: String?,
        serverId: String,
        memberId: String
    ) throws -> ServerMemberProfileResponse {
        let userId = try requireUserWithCode(authorization)
        let role = try requireRole(serverId: serverId, userId: userId)
        let oauth = dependencies.oauth
        let targetRole = oauth.memberRole(serverId: serverId, userId: memberId)
        if targetRole == nil {
            let removed = dependencies.channels.isMemberRemoved(serverId: serverId, userId: memberId)
            let account = dependencies.profiles.account(userId: memberId)
            let canSee = role == "owner" || role == "admin" || memberId == userId
            guard removed, canSee, let account else {
                throw ServerProfileAndOrderError.userNotFound
            }
            return .removed(
                userId: memberId,
                name: account.name,
                email: account.email,
                avatarUrl: account.avatarUrl
            )
        }
        let hiddenDirectory = dependencies.channels.hideHumans(serverId: serverId)
        let targetAccount = dependencies.profiles.account(userId: memberId)
        let isAdmin = role == "owner" || role == "admin"
        if hiddenDirectory, !isAdmin, memberId != userId {
            let contextual = oauth.channelsForServer(serverId: serverId, userId: userId)
                .contains { channel in
                    channel.type == "channel"
                        && oauth.channelArchivedAt(id: channel.id) == nil
                        && oauth.isChannelParticipant(channelId: channel.id, userId: userId)
                        && oauth.isChannelParticipant(channelId: channel.id, userId: memberId)
                }
            guard contextual else {
                throw ServerProfileAndOrderError.userNotFound
            }
        }
        let email: String? = (isAdmin || memberId == userId) ? targetAccount?.email : nil
        let createdAgents = oauth.serverAgents(serverId: serverId)
            .filter { !$0.deleted && $0.creatorUserId == memberId }
            .map {
                ServerMemberProfileResponse.CreatedAgent(id: $0.id, name: $0.name, displayName: $0.displayName)
            }
        return .current(
            userId: memberId,
            name: targetAccount?.name ?? "",
            email: email,
            avatarUrl: targetAccount?.avatarUrl,
            createdAgents: createdAgents
        )
    }

    /// `GET /api/servers/:id/members`.
    public func serverMembersList(
        authorization: String?,
        serverId: String
    ) throws -> ServerMembersListResponse {
        let userId = try requireUserWithCode(authorization)
        let role = try requireRole(serverId: serverId, userId: userId)
        let canSeeAllEmails = role == "owner" || role == "admin"
        let hiddenDirectory = dependencies.channels.hideHumans(serverId: serverId)
        var members = dependencies.oauth.memberIdsWithRoles(serverId: serverId)
        if hiddenDirectory, role != "owner", role != "admin" {
            members = members.filter { $0.id == userId }
        }
        let rows = members.map { member -> ServerMemberListEntry in
            let account = dependencies.profiles.account(userId: member.id)
            let email: String? = (canSeeAllEmails || member.id == userId) ? account?.email : nil
            return ServerMemberListEntry(
                userId: member.id,
                role: member.role,
                name: account?.name ?? "",
                email: email,
                avatarUrl: account?.avatarUrl
            )
        }
        return ServerMembersListResponse(members: rows)
    }

    /// `GET /api/servers/:id/member-graph`.
    public func serverMemberGraph(
        authorization: String?,
        serverId: String
    ) throws -> ServerMemberGraphResponse {
        let userId = try requireUserWithCode(authorization)
        let role = try requireRole(serverId: serverId, userId: userId)
        let oauth = dependencies.oauth
        if dependencies.channels.hideHumans(serverId: serverId), role != "owner", role != "admin" {
            throw ServerProfileAndOrderError.memberGraphUnavailable
        }
        let memberIds = oauth.memberIds(serverId: serverId)
        let agentIds = oauth.activeAgentIds(serverId: serverId)
        var channels: [(id: String, name: String, humans: [String], agents: [String])] = []
        if let allChannelId = oauth.allChannelId(serverId: serverId) {
            channels.append((allChannelId, "all", memberIds, agentIds))
        }
        for channel in oauth.channelsForServer(serverId: serverId, userId: userId) {
            guard channel.type == "channel", channel.name != "all",
                  oauth.channelArchivedAt(id: channel.id) == nil
            else { continue }
            let humans = oauth.channelHumanIds(channelId: channel.id).filter { memberIds.contains($0) }
            let agents = oauth.channelAgentIds(channelId: channel.id).filter { agentIds.contains($0) }
            channels.append((channel.id, channel.name, humans, agents))
        }
        var edges: [ServerMemberGraphResponse.Edge] = []
        var humanChannelIds: [String: [String]] = [:]
        var agentChannelIds: [String: [String]] = [:]
        var channelRows: [ServerMemberGraphResponse.Channel] = []
        for channel in channels {
            for human in channel.humans {
                humanChannelIds[human, default: []].append(channel.id)
                edges.append(.init(channelId: channel.id, memberType: "human", memberId: human))
            }
            for agent in channel.agents {
                agentChannelIds[agent, default: []].append(channel.id)
                edges.append(.init(channelId: channel.id, memberType: "agent", memberId: agent))
            }
            channelRows.append(.init(
                id: channel.id,
                name: channel.name,
                memberCount: channel.humans.count + channel.agents.count
            ))
        }
        let humans = memberIds.map {
            ServerMemberGraphResponse.Human(id: $0, channelIds: humanChannelIds[$0] ?? [])
        }
        let agents = agentIds.map { agentId in
            ServerMemberGraphResponse.Agent(
                id: agentId,
                name: oauth.agentRuntimeInfo(id: agentId)?.name ?? "",
                channelIds: agentChannelIds[agentId] ?? []
            )
        }
        return ServerMemberGraphResponse(humans: humans, agents: agents, channels: channelRows, edges: edges)
    }
}

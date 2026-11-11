import Foundation
import RaftShared

/// Exact ordered success body used by the App-management routes. The legacy
/// handlers returned rows straight from the service layer, so their member order
/// is the column order of the row they read; the service builds that order once.
public struct OrderedBodyDTO: JSONBodyConvertible {
    public var jsonBody: OrderedJSON

    public init(_ jsonBody: OrderedJSON) {
        self.jsonBody = jsonBody
    }
}

/// A refusal of the App-management surface. Every case is one published
/// `(status, body)` pair. `serverFailure` carries the correlation id that the
/// generic upstream route error puts in the body and the `X-Slock-Error-Id`
/// header.
public enum IntegrationAppManagementError: DomainError, Equatable {
    case unauthorized
    case notAMember
    case forbidden(String)
    case notFound(String)
    case badRequest(String)
    case conflict(String)
    case serverFailure(correlationId: String)

    public var status: UInt {
        switch self {
        case .unauthorized: 401
        case .notAMember, .forbidden: 403
        case .notFound: 404
        case .badRequest: 400
        case .conflict: 409
        case .serverFailure: 500
        }
    }

    public var errorMessage: String {
        switch self {
        case .unauthorized: "Unauthorized"
        case .notAMember: "Not a member of this server"
        case .forbidden(let message), .notFound(let message), .badRequest(let message),
             .conflict(let message):
            message
        case .serverFailure:
            "Failed to upload OAuth client logo"
        }
    }

    public var errorBody: OrderedJSON? {
        switch self {
        case .serverFailure(let correlationId):
            .object([
                OrderedJSONField("error", .string("Failed to upload OAuth client logo")),
                OrderedJSONField("correlationId", .string(correlationId)),
            ])
        default:
            nil
        }
    }

    public var responseHeaders: [String: String] {
        switch self {
        case .serverFailure(let correlationId):
            ["X-Slock-Error-Id": correlationId]
        default:
            [:]
        }
    }
}

/// The developer-platform App-management surface: client CRUD, the private
/// share link and its public invite, App Notifications permissions/webhook,
/// Marketplace installation grants, the integrations overview and request deny.
///
/// All state lives in the OAuth ledger; the service validates the published
/// input shape, maps refusals, and builds the ordered row projections. Secret
/// material is returned exactly once, by the same response that creates or
/// rotates it.
public struct IntegrationAppManagementService: Sendable {
    static let categories = [
        "AI & Automation", "Communication", "Productivity & Collaboration",
        "Developer Tools", "Data & Analytics", "Business Ops", "Infrastructure",
        "Content & Creative", "Other",
    ]
    static let groups = ["server", "agent", "channel", "computer", "agent_reminder_write"]
    static let eventGroups: [String: [String]] = [
        "server.member_added": ["server"],
        "server.member_removed": ["server"],
        "server.member_role_changed": ["server"],
        "server.config_updated": ["server"],
        "server.public_channel_created": ["server", "channel"],
        "server.public_channel_archived": ["server", "channel"],
        "server.plan_changed": ["server"],
        "agent.status_changed": ["agent"],
        "agent.profile_updated": ["agent"],
        "agent.runtime_changed": ["agent"],
        "agent.model_changed": ["agent"],
        "channel.member_added": ["channel"],
        "channel.member_removed": ["channel"],
        "channel.config_updated": ["channel"],
        "channel.archived": ["channel"],
        "thread.created": ["channel"],
        "thread.resolved": ["channel"],
        "computer.online": ["computer"],
        "computer.offline": ["computer"],
        "computer.version_changed": ["computer"],
        "computer.agent_started": ["computer", "agent"],
        "computer.agent_stopped": ["computer", "agent"],
    ]
    static let scopes = [
        "openid", "profile", "email", "identity", "agent:read", "agent:event:write",
        "agent:notification:write", "agent:action_request:write",
    ]

    private let oauth: OAuthLedger
    private let sessionUserId: @Sendable (String?) -> String?
    private let userDisplayName: @Sendable (String) -> String?
    private let environment: [String: String]
    private let now: @Sendable () -> Date

    public init(
        oauth: OAuthLedger,
        sessionUserId: @escaping @Sendable (String?) -> String?,
        userDisplayName: @escaping @Sendable (String) -> String? = { _ in nil },
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.oauth = oauth
        self.sessionUserId = sessionUserId
        self.userDisplayName = userDisplayName
        self.environment = environment
        self.now = now
    }

    // MARK: - Shared gates

    private func requireUser(_ authorization: String?) throws -> String {
        guard let userId = sessionUserId(authorization) else {
            throw IntegrationAppManagementError.unauthorized
        }
        return userId
    }

    private func requireAppId(_ clientId: String) throws {
        guard ServerScope.isUUID(clientId) else {
            throw IntegrationAppManagementError.notFound("App not found")
        }
    }

    private func requireRequestId(_ requestId: String) throws {
        guard ServerScope.isUUID(requestId) else {
            throw IntegrationAppManagementError.notFound("Access request not found")
        }
    }

    private func requireManager(_ authorization: String?, serverId: String, message: String) throws -> String {
        let userId = try requireUser(authorization)
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            throw IntegrationAppManagementError.notAMember
        }
        guard role == "owner" || role == "admin" else {
            throw IntegrationAppManagementError.forbidden(message)
        }
        return userId
    }

    private func requireOwnedClient(serverId: String, recordId: String) throws -> OAuthLedger.Client {
        guard oauth.sourceOwnedClient(serverId: serverId, recordId: recordId) != nil else {
            throw IntegrationAppManagementError.notFound("OAuth client not found")
        }
        return oauth.sourceOwnedClient(serverId: serverId, recordId: recordId)!
    }

    // MARK: - Projections

    static func iso(_ date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func clientJSON(_ client: OAuthLedger.Client) -> OrderedJSON {
        var body = OrderedJSONObject()
        body.append("id", client.id)
        body.append("serverId", client.serverId)
        body.append("clientId", client.clientId)
        body.append("appType", client.appType)
        body.append("publishStatus", client.publishStatus)
        body.append("category", client.category)
        body.append("dataAccessSummary", optional: client.dataAccessSummary)
        body.append("publishRejectionReason", optional: client.publishRejectionReason)
        body.append("name", client.name)
        body.append("description", optional: client.descriptionText)
        body.append("whenToUse", optional: client.whenToUse)
        body.append("homepageUrl", optional: client.homepageUrl)
        body.append("returnUrl", optional: client.returnUrl)
        body.append("agentManifestUrl", optional: client.agentManifestUrl)
        body.append("setupUrl", optional: client.setupUrl)
        body.append("setupDescription", optional: client.setupDescription)
        body.append("setupRevision", client.setupRevision)
        body.append("allowedScopes", client.allowedScopes.map { .array($0.map(OrderedJSON.string)) } ?? .null)
        body.append("logoUrl", optional: client.logoUrl)
        body.append("humanMarketplaceVisible", client.humanMarketplaceVisible)
        body.append("createdByUserId", client.createdByUserId)
        body.append("createdAt", .string(Self.iso(client.createdAt) ?? ""))
        body.append("updatedAt", .string(Self.iso(client.updatedAt) ?? ""))
        return body.json
    }

    private func linkJSON(_ link: OAuthLedger.ClientShareLink) -> OrderedJSON {
        var body = OrderedJSONObject()
        body.append("id", link.id)
        body.append("clientId", link.clientRecordId)
        body.append("expiresAt", optional: Self.iso(link.expiresAt))
        body.append("revokedAt", optional: Self.iso(link.revokedAt))
        body.append("lastUsedAt", optional: Self.iso(link.lastUsedAt))
        body.append("createdAt", .string(Self.iso(link.createdAt) ?? ""))
        body.append("updatedAt", .string(Self.iso(link.updatedAt) ?? ""))
        return body.json
    }

    // MARK: - Clients

    public func createClient(
        authorization: String?, serverId: String, body: IntegrationRequestBody?
    ) throws -> OrderedBodyDTO {
        let userId = try requireManager(
            authorization, serverId: serverId,
            message: "Only server owners and admins can manage integrations"
        )
        guard let body else {
            throw IntegrationAppManagementError.badRequest("Invalid request body")
        }
        let name = body.string("name") ?? ""
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IntegrationAppManagementError.badRequest("name is required")
        }
        let clientKey = body.string("clientId")
        if let clientKey, !clientKey.isEmpty,
           oauth.clientRecordId(serverId: serverId, clientKey: clientKey.lowercased()) != nil {
            throw IntegrationAppManagementError.conflict("Client ID is already taken")
        }
        let allowedScopes = try scopesValue(body.value("allowedScopes"))
        let category = try categoryValue(body.value("category"))
        let whenToUse: String?
        do { whenToUse = try Self.normalizeWhenToUse(body.string("whenToUse")) }
        catch let error as OAuthClientRejection { throw IntegrationAppManagementError.badRequest(error.message) }
        do {
            let (client, secret) = try oauth.createManagedClient(
                serverId: serverId,
                createdByUserId: userId,
                name: name,
                description: body.string("description"),
                whenToUse: whenToUse,
                homepageUrl: body.string("homepageUrl"),
                returnUrl: body.string("returnUrl"),
                agentManifestUrl: body.string("agentManifestUrl"),
                setupUrl: body.string("setupUrl"),
                setupDescription: body.string("setupDescription"),
                clientKey: clientKey,
                allowedScopes: allowedScopes,
                category: category
            )
            return OrderedBodyDTO(.object([
                OrderedJSONField("client", clientJSON(client)),
                OrderedJSONField("clientSecret", .string(secret)),
            ]))
        } catch let error as OAuthClientRejection {
            throw IntegrationAppManagementError.badRequest(error.message)
        }
    }

    public func deleteClient(
        authorization: String?, serverId: String, clientId: String
    ) throws -> OrderedBodyDTO {
        try requireAppId(clientId)
        _ = try requireManager(
            authorization, serverId: serverId,
            message: "Only server owners and admins can manage integrations"
        )
        guard let deleted = oauth.deleteManagedClient(serverId: serverId, recordId: clientId) else {
            throw IntegrationAppManagementError.notFound("OAuth client not found")
        }
        return OrderedBodyDTO(clientJSON(deleted))
    }

    public func regenerateSecret(
        authorization: String?, serverId: String, clientId: String
    ) throws -> OrderedBodyDTO {
        try requireAppId(clientId)
        _ = try requireManager(
            authorization, serverId: serverId,
            message: "Only server owners and admins can manage integrations"
        )
        guard let (client, secret) = oauth.regenerateManagedSecret(serverId: serverId, recordId: clientId) else {
            throw IntegrationAppManagementError.notFound("OAuth client not found")
        }
        return OrderedBodyDTO(.object([
            OrderedJSONField("client", clientJSON(client)),
            OrderedJSONField("clientSecret", .string(secret)),
        ]))
    }

    public func requestPublish(
        authorization: String?, serverId: String, clientId: String
    ) throws -> OrderedBodyDTO {
        try requireAppId(clientId)
        _ = try requireManager(
            authorization, serverId: serverId,
            message: "Only server owners and admins can manage integrations"
        )
        do {
            guard let client = try oauth.requestManagedPublish(serverId: serverId, recordId: clientId) else {
                throw IntegrationAppManagementError.notFound("OAuth client not found")
            }
            return OrderedBodyDTO(clientJSON(client))
        } catch let error as OAuthClientRejection {
            throw IntegrationAppManagementError.badRequest(error.message)
        }
    }

    public func requestUnpublish(
        authorization: String?, serverId: String, clientId: String
    ) throws -> OrderedBodyDTO {
        try requireAppId(clientId)
        _ = try requireManager(
            authorization, serverId: serverId,
            message: "Only server owners and admins can manage integrations"
        )
        guard let client = oauth.requestManagedUnpublish(serverId: serverId, recordId: clientId) else {
            throw IntegrationAppManagementError.notFound("Published marketplace app not found")
        }
        return OrderedBodyDTO(clientJSON(client))
    }

    // MARK: - Share links and invites

    public func getShareLink(
        authorization: String?, serverId: String, clientId: String
    ) throws -> OrderedBodyDTO {
        try requireAppId(clientId)
        // The legacy guard answered a well-formed but unknown id with the
        // share-link 404 before any authorization lookup.
        guard let link = oauth.shareLinkActive(serverId: serverId, recordId: clientId) else {
            throw IntegrationAppManagementError.notFound("OAuth client share link not found")
        }
        _ = try requireManager(
            authorization, serverId: serverId,
            message: "Only server owners and admins can manage integrations"
        )
        return OrderedBodyDTO(linkJSON(link))
    }

    public func createShareLink(
        authorization: String?, serverId: String, clientId: String, body: IntegrationRequestBody?
    ) throws -> OrderedBodyDTO {
        try requireAppId(clientId)
        let userId = try requireManager(
            authorization, serverId: serverId,
            message: "Only server owners and admins can manage integrations"
        )
        guard let created = oauth.createManagedShareLink(
            serverId: serverId, recordId: clientId, createdByUserId: userId,
            expiresInDays: body?.int("expiresInDays")
        ) else {
            throw IntegrationAppManagementError.notFound("OAuth client not found")
        }
        return OrderedBodyDTO(.object([
            OrderedJSONField("client", clientJSON(created.client)),
            OrderedJSONField("link", linkJSON(created.link)),
            OrderedJSONField("token", .string(created.token)),
        ]))
    }

    public func revokeShareLink(
        authorization: String?, serverId: String, clientId: String
    ) throws -> OrderedBodyDTO {
        try requireAppId(clientId)
        _ = try requireManager(
            authorization, serverId: serverId,
            message: "Only server owners and admins can manage integrations"
        )
        guard let link = oauth.revokeManagedShareLink(serverId: serverId, recordId: clientId) else {
            throw IntegrationAppManagementError.notFound("OAuth client share link not found")
        }
        return OrderedBodyDTO(linkJSON(link))
    }

    private func inviteJSON(_ invite: OAuthLedger.ManagedShareInvite) -> OrderedJSON {
        var client = OrderedJSONObject()
        client.append("id", invite.client.id)
        client.append("serverId", invite.client.serverId)
        client.append("clientId", invite.client.clientId)
        client.append("appType", invite.client.appType)
        client.append("publishStatus", invite.client.publishStatus)
        client.append("category", invite.client.category)
        client.append("dataAccessSummary", optional: invite.client.dataAccessSummary)
        client.append("publishRejectionReason", optional: invite.client.publishRejectionReason)
        client.append("name", invite.client.name)
        client.append("description", optional: invite.client.descriptionText)
        client.append("whenToUse", optional: invite.client.whenToUse)
        client.append("homepageUrl", optional: invite.client.homepageUrl)
        client.append("returnUrl", optional: invite.client.returnUrl)
        client.append("agentManifestUrl", optional: invite.client.agentManifestUrl)
        client.append("setupUrl", optional: invite.client.setupUrl)
        client.append("setupDescription", optional: invite.client.setupDescription)
        client.append("setupRevision", invite.client.setupRevision)
        client.append("allowedScopes", invite.client.allowedScopes.map { .array($0.map(OrderedJSON.string)) } ?? .null)
        client.append("logoUrl", optional: invite.client.logoUrl)
        client.append("humanMarketplaceVisible", invite.client.humanMarketplaceVisible)
        client.append("createdByUserId", invite.client.createdByUserId)
        client.append("createdAt", .string(Self.iso(invite.client.createdAt) ?? ""))
        client.append("updatedAt", .string(Self.iso(invite.client.updatedAt) ?? ""))
        client.append("publisherName", optional: invite.publisherName)
        client.append("sourceServerName", invite.sourceServerName)
        client.append("installedAt", optional: Self.iso(invite.installedAt))
        let servers = invite.manageableServers.map { row -> OrderedJSON in
            var body = OrderedJSONObject()
            body.append("id", row.id)
            body.append("name", row.name)
            body.append("slug", row.slug)
            body.append("role", row.role)
            body.append("installedAt", optional: Self.iso(row.installedAt))
            return body.json
        }
        return .object([
            OrderedJSONField("client", client.json),
            OrderedJSONField("link", linkJSON(invite.link)),
            OrderedJSONField("manageableServers", .array(servers)),
        ])
    }

    public func getInvite(authorization: String?, token: String) throws -> OrderedBodyDTO {
        let userId = try requireUser(authorization)
        guard let invite = oauth.managedShareInvite(token: token, userId: userId, targetServerId: nil) else {
            throw IntegrationAppManagementError.notFound("Private app invite not found")
        }
        var enriched = invite
        enriched.publisherName = userDisplayName(invite.client.createdByUserId)
        return OrderedBodyDTO(inviteJSON(enriched))
    }

    public func installInvite(
        authorization: String?, token: String, body: IntegrationRequestBody?
    ) throws -> OrderedBodyDTO {
        let userId = try requireUser(authorization)
        let serverId = (body?.string("serverId") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serverId.isEmpty else {
            throw IntegrationAppManagementError.badRequest("serverId is required")
        }
        guard let invite = oauth.installManagedShareInvite(token: token, userId: userId, serverId: serverId) else {
            throw IntegrationAppManagementError.forbidden(
                "You can only install this app to a server you own or administer"
            )
        }
        var enriched = invite
        enriched.publisherName = userDisplayName(invite.client.createdByUserId)
        return OrderedBodyDTO(inviteJSON(enriched))
    }

    // MARK: - App Notifications permissions / webhook / grant

    private func scopesValue(_ value: JSONValue?) throws -> [String]? {
        guard let value else { return nil }
        if case .null = value { return nil }
        guard case .array(let items) = value else {
            throw IntegrationAppManagementError.badRequest("scopes must be an array")
        }
        var result: [String] = []
        for item in items {
            guard case .string(let scope) = item else {
                throw IntegrationAppManagementError.badRequest("scopes must contain strings")
            }
            let trimmed = scope.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw IntegrationAppManagementError.badRequest("scope values must be non-empty")
            }
            guard Self.scopes.contains(trimmed) else {
                throw IntegrationAppManagementError.badRequest("invalid_scope")
            }
            result.append(trimmed)
        }
        guard !result.isEmpty else {
            throw IntegrationAppManagementError.badRequest("at least one scope is required")
        }
        return Array(Set(result)).sorted()
    }

    private func categoryValue(_ value: JSONValue?) throws -> String {
        guard let value else { return "Other" }
        if case .null = value { return "Other" }
        guard case .string(let raw) = value else {
            throw IntegrationAppManagementError.badRequest(
                "category must be one of: \(Self.categories.joined(separator: ", "))"
            )
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Other" }
        if Self.categories.contains(trimmed) { return trimmed }
        // Legacy category values are upgraded to the current taxonomy.
        let legacy: [String: String] = [
            "AI": "AI & Automation", "Automation": "AI & Automation",
            "Communication & Collaboration": "Communication",
            "Productivity": "Productivity & Collaboration",
            "Developer": "Developer Tools", "Analytics": "Data & Analytics",
            "Business": "Business Ops", "Infrastructure & DevOps": "Infrastructure",
            "Creative": "Content & Creative",
        ]
        if let upgraded = legacy[trimmed] { return upgraded }
        throw IntegrationAppManagementError.badRequest(
            "category must be one of: \(Self.categories.joined(separator: ", "))"
        )
    }

    private static func normalizeWhenToUse(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard value.count <= 160 else {
            throw OAuthClientRejection(message: "whenToUse must be at most 160 characters")
        }
        if value.rangeOfCharacter(from: .controlCharacters) != nil {
            throw OAuthClientRejection(message: "whenToUse must be a single line without control characters")
        }
        return value
    }

    private func permissionRequest(_ body: IntegrationRequestBody?) throws -> (groups: [String], events: [String]) {
        guard let body else {
            throw IntegrationAppManagementError.badRequest("group must be an array")
        }
        func strings(_ key: String, allowed: Set<String>, label: String) throws -> [String] {
            guard case .array(let items)? = body.value(key) else {
                throw IntegrationAppManagementError.badRequest("\(label) must be an array")
            }
            var result = Set<String>()
            for item in items {
                guard case .string(let value) = item, allowed.contains(value) else {
                    throw IntegrationAppManagementError.badRequest("Unknown \(label) value")
                }
                result.insert(value)
            }
            return result.sorted()
        }
        let groups = try strings("groups", allowed: Set(Self.groups), label: "group")
        let events = try strings("events", allowed: Set(Self.eventGroups.keys), label: "event")
        for event in events {
            if let missing = Self.eventGroups[event]?.first(where: { !groups.contains($0) }) {
                throw IntegrationAppManagementError.badRequest("Event \(event) requires group \(missing)")
            }
        }
        if groups.contains("agent_reminder_write"), !oauth.hasOfficialApp {
            throw IntegrationAppManagementError.badRequest(
                "Group agent_reminder_write is only grantable to official apps"
            )
        }
        return (groups, events)
    }

    public func updatePermissions(
        authorization: String?, serverId: String, clientId: String, body: IntegrationRequestBody?
    ) throws -> OrderedBodyDTO {
        try requireAppId(clientId)
        _ = try requireManager(
            authorization, serverId: serverId,
            message: "Only an owner or admin of the app source server can update App Notifications permissions"
        )
        let (groups, events) = try permissionRequest(body)
        guard let outcome = oauth.createManagedPermissionRevision(
            serverId: serverId, recordId: clientId, groups: groups, events: events
        ) else {
            throw IntegrationAppManagementError.notFound("OAuth client not found")
        }
        var body = OrderedJSONObject()
        body.append("request_revision_id", outcome.revision.id)
        body.append("revision", outcome.revision.revision)
        body.append("state", outcome.revision.state)
        body.append("current_groups", .array(outcome.currentGroups.map(OrderedJSON.string)))
        body.append("current_events", .array(outcome.currentEvents.map(OrderedJSON.string)))
        body.append("requires_marketplace_review", outcome.requiresReview)
        body.append("invalidated_installation_count", outcome.invalidatedInstallationCount)
        return OrderedBodyDTO(body.json)
    }

    public func updateInstallationGrant(
        authorization: String?, serverId: String, clientId: String
    ) throws -> OrderedBodyDTO {
        try requireAppId(clientId)
        _ = try requireManager(
            authorization, serverId: serverId,
            message: "Only server owners and admins can approve App Notifications permissions"
        )
        guard let installation = oauth.updateManagedInstallationGrant(serverId: serverId, recordId: clientId) else {
            throw IntegrationAppManagementError.notFound("Active app installation not found")
        }
        var body = OrderedJSONObject()
        body.append("installation_id", installation.id)
        body.append("approved_request_revision_id", optional: installation.approvedRequestRevisionId)
        body.append("approved_groups", .array(installation.approvedGroups.map(OrderedJSON.string)))
        body.append("subscribed_events", .array(installation.subscribedEvents.map(OrderedJSON.string)))
        body.append("grant_revision", installation.grantRevision)
        body.append("subscription_revision", installation.subscriptionRevision)
        return OrderedBodyDTO(body.json)
    }

    private func validateWebhookURL(_ raw: String?) throws -> String {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IntegrationAppManagementError.badRequest("endpointUrl is required")
        }
        guard let components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              let host = components.host?.lowercased(), !host.isEmpty
        else {
            throw IntegrationAppManagementError.badRequest("endpointUrl must be credential-free HTTPS")
        }
        if host == "localhost" || host.hasSuffix(".localhost") {
            throw IntegrationAppManagementError.badRequest("endpointUrl must use a public host")
        }
        if let address = IPv4Address(host), !Self.isPublicIPv4(address) {
            throw IntegrationAppManagementError.badRequest(
                "endpointUrl must not use a private or special-use address"
            )
        }
        if host.hasPrefix("[") || host.contains(":") {
            throw IntegrationAppManagementError.badRequest(
                "endpointUrl must not use a private or special-use address"
            )
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct IPv4Address {
        var octets: [Int]
        init?(_ raw: String) {
            let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 4 else { return nil }
            var values: [Int] = []
            for part in parts {
                guard !part.isEmpty, let value = Int(part), (0...255).contains(value) else { return nil }
                values.append(value)
            }
            octets = values
        }
    }

    private static func isPublicIPv4(_ address: IPv4Address) -> Bool {
        let a = address.octets
        if a[0] == 0 || a[0] == 10 || a[0] == 127 { return false }
        if a[0] == 100 && (64...127).contains(a[1]) { return false }
        if a[0] == 169 && a[1] == 254 { return false }
        if a[0] == 172 && (16...31).contains(a[1]) { return false }
        if a[0] == 192 && a[1] == 168 { return false }
        if a[0] == 198 && (18...19).contains(a[1]) { return false }
        if a[0] >= 224 { return false }
        return true
    }

    private func requireWebhookKey() throws {
        let raw = environment["RAFT_APP_WEBHOOK_ENCRYPTION_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else {
            throw IntegrationAppManagementError.badRequest("RAFT_APP_WEBHOOK_ENCRYPTION_KEY is required")
        }
        let bytes: Int
        if raw.count == 64, raw.allSatisfy(\.isHexDigit) {
            bytes = 32
        } else if let decoded = Data(base64Encoded: raw) {
            bytes = decoded.count
        } else {
            bytes = 0
        }
        guard bytes == 32 else {
            throw IntegrationAppManagementError.badRequest(
                "RAFT_APP_WEBHOOK_ENCRYPTION_KEY must decode to 32 bytes"
            )
        }
    }

    public func configureWebhook(
        authorization: String?, serverId: String, clientId: String, body: IntegrationRequestBody?
    ) throws -> OrderedBodyDTO {
        try requireAppId(clientId)
        let userId = try requireManager(
            authorization, serverId: serverId,
            message: "Only an owner or admin of the app source server can configure its webhook"
        )
        _ = userId
        guard oauth.sourceOwnedClient(serverId: serverId, recordId: clientId) != nil else {
            throw IntegrationAppManagementError.forbidden(
                "Only an owner or admin of the app source server can configure its webhook"
            )
        }
        let endpointUrl = try validateWebhookURL(body?.string("endpointUrl") ?? body?.string("endpoint_url"))
        try requireWebhookKey()
        guard let config = oauth.configureManagedWebhook(
            serverId: serverId, recordId: clientId, endpointUrl: endpointUrl
        ) else {
            throw IntegrationAppManagementError.notFound("OAuth client not found")
        }
        var response = OrderedJSONObject()
        response.append("endpoint_url", config.endpointUrl)
        response.append("config_revision", config.revision)
        response.append("enabled", config.enabled)
        if config.revision == 1 { response.append("signing_secret", config.secret) }
        return OrderedBodyDTO(response.json)
    }

    public func rotateWebhookSecret(
        authorization: String?, serverId: String, clientId: String, body: IntegrationRequestBody?
    ) throws -> OrderedBodyDTO {
        try requireAppId(clientId)
        _ = try requireManager(
            authorization, serverId: serverId,
            message: "Only an owner or admin of the app source server can rotate its webhook secret"
        )
        guard oauth.sourceOwnedClient(serverId: serverId, recordId: clientId) != nil else {
            throw IntegrationAppManagementError.forbidden(
                "Only an owner or admin of the app source server can rotate its webhook secret"
            )
        }
        try requireWebhookKey()
        guard let config = oauth.rotateManagedWebhookSecret(
            serverId: serverId, recordId: clientId, emergency: body?.bool("emergency") == true
        ) else {
            throw IntegrationAppManagementError.notFound("Active webhook configuration not found")
        }
        var response = OrderedJSONObject()
        response.append("signing_secret", config.secret)
        response.append("config_revision", config.revision)
        response.append("previous_valid_until", optional: Self.iso(config.previousValidUntil))
        response.append("emergency", body?.bool("emergency") == true)
        return OrderedBodyDTO(response.json)
    }

    public func disableWebhook(
        authorization: String?, serverId: String, clientId: String
    ) throws -> OrderedBodyDTO {
        try requireAppId(clientId)
        _ = try requireManager(
            authorization, serverId: serverId,
            message: "Only an owner or admin of the app source server can disable its webhook"
        )
        guard oauth.sourceOwnedClient(serverId: serverId, recordId: clientId) != nil else {
            throw IntegrationAppManagementError.forbidden(
                "Only an owner or admin of the app source server can disable its webhook"
            )
        }
        guard let config = oauth.disableManagedWebhook(serverId: serverId, recordId: clientId) else {
            throw IntegrationAppManagementError.notFound("Webhook configuration not found")
        }
        return OrderedBodyDTO(.object([
            OrderedJSONField("config_revision", .int(config.revision)),
            OrderedJSONField("enabled", .bool(config.enabled)),
        ]))
    }

    // MARK: - Overview and deny

    public func overview(authorization: String?, serverId: String) throws -> OrderedBodyDTO {
        let userId = try requireUser(authorization)
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            throw IntegrationAppManagementError.notAMember
        }
        let rows = oauth.managedIntegrationsOverview(serverId: serverId).map { row -> OrderedJSON in
            var body = OrderedJSONObject()
            body.append("id", row.id)
            body.append("type", row.type)
            body.append("serverId", row.serverId)
            body.append("agentId", row.agentId)
            body.append("agentName", row.agentName)
            body.append("agentDisplayName", optional: row.agentDisplayName)
            body.append("clientId", row.clientId)
            body.append("clientKey", row.clientKey)
            body.append("clientName", row.clientName)
            body.append("clientDescription", optional: row.clientDescription)
            body.append("clientHomepageUrl", optional: row.clientHomepageUrl)
            body.append("clientReturnUrl", optional: row.clientReturnUrl)
            body.append("clientAgentManifestUrl", optional: row.clientAgentManifestUrl)
            body.append("scopes", .array(row.scopes.map(OrderedJSON.string)))
            body.append("remember", row.remember)
            body.append("createdAt", .string(Self.iso(row.createdAt) ?? ""))
            body.append("resolvedAt", optional: Self.iso(row.resolvedAt))
            body.append("resolvedByUserId", optional: row.resolvedByUserId)
            body.append("revokedAt", optional: Self.iso(row.revokedAt))
            body.append("grantSource", optional: row.grantSource)
            return body.json
        }
        return OrderedBodyDTO(.array(rows))
    }

    public func denyRequest(
        authorization: String?, serverId: String, requestId: String
    ) throws -> OrderedBodyDTO {
        try requireRequestId(requestId)
        let userId = try requireUser(authorization)
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            throw IntegrationAppManagementError.notAMember
        }
        guard let request = oauth.denyManagedAccessRequest(userId: userId, requestId: requestId),
              request.serverId == serverId
        else {
            throw IntegrationAppManagementError.notFound("Access request not found")
        }
        var body = OrderedJSONObject()
        body.append("id", request.id)
        body.append("serverId", request.serverId)
        body.append("principalType", request.principalType)
        body.append("agentId", optional: request.agentId)
        body.append("userId", optional: request.userId)
        body.append("clientId", request.clientId)
        body.append("scopes", .array(request.scopes.map(OrderedJSON.string)))
        body.append("resource", optional: request.resource)
        body.append("status", request.status)
        body.append("remember", request.remember)
        body.append("resolvedByUserId", optional: request.resolvedByUserId)
        body.append("resolvedAt", optional: Self.iso(request.resolvedAt))
        body.append("consumedAt", optional: Self.iso(request.consumedAt))
        body.append("createdAt", .string(Self.iso(request.createdAt) ?? ""))
        body.append("updatedAt", .string(Self.iso(request.updatedAt ?? request.createdAt) ?? ""))
        return OrderedBodyDTO(body.json)
    }

    // MARK: - Logo

    /// Uploads an integration logo. The deployment has no image pipeline or
    /// object storage (D5), so a valid upload has the same published 500 the
    /// upstream route returns when storage is not configured. The upload shape
    /// checks in front of it stay exact.
    public func uploadLogo(
        authorization: String?, serverId: String, clientId: String, upload: MultipartUpload
    ) throws -> OrderedBodyDTO {
        try requireAppId(clientId)
        _ = try requireManager(
            authorization, serverId: serverId,
            message: "Only server owners and admins can manage integrations"
        )
        _ = try requireOwnedClient(serverId: serverId, recordId: clientId)
        guard let file = upload.file else {
            throw IntegrationAppManagementError.badRequest("No logo file provided")
        }
        guard ["image/jpeg", "image/png", "image/gif", "image/webp"].contains(file.contentType.lowercased()) else {
            throw IntegrationAppManagementError.badRequest(
                "Only image files are allowed (JPEG, PNG, GIF, WebP)"
            )
        }
        guard file.bytes.count <= 5 * 1024 * 1024 else {
            throw IntegrationAppManagementError.badRequest(
                "Avatar image must be 5 MB or smaller"
            )
        }
        throw IntegrationAppManagementError.serverFailure(
            correlationId: UUID().uuidString.lowercased()
        )
    }

    public func clearLogo(
        authorization: String?, serverId: String, clientId: String
    ) throws -> OrderedBodyDTO {
        try requireAppId(clientId)
        _ = try requireManager(
            authorization, serverId: serverId,
            message: "Only server owners and admins can manage integrations"
        )
        guard var client = oauth.sourceOwnedClient(serverId: serverId, recordId: clientId) else {
            throw IntegrationAppManagementError.notFound("OAuth client not found")
        }
        client.logoUrl = nil
        client.logoStorageKey = nil
        client.updatedAt = now()
        oauth.replaceClientLogo(client)
        return OrderedBodyDTO(clientJSON(client))
    }
}

/// One uploaded multipart file, already bounded by the caller.
public struct MultipartUpload: Sendable {
    public struct File: Sendable {
        public var contentType: String
        public var bytes: Data

        public init(contentType: String, bytes: Data) {
            self.contentType = contentType
            self.bytes = bytes
        }
    }

    public var file: File?

    public init(file: File? = nil) {
        self.file = file
    }
}

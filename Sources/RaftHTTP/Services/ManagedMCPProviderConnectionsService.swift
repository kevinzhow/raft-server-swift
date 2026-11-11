import Foundation

/// Provider connections: list, create, patch, credential rotation, the retired
/// probe and the assigned-agent list.
///
/// Every route first requires the surface to be enabled for the server, then an
/// owner or admin. The service returns the published `JSONBodyConvertible`
/// bodies and throws `ManagedMCPLifecycleError`; the patch and the rotation are
/// one `ManagedMCPAndCardsStore` critical section each.
public struct ManagedMCPProviderConnectionsService: Sendable {
    public static let providerConnectionProviderIds = [
        "deepseek", "minimax", "minimax-cn", "zai", "zai-coding-cn", "moonshotai",
        "moonshotai-cn", "kimi-coding", "qwen-token-plan", "qwen-token-plan-cn",
        "openrouter", "openai", "anthropic", "google", "xai", "xiaomi",
        "openai-compatible", "anthropic-compatible",
    ]

    private static let allowedKeys: Set<String> = [
        "name", "providerId", "apiKey", "endpointUrl", "supportsImageInput", "authMethod",
    ]

    private let sessionUserId: @Sendable (String?) -> String?
    private let oauth: OAuthLedger
    private let providers: ManagedMCPAndCardsStore
    private let now: @Sendable () -> Date
    private let credentialMasterKey: @Sendable () throws -> Data

    init(
        sessionUserId: @escaping @Sendable (String?) -> String?,
        oauth: OAuthLedger,
        providers: ManagedMCPAndCardsStore,
        now: @escaping @Sendable () -> Date = { Date() },
        credentialMasterKey: @escaping @Sendable () throws -> Data = {
            try ProviderCredentialVault.configuredMasterKey()
        }
    ) {
        self.sessionUserId = sessionUserId
        self.oauth = oauth
        self.providers = providers
        self.now = now
        self.credentialMasterKey = credentialMasterKey
    }

    /// Binds one external in-memory credential master without changing owners or clocks.
    /// The caller must keep the key out of persisted state, responses and diagnostics.
    public func bindingCredentialMasterKey(_ masterKey: Data) throws -> Self {
        guard masterKey.count == 32 else {
            throw ProviderCredentialError.encryptionKeyUnavailable
        }
        return Self(
            sessionUserId: sessionUserId, oauth: oauth, providers: providers, now: now,
            credentialMasterKey: { masterKey }
        )
    }

    /// The enabled-surface and owner/admin gate every provider route shares.
    private func requireManager(_ authorization: String?, serverId: String) throws {
        guard let userId = sessionUserId(authorization) else {
            throw ManagedMCPLifecycleError.unauthorized
        }
        guard providers.isProviderConnectionsEnabled(serverId: serverId) else {
            throw ManagedMCPLifecycleError.providerConnectionsDisabled
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId),
              role == "owner" || role == "admin"
        else { throw ManagedMCPLifecycleError.forbidden }
    }

    // MARK: - GET /api/provider-connections

    public func listProviderConnections(
        authorization: String?,
        serverId: String
    ) throws -> ProviderConnectionListResponse {
        try requireManager(authorization, serverId: serverId)
        return ProviderConnectionListResponse(
            connections: providers.providerConnections(serverId: serverId),
            options: Self.providerConnectionProviderIds.map {
                ProviderConnectionListResponse.Option(id: $0, label: Self.providerConnectionLabel($0))
            }
        )
    }

    // MARK: - POST /api/provider-connections

    public func createProviderConnection(
        authorization: String?,
        serverId: String,
        body: LenientJSONObjectRequest?
    ) throws -> ProviderConnectionBody {
        try requireManager(authorization, serverId: serverId)
        guard let object = body,
              let name = object["name"]?.legacyString,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let providerId = object["providerId"]?.legacyString,
              Self.providerConnectionProviderIds.contains(providerId),
              let apiKey = object["apiKey"]?.legacyString, !apiKey.isEmpty,
              Set(object.members.keys).isSubset(of: Self.allowedKeys)
        else { throw ManagedMCPLifecycleError.invalidProviderConnection }
        let created = now()
        let connection = ProviderConnection(
            id: UUID().uuidString.lowercased(),
            serverId: serverId,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            providerId: providerId,
            endpointUrl: object["endpointUrl"]?.legacyString,
            supportsImageInput: object["supportsImageInput"]?.legacyBool ?? false,
            status: "unchecked",
            configVersion: 1,
            credentialVersion: 1,
            hasCredential: true,
            createdAt: created,
            updatedAt: created
        )
        let credential = try ProviderCredentialVault(masterKey: credentialMasterKey()).seal(
            apiKey, serverId: serverId, connectionId: connection.id
        )
        try providers.insertProviderConnection(connection, credential: credential)
        return ProviderConnectionBody(connection: connection)
    }

    // MARK: - Retired probe

    public func retiredProviderProbe(authorization: String?, serverId: String) throws -> NoContentResponse {
        try requireManager(authorization, serverId: serverId)
        throw ManagedMCPLifecycleError.providerProbeRetired
    }

    // MARK: - Provider probes (GET/POST /api/provider-connections/:id/probes)

    /// The provider-connections feature is off in this deployment, so both
    /// probe routes answer the upstream disabled-surface refusal. When a server
    /// enables the surface the retired probe refusal stays explicit (D5): this
    /// build has no daemon carrier that could execute a probe.
    public func listProviderProbes(
        authorization: String?, serverId: String, connectionId: String
    ) throws -> NoContentResponse {
        try requireManager(authorization, serverId: serverId)
        guard connectionId.wholeMatch(of: /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) != nil else {
            throw ManagedMCPLifecycleError.invalidProviderConnection
        }
        throw ManagedMCPLifecycleError.providerProbeRetired
    }

    public func createProviderProbe(
        authorization: String?, serverId: String, connectionId: String
    ) throws -> NoContentResponse {
        try requireManager(authorization, serverId: serverId)
        guard connectionId.wholeMatch(of: /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) != nil else {
            throw ManagedMCPLifecycleError.invalidProviderConnection
        }
        throw ManagedMCPLifecycleError.providerProbeRetired
    }

    // MARK: - PATCH /api/provider-connections/:id

    public func patchProviderConnection(
        authorization: String?,
        serverId: String,
        connectionId: String,
        body: LenientJSONObjectRequest?
    ) throws -> ProviderConnectionBody {
        try requireManager(authorization, serverId: serverId)
        guard let object = body, Set(object.members.keys).isSubset(of: Self.allowedKeys) else {
            throw ManagedMCPLifecycleError.invalidProviderConnection
        }
        if object["apiKey"] != nil, object["providerId"] != nil {
            throw ManagedMCPLifecycleError.rotateCredentialSeparately
        }
        var patch = ProviderConnectionPatch(credential: nil)
        if let name = object["name"]?.legacyString,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            patch.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        patch.endpointUrl = object["endpointUrl"]?.legacyString
        patch.supportsImageInput = object["supportsImageInput"]?.legacyBool
        if let apiKey = object["apiKey"]?.legacyString, !apiKey.isEmpty {
            patch.credential = try encryptedCredentialForExistingConnection(
                apiKey, serverId: serverId, connectionId: connectionId
            )
        }
        guard let updated = try providers.patchProviderConnection(
            id: connectionId, serverId: serverId, patch: patch, now: now()
        ) else { throw ManagedMCPLifecycleError.providerConnectionNotFound }
        return ProviderConnectionBody(connection: updated)
    }

    // MARK: - Credential rotation

    public func rotateProviderConnectionCredential(
        authorization: String?,
        serverId: String,
        connectionId: String,
        body: LenientJSONObjectRequest?
    ) throws -> ProviderConnectionBody {
        try requireManager(authorization, serverId: serverId)
        guard let apiKey = body?["apiKey"]?.legacyString, !apiKey.isEmpty else {
            throw ManagedMCPLifecycleError.apiKeyRequired
        }
        let credential = try encryptedCredentialForExistingConnection(
            apiKey, serverId: serverId, connectionId: connectionId
        )
        guard let updated = try providers.rotateProviderCredential(
            id: connectionId, serverId: serverId, credential: credential, now: now()
        ) else { throw ManagedMCPLifecycleError.providerConnectionNotFound }
        return ProviderConnectionBody(connection: updated)
    }

    /// Internal outbound-provider use only: no route or response DTO exposes this value.
    /// The caller must keep the returned key out of responses, diagnostics and logs.
    /// Uses the same live session, enabled-surface and owner/admin gates as management.
    public func providerCredentialForRequest(
        authorization: String?, serverId: String, connectionId: String
    ) throws -> String {
        try requireManager(authorization, serverId: serverId)
        guard providers.containsProviderConnection(id: connectionId, serverId: serverId) else {
            throw ManagedMCPLifecycleError.providerConnectionNotFound
        }
        guard let credential = providers.providerCredential(id: connectionId, serverId: serverId) else {
            throw ProviderCredentialError.credentialUnavailable
        }
        return try ProviderCredentialVault(masterKey: credentialMasterKey()).open(
            credential, serverId: serverId, connectionId: connectionId
        )
    }

    private func encryptedCredentialForExistingConnection(
        _ apiKey: String, serverId: String, connectionId: String
    ) throws -> ProviderCredentialEnvelope {
        // Preserve the existing body-validation -> scoped not-found order even if
        // this process has no usable encryption master. No metadata is changed here.
        guard providers.containsProviderConnection(id: connectionId, serverId: serverId) else {
            throw ManagedMCPLifecycleError.providerConnectionNotFound
        }
        return try ProviderCredentialVault(masterKey: credentialMasterKey()).seal(
            apiKey, serverId: serverId, connectionId: connectionId
        )
    }

    // MARK: - GET /api/provider-connections/:id/agents

    /// Unlike the other provider routes this one does not require the surface to
    /// be enabled; it only asks for an owner or admin.
    public func listAssignedProviderAgents(
        authorization: String?,
        serverId: String,
        connectionId: String
    ) throws -> ProviderAssignedAgentsResponse {
        guard let userId = sessionUserId(authorization) else {
            throw ManagedMCPLifecycleError.unauthorized
        }
        let role = oauth.memberRole(serverId: serverId, userId: userId)
        guard role == "owner" || role == "admin" else { throw ManagedMCPLifecycleError.forbidden }
        let (known, assignments) = providers.providerAssignments(serverId: serverId, connectionId: connectionId)
        guard known else { throw ManagedMCPLifecycleError.providerConnectionNotFound }
        var rows: [ProviderAssignedAgentsResponse.Row] = []
        for assignment in assignments {
            guard let info = oauth.providerAgentInfo(serverId: serverId, agentId: assignment.agentId) else { continue }
            rows.append(.init(id: assignment.agentId, info: info, computerName: assignment.computerName))
        }
        return ProviderAssignedAgentsResponse(agents: rows)
    }

    static func providerConnectionLabel(_ id: String) -> String {
        switch id {
        case "openai-compatible": return "OpenAI compatible"
        case "anthropic-compatible": return "Anthropic compatible"
        case "minimax-cn": return "MiniMax CN"
        case "zai-coding-cn": return "Z.ai Coding CN"
        case "moonshotai-cn": return "Moonshot AI CN"
        case "kimi-coding": return "Kimi Coding"
        case "qwen-token-plan": return "Qwen Token Plan"
        case "qwen-token-plan-cn": return "Qwen Token Plan CN"
        default: return id.prefix(1).uppercased() + id.dropFirst()
        }
    }
}

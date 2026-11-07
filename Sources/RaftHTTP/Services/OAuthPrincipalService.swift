/// Principal projection over the actual live profile configuration and OAuth
/// owners. Construction snapshots no URL, token, member, agent or server row.
public struct OAuthPrincipalService: Sendable {
    private let profiles: AuthProfileStore
    private let oauth: OAuthLedger

    init(profiles: AuthProfileStore, oauth: OAuthLedger) {
        self.profiles = profiles
        self.oauth = oauth
    }

    public func userinfo(authorization: String?, scopeServerId: String? = nil) throws -> OAuthUserinfoResponse {
        let baseURL = profiles.oauthDeploymentConfiguration.serverURL
        guard let raw = OAuthRequestParsing.bearerToken(authorization) else {
            throw OAuthLedgerError(.missingBearerToken)
        }
        do {
            let facts = try oauth.userinfoFacts(.init(token: raw, scopeServerId: scopeServerId))
            return OAuthUserinfoResponse(scope: facts.scopes.joined(separator: " "), clientId: facts.clientId,
                clientName: facts.clientName, serverId: facts.serverId, serverSlug: facts.serverSlug,
                sub: facts.sub, type: facts.type, serverRole: facts.serverRole,
                preferredUsername: facts.preferredUsername, name: facts.name, avatarUrl: facts.avatarUrl,
                picture: facts.type == "agent" ? agentPicture(avatar: facts.avatarUrl, baseURL: baseURL)
                    : userinfoPicture(avatar: facts.avatarUrl, baseURL: baseURL),
                description: facts.description,
                email: facts.email.map { .init(address: $0, verified: facts.emailVerified) })
        } catch let failure as OAuthPrincipalFailure { throw published(failure) }
    }

    public func serverinfo(authorization: String?, scopeServerId: String? = nil) throws -> OAuthServerinfoResponse {
        let baseURL = profiles.oauthDeploymentConfiguration.serverURL
        guard let raw = OAuthRequestParsing.bearerToken(authorization) else {
            throw OAuthLedgerError(.missingBearerToken)
        }
        do {
            let facts = try oauth.serverinfoFacts(.init(token: raw, scopeServerId: scopeServerId))
            return OAuthServerinfoResponse(id: facts.id, slug: facts.slug, name: facts.name,
                avatarUrl: facts.avatarUrl, picture: absolutePicture(facts.avatarUrl, baseURL: baseURL), isPaid: facts.isPaid)
        } catch let failure as OAuthPrincipalFailure { throw published(failure) }
    }

    public func agentDirectory(authorization: String?, scopeServerId: String? = nil) throws -> OAuthAgentDirectoryResponse {
        let baseURL = profiles.oauthDeploymentConfiguration.serverURL
        let noStore = "no-store"
        guard let raw = OAuthRequestParsing.bearerToken(authorization) else {
            throw OAuthLedgerError(.missingBearerToken, cacheControl: noStore)
        }
        do {
            let facts = try oauth.directoryFacts(.init(token: raw, scopeServerId: scopeServerId))
            return OAuthAgentDirectoryResponse(agents: facts.entries.map { entry in
                .init(id: entry.id, handle: entry.handle, displayName: entry.displayName,
                    avatarUrl: entry.avatarUrl, picture: agentPicture(avatar: entry.avatarUrl, baseURL: baseURL))
            })
        } catch let failure as OAuthPrincipalFailure { throw published(failure, cacheControl: noStore) }
    }

    /// Only a Raft-uploaded user avatar becomes a picture URL.
    private func userinfoPicture(avatar: String?, baseURL: String) -> String? {
        guard let avatar,
              avatar.wholeMatch(of: /^(?i)\/(?:api\/)?avatars\/users\/[0-9a-f]+\.webp$/) != nil
        else { return nil }
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        return base + avatar
    }

    private func agentPicture(avatar: String?, baseURL: String) -> String? {
        guard let avatar else { return nil }
        if avatar.hasPrefix("pixel:") {
            let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
            return base + "/api/avatars/pixel/\(OAuthLedger.pixelAvatarKey(avatar)).svg"
        }
        return absolutePicture(avatar, baseURL: baseURL)
    }

    private func absolutePicture(_ path: String?, baseURL: String) -> String? {
        guard let path else { return nil }
        if path.hasPrefix("http://") || path.hasPrefix("https://") { return path }
        guard path.hasPrefix("/") else { return nil }
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        return base + path
    }

    private func published(_ failure: OAuthPrincipalFailure, cacheControl: String? = nil) -> OAuthLedgerError {
        let reason: OAuthLedgerError.Reason
        switch failure {
        case .invalidOrExpiredAccessToken: reason = .invalidOrExpiredAccessToken
        case .wrongIssuerServer: reason = .wrongIssuerServer
        case .agentReadRequired: reason = .agentReadRequired
        }
        return OAuthLedgerError(reason, cacheControl: cacheControl)
    }
}

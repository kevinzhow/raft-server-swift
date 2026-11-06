import Crypto
import Foundation
import RaftShared

extension OAuthLedger {
    /// `GET /api/oauth/userinfo`. Only principal access tokens resolve; an App
    /// installation credential is not a principal and stays 401.
    public func userinfo(authorization: String?, baseURL: String, scopeServerId: String? = nil) throws -> OAuthUserinfoResponse {
        guard let raw = OAuthRequestParsing.bearerToken(authorization) else {
            throw OAuthLedgerError(.missingBearerToken)
        }
        return try self.state.withLock { ledgerState in
            guard let token = principalTokenLocked(raw, state: ledgerState),
                  let client = ledgerState.clients.first(where: { $0.id == token.clientId }),
                  isUserManaged(client),
                  let server = ledgerState.servers[token.serverId], !server.deleted
            else {
                throw OAuthLedgerError(.invalidOrExpiredAccessToken)
            }
            if let scopeServerId, scopeServerId != token.serverId {
                throw OAuthLedgerError(.wrongIssuerServer)
            }
            if token.principalType == "agent" {
                guard let agentId = token.agentId,
                      let agent = ledgerState.agents[agentId],
                      agent.serverId == server.id,
                      !agent.deleted,
                      let role = ledgerState.agentRoles["\(server.id)\n\(agentId)"]
                else {
                    throw OAuthLedgerError(.invalidOrExpiredAccessToken)
                }
                return OAuthUserinfoResponse(
                    scope: token.scopes.joined(separator: " "),
                    clientId: client.clientId,
                    clientName: client.name,
                    serverId: server.id,
                    serverSlug: server.slug,
                    sub: agent.id,
                    type: "agent",
                    serverRole: role,
                    preferredUsername: agent.name,
                    name: agent.displayName,
                    avatarUrl: agent.avatarUrl,
                    picture: agentPicture(avatar: agent.avatarUrl, baseURL: baseURL),
                    description: agent.description,
                    email: nil
                )
            }
            guard let request = ledgerState.requests.first(where: { $0.id == token.requestId }),
                  let role = ledgerState.members["\(token.serverId)\n\(token.userId)"]
            else {
                throw OAuthLedgerError(.invalidOrExpiredAccessToken)
            }
            var email: OAuthUserinfoResponse.Email?
            if token.scopes.contains("email"), !request.humanEmail.isEmpty {
                email = OAuthUserinfoResponse.Email(address: request.humanEmail, verified: request.humanEmailVerified)
            }
            return OAuthUserinfoResponse(
                scope: token.scopes.joined(separator: " "),
                clientId: client.clientId,
                clientName: client.name,
                serverId: server.id,
                serverSlug: server.slug,
                sub: token.userId,
                type: "human",
                serverRole: role,
                preferredUsername: request.humanName,
                name: request.humanName,
                avatarUrl: request.humanAvatarUrl,
                picture: userinfoPicture(avatar: request.humanAvatarUrl, baseURL: baseURL),
                description: nil,
                email: email
            )
        }
    }

    /// Only a Raft-uploaded user avatar becomes a picture URL.
    func userinfoPicture(avatar: String?, baseURL: String) -> String? {
        guard let avatar,
              avatar.wholeMatch(of: /^(?i)\/(?:api\/)?avatars\/users\/[0-9a-f]+\.webp$/) != nil
        else { return nil }
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        return base + avatar
    }

    func agentPicture(avatar: String?, baseURL: String) -> String? {
        guard let avatar else { return nil }
        if avatar.hasPrefix("pixel:") {
            let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
            return base + "/api/avatars/pixel/\(Self.pixelAvatarKey(avatar)).svg"
        }
        return absolutePicture(avatar, baseURL: baseURL)
    }

    /// `GET /api/oauth/serverinfo`. The token names the Server; a query cannot
    /// redirect the read. Fields come from the live Server row.
    public func serverinfo(authorization: String?, baseURL: String, scopeServerId: String? = nil) throws -> OAuthServerinfoResponse {
        guard let raw = OAuthRequestParsing.bearerToken(authorization) else {
            throw OAuthLedgerError(.missingBearerToken)
        }
        return try self.state.withLock { ledgerState in
            guard let token = principalTokenLocked(raw, state: ledgerState),
                  let client = ledgerState.clients.first(where: { $0.id == token.clientId }),
                  isUserManaged(client),
                  let server = ledgerState.servers[token.serverId], !server.deleted
            else {
                throw OAuthLedgerError(.invalidOrExpiredAccessToken)
            }
            if let scopeServerId, scopeServerId != token.serverId {
                throw OAuthLedgerError(.wrongIssuerServer)
            }
            if token.principalType == "agent" {
                guard let agentId = token.agentId,
                      let agent = ledgerState.agents[agentId],
                      agent.serverId == server.id,
                      !agent.deleted
                else {
                    throw OAuthLedgerError(.invalidOrExpiredAccessToken)
                }
            } else {
                guard ledgerState.members["\(token.serverId)\n\(token.userId)"] != nil else {
                    throw OAuthLedgerError(.invalidOrExpiredAccessToken)
                }
            }
            return OAuthServerinfoResponse(
                id: server.id,
                slug: server.slug,
                name: server.name,
                avatarUrl: server.avatarUrl,
                picture: absolutePicture(server.avatarUrl, baseURL: baseURL),
                isPaid: server.plan != "free"
            )
        }
    }

    func absolutePicture(_ path: String?, baseURL: String) -> String? {
        guard let path else { return nil }
        if path.hasPrefix("http://") || path.hasPrefix("https://") { return path }
        guard path.hasPrefix("/") else { return nil }
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        return base + path
    }

    /// Resolves an `/oidc/:server` segment by id or slug.
    public func serverScopeId(_ segment: String) -> String? {
        return self.state.withLock { ledgerState in
            return ledgerState.servers.values.first(where: {
                ($0.id == segment || $0.slug == segment) && !$0.deleted
            })?.id
        }
    }

    public func agentDirectory(authorization: String?, baseURL: String, scopeServerId: String? = nil) throws -> OAuthAgentDirectoryResponse {
        let noStore = "no-store"
        guard let raw = OAuthRequestParsing.bearerToken(authorization) else {
            throw OAuthLedgerError(.missingBearerToken, cacheControl: noStore)
        }
        return try self.state.withLock { ledgerState in
            guard let token = principalTokenLocked(raw, state: ledgerState),
                  let client = ledgerState.clients.first(where: { $0.id == token.clientId }),
                  isUserManaged(client),
                  let server = ledgerState.servers[token.serverId], !server.deleted
            else {
                throw OAuthLedgerError(.invalidOrExpiredAccessToken, cacheControl: noStore)
            }
            guard client.enabled, token.scopes.contains("agent:read") else {
                throw OAuthLedgerError(.agentReadRequired, cacheControl: noStore)
            }
            if let scopeServerId, scopeServerId != token.serverId {
                throw OAuthLedgerError(.wrongIssuerServer, cacheControl: noStore)
            }
            if token.principalType == "agent" {
                guard let agentId = token.agentId,
                      let agent = ledgerState.agents[agentId], !agent.deleted,
                      ledgerState.agentRoles["\(server.id)\n\(agentId)"] != nil
                else {
                    throw OAuthLedgerError(.invalidOrExpiredAccessToken, cacheControl: noStore)
                }
            } else {
                guard ledgerState.members["\(server.id)\n\(token.userId)"] != nil else {
                    throw OAuthLedgerError(.invalidOrExpiredAccessToken, cacheControl: noStore)
                }
            }
            let entries = ledgerState.agents.values
                .filter { $0.serverId == server.id && !$0.deleted }
                .sorted { $0.name < $1.name }
                .map { agent in
                    OAuthAgentDirectoryResponse.Entry(
                        id: agent.id,
                        handle: agent.name,
                        displayName: agent.displayName,
                        avatarUrl: agent.avatarUrl,
                        picture: agentPicture(avatar: agent.avatarUrl, baseURL: baseURL)
                    )
                }
            return OAuthAgentDirectoryResponse(agents: entries)
        }
    }
    /// Reads the caller's borrowed State; installation tokens live in a different table and never match.
    func principalTokenLocked(_ raw: String, state ledgerState: State) -> AccessToken? {
        let hash = sha256(raw)
        guard let token = ledgerState.tokens.last(where: { $0.tokenHash == hash }),
              token.expiresAt > Date(),
              token.revokedAt == nil
        else {
            return nil
        }
        if token.principalType == "agent", ledgerState.revokedGrantClients.contains(token.clientId) {
            return nil
        }
        return token
    }
}

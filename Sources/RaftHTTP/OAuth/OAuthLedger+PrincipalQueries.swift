import Crypto
import Foundation
import RaftShared

extension OAuthLedger {
    /// Userinfo retains its request/member and same-server agent-role gates.
    func userinfoFacts(_ attempt: OAuthPrincipalAttempt) throws -> OAuthUserinfoFacts {
        let raw = attempt.token
        return try self.state.withLock { ledgerState in
            guard let token = principalTokenLocked(raw, state: ledgerState),
                  let client = ledgerState.clients.first(where: { $0.id == token.clientId }),
                  isUserManaged(client),
                  let server = ledgerState.servers[token.serverId], !server.deleted
            else {
                throw OAuthPrincipalFailure.invalidOrExpiredAccessToken
            }
            if let scopeServerId = attempt.scopeServerId, scopeServerId != token.serverId {
                throw OAuthPrincipalFailure.wrongIssuerServer
            }
            if token.principalType == "agent" {
                guard let agentId = token.agentId,
                      let agent = ledgerState.agents[agentId],
                      agent.serverId == server.id,
                      !agent.deleted,
                      let role = ledgerState.agentRoles["\(server.id)\n\(agentId)"]
                else {
                    throw OAuthPrincipalFailure.invalidOrExpiredAccessToken
                }
                return OAuthUserinfoFacts(
                    scopes: token.scopes,
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
                    description: agent.description,
                    email: nil,
                    emailVerified: false
                )
            }
            guard let request = ledgerState.requests.first(where: { $0.id == token.requestId }),
                  let role = ledgerState.members["\(token.serverId)\n\(token.userId)"]
            else {
                throw OAuthPrincipalFailure.invalidOrExpiredAccessToken
            }
            var email: String?
            if token.scopes.contains("email"), !request.humanEmail.isEmpty {
                email = request.humanEmail
            }
            return OAuthUserinfoFacts(
                scopes: token.scopes,
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
                description: nil,
                email: email,
                emailVerified: request.humanEmailVerified
            )
        }
    }

    /// Serverinfo deliberately has no agent-role or human-request requirement.
    func serverinfoFacts(_ attempt: OAuthPrincipalAttempt) throws -> OAuthServerinfoFacts {
        let raw = attempt.token
        return try self.state.withLock { ledgerState in
            guard let token = principalTokenLocked(raw, state: ledgerState),
                  let client = ledgerState.clients.first(where: { $0.id == token.clientId }),
                  isUserManaged(client),
                  let server = ledgerState.servers[token.serverId], !server.deleted
            else {
                throw OAuthPrincipalFailure.invalidOrExpiredAccessToken
            }
            if let scopeServerId = attempt.scopeServerId, scopeServerId != token.serverId {
                throw OAuthPrincipalFailure.wrongIssuerServer
            }
            if token.principalType == "agent" {
                guard let agentId = token.agentId,
                      let agent = ledgerState.agents[agentId],
                      agent.serverId == server.id,
                      !agent.deleted
                else {
                    throw OAuthPrincipalFailure.invalidOrExpiredAccessToken
                }
            } else {
                guard ledgerState.members["\(token.serverId)\n\(token.userId)"] != nil else {
                    throw OAuthPrincipalFailure.invalidOrExpiredAccessToken
                }
            }
            return OAuthServerinfoFacts(
                id: server.id,
                slug: server.slug,
                name: server.name,
                avatarUrl: server.avatarUrl,
                isPaid: server.plan != "free"
            )
        }
    }

    /// Directory eligibility and its name-only ordering share the original borrow.
    func directoryFacts(_ attempt: OAuthPrincipalAttempt) throws -> OAuthDirectoryFacts {
        let raw = attempt.token
        return try self.state.withLock { ledgerState in
            guard let token = principalTokenLocked(raw, state: ledgerState),
                  let client = ledgerState.clients.first(where: { $0.id == token.clientId }),
                  isUserManaged(client),
                  let server = ledgerState.servers[token.serverId], !server.deleted
            else {
                throw OAuthPrincipalFailure.invalidOrExpiredAccessToken
            }
            guard client.enabled, token.scopes.contains("agent:read") else {
                throw OAuthPrincipalFailure.agentReadRequired
            }
            if let scopeServerId = attempt.scopeServerId, scopeServerId != token.serverId {
                throw OAuthPrincipalFailure.wrongIssuerServer
            }
            if token.principalType == "agent" {
                guard let agentId = token.agentId,
                      let agent = ledgerState.agents[agentId], !agent.deleted,
                      ledgerState.agentRoles["\(server.id)\n\(agentId)"] != nil
                else {
                    throw OAuthPrincipalFailure.invalidOrExpiredAccessToken
                }
            } else {
                guard ledgerState.members["\(server.id)\n\(token.userId)"] != nil else {
                    throw OAuthPrincipalFailure.invalidOrExpiredAccessToken
                }
            }
            let entries = ledgerState.agents.values
                .filter { $0.serverId == server.id && !$0.deleted }
                .sorted { $0.name < $1.name }
                .map { agent in
                    OAuthDirectoryEntryFacts(
                        id: agent.id,
                        handle: agent.name,
                        displayName: agent.displayName,
                        avatarUrl: agent.avatarUrl
                    )
                }
            return OAuthDirectoryFacts(entries: entries)
        }
    }
    /// Resolves an `/oidc/:server` segment by id or slug.
    public func serverScopeId(_ segment: String) -> String? {
        return self.state.withLock { ledgerState in
            return ledgerState.servers.values.first(where: {
                ($0.id == segment || $0.slug == segment) && !$0.deleted
            })?.id
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

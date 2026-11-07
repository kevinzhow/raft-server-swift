import Crypto
import Foundation
import RaftShared

extension OAuthLedger {
    /// Validate, mint and consume atomically. The returned claims are flat.
    func redeemAuthorizationCode(_ attempt: OAuthCodeRedemptionAttempt) throws -> OAuthCodeRedemptionReceipt {
        return try self.state.withLock { ledgerState in
            guard let client = ledgerState.clients.first(where: { $0.clientId == attempt.clientId && $0.appType != "slock_builtin" && $0.secretHash == sha256(attempt.clientSecret) }) else {
                throw OAuthAuthorizationFailure.invalidClientCredentials
            }
            guard let index = ledgerState.requests.firstIndex(where: { $0.id == attempt.code && $0.clientId == client.id }) else {
                if attempt.isOIDC {
                    throw OAuthAuthorizationFailure.invalidGrant(.requestInvalidOrExpired)
                }
                throw OAuthAuthorizationFailure.accessRequestNotFound
            }
            let request = ledgerState.requests[index]
            if attempt.isOIDC {
                guard request.oidc else {
                    throw OAuthAuthorizationFailure.invalidGrant(.codeRedirectOrVerifierInvalid)
                }
                if request.codeChallenge == nil, attempt.verifierPresent {
                    throw OAuthAuthorizationFailure.invalidGrant(.notPKCERequest)
                }
                if let challenge = request.codeChallenge {
                    guard let verifier = attempt.verifier, !verifier.isEmpty,
                          challenge == Self.pkceChallenge(verifier)
                    else {
                        throw OAuthAuthorizationFailure.invalidGrant(.codeRedirectOrVerifierInvalid)
                    }
                }
                if let redirect = request.oidcRedirectURI {
                    guard attempt.redirectURI == redirect else {
                        throw OAuthAuthorizationFailure.invalidGrant(.codeRedirectOrVerifierInvalid)
                    }
                }
            }
            if let scopeServerId = attempt.scopeServerId, scopeServerId != request.serverId {
                throw OAuthAuthorizationFailure.invalidGrant(.differentServer)
            }
            if request.consumedAt != nil {
                if attempt.isOIDC {
                    throw OAuthAuthorizationFailure.invalidGrant(.requestInvalidOrExpired)
                }
                throw OAuthAuthorizationFailure.requestAlreadyConsumed
            }
            let now = Date()
            if now.timeIntervalSince(request.createdAt) > 10 * 60 {
                if attempt.isOIDC {
                    throw OAuthAuthorizationFailure.invalidGrant(.requestInvalidOrExpired)
                }
                throw OAuthAuthorizationFailure.authorizationCodeExpired
            }
            guard let server = ledgerState.servers[request.serverId], !server.deleted,
                  let role = ledgerState.members["\(request.serverId)\n\(request.userId)"]
            else {
                throw OAuthAuthorizationFailure.invalidGrant(.identityUnavailable)
            }
            var raw = Data(count: 32)
            for index in raw.indices { raw[index] = UInt8.random(in: 0...255) }
            let accessToken = "slock_at_" + raw.map { String(format: "%02x", $0) }.joined()
            let expiresAt = now.addingTimeInterval(60 * 60)
            ledgerState.tokens.append(AccessToken(
                serverId: request.serverId,
                userId: request.userId,
                clientId: client.id,
                requestId: request.id,
                tokenHash: sha256(accessToken),
                scopes: request.scopes,
                expiresAt: expiresAt
            ))
            ledgerState.requests[index].consumedAt = now
            return OAuthCodeRedemptionReceipt(
                userId: request.userId, humanName: request.humanName, humanEmail: request.humanEmail, nonce: request.nonce,
                accessToken: accessToken,
                issuedAt: now,
                expiresAt: expiresAt,
                scopes: request.scopes,
                clientKey: client.clientId,
                serverId: server.id,
                serverSlug: server.slug,
                role: role
            )
        }
    }

    /// Agent grants retain their separate approval/resource/live-agent rules.
    func redeemAgentRequest(_ attempt: OAuthAgentRedemptionAttempt) throws -> OAuthAgentRedemptionReceipt {
        return try self.state.withLock { ledgerState in
            guard let client = ledgerState.clients.first(where: {
                $0.clientId == attempt.clientId
                    && isUserManaged($0)
                    && ($0.appType != "third_party_global" || $0.enabled)
                    && $0.secretHash == sha256(attempt.clientSecret)
            }) else {
                throw OAuthAuthorizationFailure.invalidClientCredentials
            }
            guard let index = ledgerState.requests.firstIndex(where: { $0.id == attempt.requestId && $0.clientId == client.id && $0.agentId != nil }) else {
                throw OAuthAuthorizationFailure.accessRequestNotFound
            }
            let request = ledgerState.requests[index]
            if let scopeServerId = attempt.scopeServerId, scopeServerId != request.serverId {
                throw OAuthAuthorizationFailure.invalidGrant(.differentServer)
            }
            if request.consumedAt != nil {
                throw OAuthAuthorizationFailure.requestAlreadyConsumed
            }
            guard request.status == "approved" else {
                throw OAuthAuthorizationFailure.authorizationPending
            }
            guard let agentId = request.agentId, let agent = ledgerState.agents[agentId], !agent.deleted else {
                throw OAuthAuthorizationFailure.invalidGrant(.identityUnavailable)
            }
            let resource = attempt.resource.flatMap { $0.isEmpty ? nil : $0 }
            let requiresResource = request.scopes.contains(where: {
                ["agent:event:write", "agent:notification:write", "agent:action_request:write"].contains($0)
            })
            let boundResource: String?
            if requiresResource {
                guard let resource else {
                    throw OAuthAuthorizationFailure.resourceRequired
                }
                guard resource == "urn:raft:server:\(request.serverId):agent-inbound" else {
                    throw OAuthAuthorizationFailure.resourceMismatch
                }
                boundResource = resource
            } else {
                boundResource = resource
            }
            var raw = Data(count: 32)
            for index in raw.indices { raw[index] = UInt8.random(in: 0...255) }
            let accessToken = "slock_at_" + raw.map { String(format: "%02x", $0) }.joined()
            let now = Date()
            ledgerState.tokens.append(AccessToken(
                serverId: request.serverId,
                userId: request.userId,
                clientId: client.id,
                requestId: request.id,
                tokenHash: sha256(accessToken),
                scopes: request.scopes,
                expiresAt: now.addingTimeInterval(60 * 60),
                principalType: "agent",
                agentId: agent.id,
                resource: boundResource
            ))
            ledgerState.requests[index].consumedAt = now
            return OAuthAgentRedemptionReceipt(
                accessToken: accessToken,
                scopes: request.scopes,
                resource: boundResource
            )
        }
    }
}

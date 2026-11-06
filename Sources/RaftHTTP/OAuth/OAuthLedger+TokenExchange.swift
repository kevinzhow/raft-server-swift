import Crypto
import Foundation
import RaftShared

extension OAuthLedger {
    /// `POST /api/oauth/token`. Form fields, camelCase JSON, and HTTP Basic all name the same client.
    public func exchangeToken(
        authorization: String?,
        body: String,
        issuer: String,
        scopeServerId: String? = nil
    ) throws -> OAuthTokenResponse {
        let fields = OAuthRequestParsing.tokenFields(body)
        guard let credentials = OAuthRequestParsing.clientCredentials(authorization: authorization, fields: fields) else {
            throw OAuthLedgerError(.clientCredentialsRequired)
        }
        let grantType = fields["grantType"] ?? fields["grant_type"] ?? ""
        let verifierPresent = fields["code_verifier"] != nil || OAuthRequestParsing.jsonBodyHasKey(body, "code_verifier")
        if grantType == "urn:slock:grant-type:agent_request" {
            if verifierPresent {
                throw OAuthLedgerError(.invalidGrant(.notPKCERequest))
            }
            return try exchangeAgentRequest(fields: fields, credentials: credentials, scopeServerId: scopeServerId)
        }
        guard grantType == "authorization_code" else {
            throw OAuthLedgerError(.unsupportedGrantType)
        }
        let rawCode = (fields["code"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let isOIDC = rawCode.hasPrefix("raft_oidc_")
        if !isOIDC, verifierPresent {
            throw OAuthLedgerError(.invalidGrant(.codeRedirectOrVerifierInvalid))
        }
        let code = isOIDC ? rawCode : rawCode.lowercased()
        guard !code.isEmpty else { throw OAuthLedgerError(.codeRequired) }
        if !isOIDC {
            guard code.wholeMatch(of: /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/) != nil else {
                throw OAuthLedgerError(.invalidGrant(.requestInvalidOrExpired))
            }
        }

        let redeemed = try redeemAuthorizationCode(
            code: code,
            isOIDC: isOIDC,
            verifierPresent: verifierPresent,
            fields: fields,
            credentials: credentials,
            scopeServerId: scopeServerId
        )

        let expiresIn = max(1, Int(redeemed.expiresAt.timeIntervalSince(redeemed.issuedAt)))
        let identity = OAuthIdentity(
            sub: redeemed.request.userId,
            clientId: redeemed.clientKey,
            scopes: redeemed.scopes,
            name: redeemed.request.humanName,
            email: redeemed.request.humanEmail,
            serverId: redeemed.serverId,
            serverSlug: redeemed.serverSlug,
            serverRole: redeemed.role
        )
        var idToken: String?
        if redeemed.scopes.contains("openid") {
            guard let signed = OAuthIDToken.sign(
                identity: identity,
                issuer: issuer,
                expiresIn: expiresIn,
                secret: jwtSecret,
                nonce: isOIDC ? redeemed.request.nonce : nil
            ) else {
                throw OAuthLedgerError(.tokenIssueFailed)
            }
            idToken = signed
        }
        return OAuthTokenResponse(
            accessToken: redeemed.accessToken,
            expiresIn: expiresIn,
            scope: redeemed.scopes.joined(separator: " "),
            idToken: idToken,
            resource: nil
        )
    }

    /// What one successful code redemption produced; the ID token is signed
    /// after the ledger lock is released.
    struct RedeemedAuthorization: Sendable {
        var request: AccessRequest
        var accessToken: String
        var issuedAt: Date
        var expiresAt: Date
        var scopes: [String]
        var clientKey: String
        var serverId: String
        var serverSlug: String
        var role: String
    }

    /// The locked half of `exchangeToken`: validates the code against the
    /// request row, mints the access token and consumes the request in one
    /// critical section.
    func redeemAuthorizationCode(
        code: String,
        isOIDC: Bool,
        verifierPresent: Bool,
        fields: [String: String],
        credentials: (clientId: String, clientSecret: String),
        scopeServerId: String?
    ) throws -> RedeemedAuthorization {
        lock.lock()
        defer { lock.unlock() }
        guard let client = clients.first(where: { $0.clientId == credentials.clientId && $0.appType != "slock_builtin" && $0.secretHash == sha256(credentials.clientSecret) }) else {
            throw OAuthLedgerError(.invalidClientCredentials)
        }
        guard let index = requests.firstIndex(where: { $0.id == code && $0.clientId == client.id }) else {
            if isOIDC {
                throw OAuthLedgerError(.invalidGrant(.requestInvalidOrExpired))
            }
            throw OAuthLedgerError(.accessRequestNotFound)
        }
        let request = requests[index]
        if isOIDC {
            guard request.oidc else {
                throw OAuthLedgerError(.invalidGrant(.codeRedirectOrVerifierInvalid))
            }
            if request.codeChallenge == nil, verifierPresent {
                throw OAuthLedgerError(.invalidGrant(.notPKCERequest))
            }
            if let challenge = request.codeChallenge {
                guard let verifier = fields["code_verifier"], !verifier.isEmpty,
                      challenge == Self.pkceChallenge(verifier)
                else {
                    throw OAuthLedgerError(.invalidGrant(.codeRedirectOrVerifierInvalid))
                }
            }
            if let redirect = request.oidcRedirectURI {
                guard fields["redirect_uri"] == redirect else {
                    throw OAuthLedgerError(.invalidGrant(.codeRedirectOrVerifierInvalid))
                }
            }
        }
        if let scopeServerId, scopeServerId != request.serverId {
            throw OAuthLedgerError(.invalidGrant(.differentServer))
        }
        if request.consumedAt != nil {
            if isOIDC {
                throw OAuthLedgerError(.invalidGrant(.requestInvalidOrExpired))
            }
            throw OAuthLedgerError(.requestAlreadyConsumed)
        }
        let now = Date()
        if now.timeIntervalSince(request.createdAt) > 10 * 60 {
            if isOIDC {
                throw OAuthLedgerError(.invalidGrant(.requestInvalidOrExpired))
            }
            throw OAuthLedgerError(.authorizationCodeExpired)
        }
        guard let server = servers[request.serverId], !server.deleted,
              let role = members["\(request.serverId)\n\(request.userId)"]
        else {
            throw OAuthLedgerError(.invalidGrant(.identityUnavailable))
        }
        var raw = Data(count: 32)
        for index in raw.indices { raw[index] = UInt8.random(in: 0...255) }
        let accessToken = "slock_at_" + raw.map { String(format: "%02x", $0) }.joined()
        let expiresAt = now.addingTimeInterval(60 * 60)
        tokens.append(AccessToken(
            serverId: request.serverId,
            userId: request.userId,
            clientId: client.id,
            requestId: request.id,
            tokenHash: sha256(accessToken),
            scopes: request.scopes,
            expiresAt: expiresAt
        ))
        requests[index].consumedAt = now
        return RedeemedAuthorization(
            request: request,
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

    func exchangeAgentRequest(
        fields: [String: String],
        credentials: (clientId: String, clientSecret: String),
        scopeServerId: String? = nil
    ) throws -> OAuthTokenResponse {
        let requestId = (fields["requestId"] ?? fields["request_id"] ?? "").lowercased()
        guard !requestId.isEmpty else {
            throw OAuthLedgerError(.requestIdRequired)
        }
        guard requestId.wholeMatch(of: /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/) != nil else {
            throw OAuthLedgerError(.invalidGrant(.requestInvalidOrExpired))
        }
        lock.lock()
        defer { lock.unlock() }
        guard let client = clients.first(where: {
            $0.clientId == credentials.clientId
                && isUserManaged($0)
                && ($0.appType != "third_party_global" || $0.enabled)
                && $0.secretHash == sha256(credentials.clientSecret)
        }) else {
            throw OAuthLedgerError(.invalidClientCredentials)
        }
        guard let index = requests.firstIndex(where: { $0.id == requestId && $0.clientId == client.id && $0.agentId != nil }) else {
            throw OAuthLedgerError(.accessRequestNotFound)
        }
        let request = requests[index]
        if let scopeServerId, scopeServerId != request.serverId {
            throw OAuthLedgerError(.invalidGrant(.differentServer))
        }
        if request.consumedAt != nil {
            throw OAuthLedgerError(.requestAlreadyConsumed)
        }
        guard request.status == "approved" else {
            throw OAuthLedgerError(.authorizationPending)
        }
        guard let agentId = request.agentId, let agent = agents[agentId], !agent.deleted else {
            throw OAuthLedgerError(.invalidGrant(.identityUnavailable))
        }
        let resource = fields["resource"].flatMap { $0.isEmpty ? nil : $0 }
        let requiresResource = request.scopes.contains(where: {
            ["agent:event:write", "agent:notification:write", "agent:action_request:write"].contains($0)
        })
        let boundResource: String?
        if requiresResource {
            guard let resource else {
                throw OAuthLedgerError(.resourceRequired)
            }
            guard resource == "urn:raft:server:\(request.serverId):agent-inbound" else {
                throw OAuthLedgerError(.resourceMismatch)
            }
            boundResource = resource
        } else {
            boundResource = resource
        }
        var raw = Data(count: 32)
        for index in raw.indices { raw[index] = UInt8.random(in: 0...255) }
        let accessToken = "slock_at_" + raw.map { String(format: "%02x", $0) }.joined()
        let now = Date()
        tokens.append(AccessToken(
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
        requests[index].consumedAt = now
        return OAuthTokenResponse(
            accessToken: accessToken,
            expiresIn: 3600,
            scope: request.scopes.joined(separator: " "),
            idToken: nil,
            resource: boundResource
        )
    }
}

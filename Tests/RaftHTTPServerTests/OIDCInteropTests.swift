import Crypto
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private let interopVerifier = "oidc-standard-verifier-abcdefghijklmnopqrstuvwxyz-0123456789"
private let interopChallenge = "4lHxhn3RWN1r50LRPOPTsUXp-dh5hd_mKVHMGvXAufY"

private func interopObject(_ response: ClientResponse) throws -> [String: Any] {
    let data = Data((response.body.string ?? "").utf8)
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

private func interopBase64URLData(_ value: String) -> Data? {
    var encoded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while encoded.count % 4 != 0 { encoded += "=" }
    return Data(base64Encoded: encoded)
}

private func interopJWT(_ token: String) -> (header: [String: Any], payload: [String: Any], signingInput: Data, signature: Data)? {
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3,
          let headerData = interopBase64URLData(String(parts[0])),
          let payloadData = interopBase64URLData(String(parts[1])),
          let signature = interopBase64URLData(String(parts[2])),
          let header = (try? JSONSerialization.jsonObject(with: headerData)) as? [String: Any],
          let payload = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any]
    else { return nil }
    return (header, payload, Data("\(parts[0]).\(parts[1])".utf8), signature)
}

private struct OIDCInteropFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let otherServerId: String
    let ownerId: String
    let email: String
    let redirectURI: String
    let clientId: String
    let clientRecordId: String
    let clientSecret: String
}

private func makeOIDCInteropFixture(suffix: String) throws -> OIDCInteropFixture {
    let accounts = EmailLoginDirectory()
    accounts.configureOAuthForTesting { $0.serverURL = "https://api.raft.test" }
    accounts.configureOAuthForTesting { $0.appURL = "https://app.raft.test" }
    let number = Int(suffix) ?? 0
    let serverId = String(format: "33333333-3333-4333-8333-%012d", 100_000 + number)
    let otherServerId = String(format: "33333333-3333-4333-8333-%012d", 200_000 + number)
    let ownerId = String(format: "11111111-1111-4111-8111-%012d", 800_000 + number)
    let email = "oidc-interop-\(suffix)@raft.test"
    let redirectURI = "https://open-webui.example.test/oauth/oidc/callback"
    accounts.addAccount(id: ownerId, email: email, password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "oidc-interop-\(suffix)", name: "OIDC Interop", ownerId: ownerId)
    accounts.oauth.addOwnedServer(id: otherServerId, slug: "other-oidc-interop-\(suffix)", name: "Other OIDC", ownerId: ownerId)
    let created = try accounts.oauth.createClient(
        serverId: serverId,
        createdByUserId: ownerId,
        name: "Open WebUI",
        clientId: "oidc-interop-client-\(suffix)",
        returnUrl: redirectURI,
        allowedScopes: ["openid", "profile", "email"]
    )
    return OIDCInteropFixture(
        accounts: accounts,
        serverId: serverId,
        otherServerId: otherServerId,
        ownerId: ownerId,
        email: email,
        redirectURI: redirectURI,
        clientId: created.clientId,
        clientRecordId: created.id,
        clientSecret: created.clientSecret
    )
}

private func interopLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    #expect(response.status == .ok)
    return try interopObject(response)["accessToken"] as? String ?? ""
}

private func interopAuthorize(
    _ client: any Client,
    session: String,
    body: String
) async throws -> ClientResponse {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(session)"
    headers[.contentType] = "application/json"
    return try await client.send(.post, headers: headers, to: "/api/oauth/authorize/human") { request in
        request.body = .init(string: body)
    }
}

private func interopExchange(
    _ client: any Client,
    fixture: OIDCInteropFixture,
    identifier: String? = nil,
    code: String,
    verifier: String? = nil,
    redirect: String? = nil
) async throws -> ClientResponse {
    let identifier = identifier ?? fixture.clientId
    var headers = HTTPFields()
    headers[.authorization] = "Basic " + Data("\(identifier):\(fixture.clientSecret)".utf8).base64EncodedString()
    headers[.contentType] = "application/x-www-form-urlencoded"
    var fields = [
        "grant_type=authorization_code",
        "code=\(code)",
        "redirect_uri=\(redirect ?? fixture.redirectURI)",
    ]
    if let verifier {
        fields.append("code_verifier=\(verifier)")
    }
    return try await client.send(.post, headers: headers, to: "/api/oauth/token") { request in
        request.body = .init(string: fields.joined(separator: "&"))
    }
}

@Test func oidcStandardInteropCoversLookupAuthorizeTokenAndClaims() async throws {
    let fixture = try makeOIDCInteropFixture(suffix: "701")
    let accounts = fixture.accounts

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let session = try await interopLogin(client, email: fixture.email)

            var lookupHeaders = HTTPFields()
            lookupHeaders[.authorization] = "Bearer \(session)"
            func lookup(_ identifier: String) async throws -> ClientResponse {
                try await client.get(
                    URI(string: "/api/oauth/clients/lookup?client_id=\(identifier)&server_id=\(fixture.serverId)"),
                    headers: lookupHeaders
                )
            }
            let keyLookup = try await lookup(fixture.clientId)
            #expect(keyLookup.status == .ok)
            #expect(try interopObject(keyLookup)["availability"] as? String == "ready")
            #expect(try interopObject(keyLookup)["clientId"] as? String == fixture.clientId)
            #expect(try await lookup(fixture.clientRecordId).status == .notFound)
            #expect(try await lookup("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb").status == .notFound)

            let root = try await client.get("/.well-known/openid-configuration")
            let nested = try await client.get("/api/oauth/.well-known/openid-configuration")
            #expect(root.status == .ok)
            #expect(nested.status == .ok)
            #expect(root.body.string == nested.body.string)
            #expect(root.headers[HTTPField.Name("Cache-Control")!] == "public, max-age=300")
            let discovery = try interopObject(root)
            #expect(discovery["issuer"] as? String == "https://api.raft.test")
            #expect(discovery["authorization_endpoint"] as? String == "https://api.raft.test/api/oauth/authorize")
            #expect(discovery["token_endpoint"] as? String == "https://api.raft.test/api/oauth/token")
            #expect(discovery["userinfo_endpoint"] as? String == "https://api.raft.test/api/oauth/userinfo")
            #expect(discovery["jwks_uri"] as? String == "https://api.raft.test/api/oauth/jwks")
            #expect(discovery["response_types_supported"] as? [String] == ["code"])
            #expect(discovery["id_token_signing_alg_values_supported"] as? [String] == ["ES256"])
            #expect(discovery["code_challenge_methods_supported"] as? [String] == ["S256"])
            #expect((discovery["scopes_supported"] as? [String])?.contains("email") == true)
            #expect((discovery["claims_supported"] as? [String])?.contains("server_slug") == true)

            let authorizeBody = "{\"clientId\":\"\(fixture.clientId)\",\"serverId\":\"\(fixture.serverId)\",\"returnUrl\":\"\(fixture.redirectURI)\",\"scopes\":[\"openid\",\"profile\",\"email\"],\"oidc\":true,\"nonce\":\"interop-nonce\",\"codeChallenge\":\"\(interopChallenge)\",\"codeChallengeMethod\":\"S256\",\"server\":\"oidc-interop-701\"}"
            let wrongServer = try await interopAuthorize(client, session: session, body: "{\"clientId\":\"\(fixture.clientId)\",\"serverId\":\"\(fixture.otherServerId)\",\"returnUrl\":\"\(fixture.redirectURI)\",\"scopes\":[\"openid\",\"profile\",\"email\"],\"oidc\":true}")
            #expect(wrongServer.status == .notFound)
            #expect(try interopObject(wrongServer)["error"] as? String == "OAuth client not found for server")

            let uuidClient = try await interopAuthorize(client, session: session, body: "{\"clientId\":\"\(fixture.clientRecordId)\",\"serverId\":\"\(fixture.serverId)\",\"returnUrl\":\"\(fixture.redirectURI)\",\"scopes\":[\"openid\",\"profile\",\"email\"],\"oidc\":true}")
            #expect(uuidClient.status == .notFound)
            #expect(try interopObject(uuidClient)["error"] as? String == "OAuth client not found for server")

            let mismatchedHint = try await interopAuthorize(client, session: session, body: "{\"clientId\":\"\(fixture.clientId)\",\"serverId\":\"\(fixture.serverId)\",\"returnUrl\":\"\(fixture.redirectURI)\",\"scopes\":[\"openid\",\"profile\",\"email\"],\"oidc\":true,\"server\":\"other-oidc-interop-701\"}")
            #expect(mismatchedHint.status == .badRequest)
            #expect(try interopObject(mismatchedHint)["error"] as? String == "server does not match the selected Server")

            let issued = try await interopAuthorize(client, session: session, body: authorizeBody)
            #expect(issued.status == .ok)
            let code = try interopObject(issued)["code"] as? String ?? ""
            #expect(code.hasPrefix("raft_oidc_"))

            let uuidExchange = try await interopExchange(
                client,
                fixture: fixture,
                identifier: fixture.clientRecordId,
                code: code,
                verifier: interopVerifier
            )
            #expect(uuidExchange.status == .unauthorized)
            #expect(try interopObject(uuidExchange)["error"] as? String == "Invalid client credentials")

            let wrongRedirect = try await interopExchange(
                client,
                fixture: fixture,
                code: code,
                verifier: interopVerifier,
                redirect: "https://attacker.example.test/callback"
            )
            #expect(wrongRedirect.status == .badRequest)
            #expect(try interopObject(wrongRedirect)["error"] as? String == "invalid_grant")

            let wrongVerifier = try await interopExchange(
                client,
                fixture: fixture,
                code: code,
                verifier: "\(interopVerifier)x"
            )
            #expect(wrongVerifier.status == .badRequest)
            #expect(try interopObject(wrongVerifier)["error"] as? String == "invalid_grant")

            let tokenResponse = try await interopExchange(
                client,
                fixture: fixture,
                code: code,
                verifier: interopVerifier
            )
            #expect(tokenResponse.status == .ok)
            #expect((tokenResponse.headers[HTTPField.Name("Cache-Control")!] ?? "").contains("no-store"))
            let tokenBody = try interopObject(tokenResponse)
            #expect(tokenBody["token_type"] as? String == "Bearer")
            #expect((tokenBody["expires_in"] as? Int ?? 0) > 0)
            #expect((tokenBody["scope"] as? String ?? "").split(separator: " ").map(String.init) == ["email", "openid", "profile"])

            let jwks = try await client.get("/api/oauth/jwks")
            let keys = try interopObject(jwks)["keys"] as? [[String: Any]] ?? []
            let jwk = try #require(keys.first)
            let jwt = try #require(interopJWT(tokenBody["id_token"] as? String ?? ""))
            #expect(jwt.header["alg"] as? String == "ES256")
            #expect(jwt.header["kid"] as? String == jwk["kid"] as? String)
            #expect(jwt.payload["iss"] as? String == "https://api.raft.test")
            #expect(jwt.payload["sub"] as? String == fixture.ownerId)
            #expect(jwt.payload["aud"] as? String == fixture.clientId)
            #expect(jwt.payload["nonce"] as? String == "interop-nonce")
            #expect(jwt.payload["name"] as? String == "oidc-interop-701")
            #expect(jwt.payload["email"] as? String == fixture.email)
            #expect(jwt.payload["email_verified"] as? Bool == true)
            #expect(jwt.payload["server_id"] as? String == fixture.serverId)
            #expect(jwt.payload["server_slug"] as? String == "oidc-interop-701")
            let issuedAt = try #require(jwt.payload["iat"] as? Int)
            let expiresAt = try #require(jwt.payload["exp"] as? Int)
            #expect(expiresAt > issuedAt)
            #expect(issuedAt <= Int(Date().timeIntervalSince1970) + 60)

            let x = try #require(interopBase64URLData(jwk["x"] as? String ?? ""))
            let y = try #require(interopBase64URLData(jwk["y"] as? String ?? ""))
            let publicKey = try P256.Signing.PublicKey(x963Representation: Data([0x04]) + x + y)
            let signature = try P256.Signing.ECDSASignature(rawRepresentation: jwt.signature)
            #expect(publicKey.isValidSignature(signature, for: jwt.signingInput))

            let replay = try await interopExchange(
                client,
                fixture: fixture,
                code: code,
                verifier: interopVerifier
            )
            #expect(replay.status == .badRequest)
            #expect(try interopObject(replay)["error"] as? String == "invalid_grant")
            #expect(try interopObject(replay)["next_action"] == nil)
        }
    }
}

@Test func oidcWithoutEmailKeepsOptionalClaimsAndMissingCodesAreInvalidGrant() async throws {
    let fixture = try makeOIDCInteropFixture(suffix: "702")
    let accounts = fixture.accounts

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let session = try await interopLogin(client, email: fixture.email)
            func issueCode(nonce: String) async throws -> String {
                let body = "{\"clientId\":\"\(fixture.clientId)\",\"serverId\":\"\(fixture.serverId)\",\"returnUrl\":\"\(fixture.redirectURI)\",\"scopes\":[\"openid\",\"profile\"],\"oidc\":true,\"nonce\":\"\(nonce)\",\"server\":\"oidc-interop-702\"}"
                let response = try await interopAuthorize(client, session: session, body: body)
                #expect(response.status == .ok)
                return try interopObject(response)["code"] as? String ?? ""
            }

            let noEmailCode = try await issueCode(nonce: "no-email-nonce")
            let noEmailExchange = try await interopExchange(client, fixture: fixture, code: noEmailCode)
            #expect(noEmailExchange.status == .ok)
            let noEmailBody = try interopObject(noEmailExchange)
            let noEmailJWT = try #require(interopJWT(noEmailBody["id_token"] as? String ?? ""))
            #expect(noEmailJWT.payload["aud"] as? String == fixture.clientId)
            #expect(noEmailJWT.payload["nonce"] as? String == "no-email-nonce")
            #expect(noEmailJWT.payload["email"] == nil)
            #expect(noEmailJWT.payload["email_verified"] == nil)

            let jwks = try await client.get("/api/oauth/jwks")
            let jwk = try #require((try interopObject(jwks)["keys"] as? [[String: Any]] ?? []).first)
            let x = try #require(interopBase64URLData(jwk["x"] as? String ?? ""))
            let y = try #require(interopBase64URLData(jwk["y"] as? String ?? ""))
            let publicKey = try P256.Signing.PublicKey(x963Representation: Data([0x04]) + x + y)
            let signature = try P256.Signing.ECDSASignature(rawRepresentation: noEmailJWT.signature)
            #expect(publicKey.isValidSignature(signature, for: noEmailJWT.signingInput))

            var bearerHeaders = HTTPFields()
            bearerHeaders[.authorization] = "Bearer \(noEmailBody["access_token"] as? String ?? "")"
            let userinfo = try await client.get("/api/oauth/userinfo", headers: bearerHeaders)
            #expect(userinfo.status == .ok)
            #expect(try interopObject(userinfo)["sub"] as? String == fixture.ownerId)
            #expect(try interopObject(userinfo)["email"] == nil)
            #expect(try interopObject(userinfo)["email_verified"] == nil)

            let missingCode = try await issueCode(nonce: "missing-row-nonce")
            accounts.oauth.removeAuthorizationCodeForTesting(id: missingCode)
            let missing = try await interopExchange(
                client,
                fixture: fixture,
                code: missingCode
            )
            #expect(missing.status == .badRequest)
            #expect(try interopObject(missing)["error"] as? String == "invalid_grant")
            #expect(try interopObject(missing)["next_action"] == nil)
        }
    }
}

import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private func bodyText(_ response: ClientResponse) -> String {
    response.body.string ?? ""
}

@Test func oauthTokenEndpointAcceptsPostBodyAndBasicClientAuth() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111195"
    let serverId = "33333333-3333-4333-8333-333333333387"
    accounts.addAccount(id: userId, email: "oauth-token-195@slock.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "oauth-token-auth-195", name: "OAuth Token Auth", ownerId: userId)
    let created = try accounts.oauth.createClient(
        serverId: serverId,
        createdByUserId: userId,
        name: "OAuth Token Auth Client",
        clientId: "oauth-token-auth-195"
    )
    #expect(created.clientSecret.wholeMatch(of: /^raft_secret_[0-9a-f]{48}$/) != nil)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"oauth-token-195@slock.test\",\"password\":\"password123\"}")
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let authorization = "Bearer \(token)"

            let issueCode = { () async throws -> String in
                var headers = HTTPFields()
                headers[.authorization] = authorization
                headers[.contentType] = "application/json"
                let authorize = try await client.send(.post, headers: headers, to: "/api/oauth/authorize/human") { request in
                    request.body = .init(string: "{\"clientId\":\(jsonString(created.clientId)),\"serverId\":\(jsonString(serverId)),\"scopes\":[\"openid\",\"profile\"]}")
                }
                #expect(authorize.status == .ok)
                let body = try JSONSerialization.jsonObject(with: Data(bodyText(authorize).utf8)) as? [String: Any]
                return body?["code"] as? String ?? ""
            }

            var formHeaders = HTTPFields()
            formHeaders[.contentType] = "application/x-www-form-urlencoded"
            let formCode = try await issueCode()
            let standard = try await client.send(.post, headers: formHeaders, to: "/api/oauth/token") { request in
                request.body = .init(string: "client_id=\(created.clientId)&client_secret=\(created.clientSecret)&grant_type=authorization_code&code=\(formCode)")
            }
            try expectAccessToken(standard, scope: "openid profile")

            var legacyHeaders = HTTPFields()
            legacyHeaders[.contentType] = "application/json"
            let legacyCode = try await issueCode()
            let legacy = try await client.send(.post, headers: legacyHeaders, to: "/api/oauth/token") { request in
                request.body = .init(string: "{\"clientId\":\(jsonString(created.clientId)),\"clientSecret\":\(jsonString(created.clientSecret)),\"grantType\":\"authorization_code\",\"code\":\(jsonString(legacyCode))}")
            }
            try expectAccessToken(legacy, scope: "openid profile")

            let basicCode = try await issueCode()
            let pair = Data("\(created.clientId):\(created.clientSecret)".utf8).base64EncodedString()
            var basicHeaders = HTTPFields()
            basicHeaders[.authorization] = "Basic \(pair)"
            basicHeaders[.contentType] = "application/json"
            let basic = try await client.send(.post, headers: basicHeaders, to: "/api/oauth/token") { request in
                request.body = .init(string: "{\"grant_type\":\"authorization_code\",\"code\":\(jsonString(basicCode))}")
            }
            try expectAccessToken(basic, scope: "openid profile")
        }
    }
}

@Test func expiredHumanAuthorizationCodeIsRejectedAndMintsNoToken() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111196"
    let serverId = "33333333-3333-4333-8333-333333333388"
    accounts.addAccount(id: userId, email: "oauth-expired-196@slock.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "oauth-expired-196", name: "OAuth Expired Code", ownerId: userId)
    let created = try accounts.oauth.createClient(
        serverId: serverId,
        createdByUserId: userId,
        name: "OAuth Expired Code Client",
        clientId: "oauth-expired-196"
    )

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"oauth-expired-196@slock.test\",\"password\":\"password123\"}")
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            let authorize = try await client.send(.post, headers: headers, to: "/api/oauth/authorize/human") { request in
                request.body = .init(string: "{\"clientId\":\(jsonString(created.clientId)),\"serverId\":\(jsonString(serverId)),\"scopes\":[\"openid\",\"profile\"]}")
            }
            #expect(authorize.status == .ok)
            let code = ((try JSONSerialization.jsonObject(with: Data(bodyText(authorize).utf8)) as? [String: Any])?["code"] as? String) ?? ""
            accounts.oauth.expireAuthorizationCode(id: code)

            var tokenHeaders = HTTPFields()
            tokenHeaders[.contentType] = "application/json"
            let expired = try await client.send(.post, headers: tokenHeaders, to: "/api/oauth/token") { request in
                request.body = .init(string: "{\"clientId\":\(jsonString(created.clientId)),\"clientSecret\":\(jsonString(created.clientSecret)),\"grantType\":\"authorization_code\",\"code\":\(jsonString(code))}")
            }
            #expect(expired.status == .badRequest)
            let body = try JSONSerialization.jsonObject(with: Data(bodyText(expired).utf8)) as? [String: Any]
            #expect(body?["error"] as? String == "authorization_code_expired")
            #expect(body?["error_description"] as? String == "This Login with Raft authorization code has expired. Obtain a fresh human authorization before retrying.")
            #expect(body?["next_action"] as? String == "obtain_fresh_authorization")
            #expect(accounts.oauth.accessTokenCount(requestId: code) == 0)
        }
    }
}

@Test func installationTokenIsMintedForAnActiveInstall() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111197"
    let serverId = "33333333-3333-4333-8333-333333333389"
    accounts.addAccount(id: userId, email: "oauth-install-197@slock.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "oauth-install-197", name: "OAuth Installation Boundary", ownerId: userId)
    let created = try accounts.oauth.createClient(
        serverId: serverId,
        createdByUserId: userId,
        name: "OAuth Installation Boundary Client",
        clientId: "oauth-install-197",
        appType: "third_party_global"
    )
    let installationId = accounts.oauth.installClient(
        serverId: serverId,
        clientRecordId: created.id,
        installedByUserId: userId,
        groups: ["server"]
    )

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            let minted = try await client.send(.post, headers: headers, to: "/api/oauth/installation-token") { request in
                request.body = .init(string: "{\"client_id\":\(jsonString(created.clientId)),\"client_secret\":\(jsonString(created.clientSecret)),\"installation_id\":\(jsonString(installationId))}")
            }
            #expect(minted.status == .ok)
            #expect(minted.headers[HTTPField.Name("Cache-Control")!] == "private, no-store")
            let body = try JSONSerialization.jsonObject(with: Data(bodyText(minted).utf8)) as? [String: Any]
            let accessToken = body?["access_token"] as? String ?? ""
            #expect(accessToken.hasPrefix("raft_installation_"))
            #expect(body?["token_type"] as? String == "Bearer")
            #expect(body?["installation_id"] as? String == installationId)
            #expect(body?["server_id"] as? String == serverId)
            #expect((body?["expires_in"] as? NSNumber)?.intValue == 600 || (body?["expires_in"] as? Int) == 600)
        }
    }
}

@Test func installationTokenIsRejectedByTheOAuthPrincipalSurfaces() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111198"
    let serverId = "33333333-3333-4333-8333-333333333390"
    accounts.addAccount(id: userId, email: "oauth-boundary-198@slock.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "oauth-boundary-198", name: "OAuth Principal Boundary", ownerId: userId)
    let created = try accounts.oauth.createClient(
        serverId: serverId,
        createdByUserId: userId,
        name: "OAuth Principal Boundary Client",
        clientId: "oauth-boundary-198",
        appType: "third_party_global"
    )
    let installationId = accounts.oauth.installClient(
        serverId: serverId,
        clientRecordId: created.id,
        installedByUserId: userId,
        groups: ["server"]
    )

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var mintHeaders = HTTPFields()
            mintHeaders[.contentType] = "application/json"
            let minted = try await client.send(.post, headers: mintHeaders, to: "/api/oauth/installation-token") { request in
                request.body = .init(string: "{\"client_id\":\(jsonString(created.clientId)),\"client_secret\":\(jsonString(created.clientSecret)),\"installation_id\":\(jsonString(installationId))}")
            }
            #expect(minted.status == .ok)
            let accessToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(minted).utf8)) as? [String: Any])?["access_token"] as? String) ?? ""

            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(accessToken)"
            let userinfo = try await client.send(.get, headers: headers, to: "/api/oauth/userinfo")
            #expect(userinfo.status == .unauthorized)

            let agents = try await client.send(.get, headers: headers, to: "/api/oauth/agents")
            #expect(agents.status == .unauthorized)
            let agentsBody = try JSONSerialization.jsonObject(with: Data(bodyText(agents).utf8)) as? [String: Any]
            #expect(agentsBody?["agents"] == nil)
        }
    }
}

@Test func malformedAgentRequestIdsAreRejectedBeforeLookup() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111211"
    let serverId = "33333333-3333-4333-8333-333333333405"
    accounts.oauth.addOwnedServer(id: serverId, slug: "oauth-malformed-211", name: "OAuth Malformed Request", ownerId: ownerId)
    let created = try accounts.oauth.createClient(
        serverId: serverId,
        createdByUserId: ownerId,
        name: "OAuth Malformed Request Client",
        clientId: "oauth-malformed-211"
    )

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            let malformed = try await client.send(.post, headers: headers, to: "/api/oauth/token") { request in
                request.body = .init(string: "{\"clientId\":\"\(created.clientId)\",\"clientSecret\":\"\(created.clientSecret)\",\"grantType\":\"urn:slock:grant-type:agent_request\",\"requestId\":\"garbage-test-123\"}")
            }
            #expect(malformed.status == .badRequest)
            let malformedBody = try JSONSerialization.jsonObject(with: Data(bodyText(malformed).utf8)) as? [String: Any]
            #expect(malformedBody?["error"] as? String == "invalid_grant")
            #expect(malformedBody?["error_description"] as? String == "The authorization request is invalid or has expired")

            let missing = try await client.send(.post, headers: headers, to: "/api/oauth/token") { request in
                request.body = .init(string: "{\"clientId\":\"\(created.clientId)\",\"clientSecret\":\"\(created.clientSecret)\",\"grantType\":\"urn:slock:grant-type:agent_request\",\"requestId\":\"\(UUID().uuidString.lowercased())\"}")
            }
            #expect(missing.status == .notFound)
            let missingBody = try JSONSerialization.jsonObject(with: Data(bodyText(missing).utf8)) as? [String: Any]
            #expect(missingBody?["error"] as? String == "Access request not found")
        }
    }
}

private func expectAccessToken(_ response: ClientResponse, scope: String) throws {
    #expect(response.status == .ok)
    let body = try JSONSerialization.jsonObject(with: Data(bodyText(response).utf8)) as? [String: Any]
    let accessToken = body?["access_token"] as? String ?? ""
    #expect(accessToken.hasPrefix("slock_at_"))
    #expect(body?["token_type"] as? String == "Bearer")
    #expect(body?["scope"] as? String == scope)
    let expiresIn = (body?["expires_in"] as? NSNumber)?.intValue ?? body?["expires_in"] as? Int
    #expect((expiresIn ?? 0) > 0)
    #expect((body?["id_token"] as? String)?.isEmpty == false)
}

private func postJSON(_ client: any Client, path: String, body: String) async throws -> ClientResponse {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    return try await client.send(.post, headers: headers, to: URI(string: path)) { request in
        request.body = .init(string: body)
    }
}

private func jsonString(_ value: String) -> String {
    let data = try? JSONSerialization.data(withJSONObject: [value])
    let wrapped = data.flatMap { String(decoding: $0, as: UTF8.self) } ?? "[\"\"]"
    return String(wrapped.dropFirst().dropLast())
}

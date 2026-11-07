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
            let serverinfo = try await client.send(.get, headers: headers, to: "/api/oauth/serverinfo")
            #expect(serverinfo.status == .unauthorized)

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

private func protocolTokenObject(_ response: ClientResponse) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(bodyText(response).utf8)) as? [String: Any])
}

private struct ProtocolTokenFixture: Sendable {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111646"
    let serverId = "33333333-3333-4333-8333-333333333672"
    let app: CreatedOAuthClient

    init(global: Bool = false) throws {
        accounts.addAccount(id: ownerId, email: "token-protocol-646@test.invalid", password: "password123")
        accounts.markEmailVerified(userId: ownerId)
        accounts.oauth.addOwnedServer(id: serverId, slug: "token-protocol-646", name: "Token Protocol", ownerId: ownerId)
        app = try accounts.oauth.createClient(serverId: serverId, createdByUserId: ownerId,
            name: "Token Protocol App", clientId: "token-protocol-client-646", appType: global ? "third_party_global" : "server_local")
        if global {
            _ = accounts.oauth.installClient(serverId: serverId, clientRecordId: app.id, installedByUserId: ownerId, groups: [])
        }
    }

    func login(_ client: any Client) async throws -> String {
        let response = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"token-protocol-646@test.invalid\",\"password\":\"password123\"}")
        #expect(response.status == .ok)
        return try #require(try protocolTokenObject(response)["accessToken"] as? String)
    }

    func code(_ client: any Client, session: String, scopes: String = "\"openid\",\"profile\"") async throws -> String {
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        headers[.authorization] = "Bearer \(session)"
        let response = try await client.send(.post, headers: headers, to: "/api/oauth/authorize/human") {
            $0.body = .init(string: "{\"clientId\":\"\(app.clientId)\",\"serverId\":\"\(serverId)\",\"scopes\":[\(scopes)]}")
        }
        #expect(response.status == .ok)
        return try #require(try protocolTokenObject(response)["code"] as? String)
    }

    func body(code: String) -> String {
        "{\"clientId\":\"\(app.clientId)\",\"clientSecret\":\"\(app.clientSecret)\",\"grantType\":\"authorization_code\",\"code\":\"\(code)\"}"
    }
}

@Test func oauthProtocolTokenParsersKeepFallbackPrecedenceAndLeaveRefusalsUnconsumed() async throws {
    let f = try ProtocolTokenFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let session = try await f.login(client)
            let code = try await f.code(client, session: session)
            let credentials = "\"clientId\":\"\(f.app.clientId)\",\"clientSecret\":\"\(f.app.clientSecret)\""
            let emptySecret = "Basic " + Data("\(f.app.clientId):".utf8).base64EncodedString()
            let cases: [(String, String?, HTTPResponse.Status, String)] = [
                (f.body(code: code), emptySecret, .unauthorized, "{\"error\":\"Invalid client credentials\"}"),
                ("{\"client_id\":\"\",\(credentials),\"grantType\":\"authorization_code\",\"code\":\"\(code)\"}", nil, .unauthorized, "{\"error\":\"Client credentials are required\"}"),
                ("{\(credentials),\"grantType\":\"\",\"grant_type\":\"authorization_code\",\"code\":\"\(code)\"}", nil, .badRequest, "{\"error\":\"Unsupported grant type\"}"),
                ("{\"clientId\":\"missing-client\",\"clientSecret\":\"wrong\",\"grantType\":\"unsupported\"}", nil, .badRequest, "{\"error\":\"Unsupported grant type\"}"),
                ("{\"grantType\":\"unsupported\"}", nil, .unauthorized, "{\"error\":\"Client credentials are required\"}"),
                ("{\"clientId\":\"missing-client\",\"clientSecret\":\"wrong\",\"grantType\":\"authorization_code\",\"code\":\"malformed\"}", nil, .badRequest,
                 "{\"error\":\"invalid_grant\",\"error_description\":\"The authorization request is invalid or has expired\"}"),
            ]
            for (body, authorization, status, expected) in cases {
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                headers[.authorization] = authorization
                let response = try await client.send(.post, headers: headers, to: "/api/oauth/token") { $0.body = .init(string: body) }
                #expect(response.status == status)
                #expect(response.body.string == expected)
                #expect(response.headers[HTTPField.Name("Cache-Control")!] == nil)
            }
            try expectAccessToken(try await postJSON(client, path: "/api/oauth/token", body: f.body(code: code)), scope: "openid profile")
            for malformedJSON in [false, true] {
                let fresh = try await f.code(client, session: session)
                var headers = HTTPFields()
                headers[.contentType] = malformedJSON ? "application/json" : "application/x-www-form-urlencoded"
                let body = malformedJSON
                    ? "{&client_id=\(f.app.clientId)&client_secret=\(f.app.clientSecret)&grant_type=authorization_code&code=\(fresh)"
                    : "client_id=wrong&client%5Fid=\(f.app.clientId)&client_secret=wrong&client_secret=\(f.app.clientSecret)&grant_type=wrong&grant_type=authorization_code&code=+\(fresh.uppercased())+"
                let response = try await client.send(.post, headers: headers, to: "/api/oauth/token") { $0.body = .init(string: body) }
                try expectAccessToken(response, scope: "openid profile")
                #expect(response.headers[HTTPField.Name("Cache-Control")!] == "no-store")
            }
            let lowerBasic = "basic " + Data("\(f.app.clientId):wrong".utf8).base64EncodedString()
            for authorization in ["Basic !!!", lowerBasic] {
                let fresh = try await f.code(client, session: session)
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                headers[.authorization] = authorization
                let response = try await client.send(.post, headers: headers, to: "/api/oauth/token") { $0.body = .init(string: f.body(code: fresh)) }
                try expectAccessToken(response, scope: "openid profile")
            }
        }
    }
}

@Test(arguments: ["disabled-global", "aged", "member-removed", "server-deleted", "uninstalled"])
func oauthProtocolGrantsKeepTheirDifferentLiveEligibility(change: String) async throws {
    let f = try ProtocolTokenFixture(global: true)
    let agentId = f.accounts.oauth.createAgent(serverId: f.serverId, name: "GrantBot", creatorUserId: f.ownerId)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let session = try await f.login(client)
            let humanCode = try await f.code(client, session: session, scopes: "\"profile\"")
            let requested = try await postJSON(client, path: "/api/oauth/requests/agent",
                body: "{\"clientId\":\"\(f.app.clientId)\",\"clientSecret\":\"\(f.app.clientSecret)\",\"serverSlug\":\"token-protocol-646\",\"agentId\":\"\(agentId)\",\"scopes\":[\"profile\"]}")
            #expect(requested.status == .ok)
            #expect(try protocolTokenObject(requested)["status"] as? String == "approved")
            let requestId = try #require(try protocolTokenObject(requested)["requestId"] as? String)
            switch change {
            case "disabled-global": f.accounts.oauth.setClientEnabled(clientRecordId: f.app.id, enabled: false)
            case "aged":
                f.accounts.oauth.expireAuthorizationCode(id: humanCode)
                f.accounts.oauth.expireAuthorizationCode(id: requestId)
            case "member-removed": f.accounts.oauth.removeMember(serverId: f.serverId, userId: f.ownerId)
            case "server-deleted": f.accounts.oauth.deleteServer(id: f.serverId)
            case "uninstalled": _ = f.accounts.oauth.uninstallClient(serverId: f.serverId, clientRecordId: f.app.id)
            default: Issue.record("unknown eligibility scenario"); return
            }
            func expectProfileToken(_ response: ClientResponse) throws {
                #expect(response.status == .ok)
                let body = try protocolTokenObject(response)
                #expect((body["access_token"] as? String)?.hasPrefix("slock_at_") == true)
                #expect(body["scope"] as? String == "profile")
                #expect(body["expires_in"] as? Int == 3600)
                #expect(body["id_token"] == nil)
                #expect(response.headers[HTTPField.Name("Cache-Control")!] == "no-store")
            }
            let human = try await postJSON(client, path: "/api/oauth/token", body: f.body(code: humanCode))
            if change == "aged" {
                #expect(human.status == .badRequest)
                #expect(human.body.string == "{\"error\":\"authorization_code_expired\",\"error_description\":\"This Login with Raft authorization code has expired. Obtain a fresh human authorization before retrying.\",\"next_action\":\"obtain_fresh_authorization\"}")
                #expect(human.headers[HTTPField.Name("Cache-Control")!] == nil)
            } else if change == "member-removed" || change == "server-deleted" {
                #expect(human.status == .badRequest)
                #expect(human.body.string == "{\"error\":\"invalid_grant\",\"error_description\":\"The authorization identity is no longer available\"}")
                #expect(human.headers[HTTPField.Name("Cache-Control")!] == nil)
            } else {
                try expectProfileToken(human)
            }
            let agentBody = "{\"clientId\":\"\(f.app.clientId)\",\"clientSecret\":\"\(f.app.clientSecret)\",\"grantType\":\"urn:slock:grant-type:agent_request\",\"requestId\":\"\(requestId)\"}"
            let agent = try await postJSON(client, path: "/api/oauth/token", body: agentBody)
            if change == "disabled-global" {
                #expect(agent.status == .unauthorized)
                #expect(agent.body.string == "{\"error\":\"Invalid client credentials\"}")
                #expect(agent.headers[HTTPField.Name("Cache-Control")!] == nil)
                f.accounts.oauth.setClientEnabled(clientRecordId: f.app.id, enabled: true)
                try expectProfileToken(try await postJSON(client, path: "/api/oauth/token", body: agentBody))
            } else {
                try expectProfileToken(agent)
            }
        }
    }
}

import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func oauthClientAuthenticationAcceptsLegacySlockSecretThroughTheTokenEndpoint() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111647"
    let serverId = "33333333-3333-4333-8333-333333333687"
    accounts.addAccount(id: userId, email: "oauth-legacy-secret@slock.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "oauth-legacy-secret", name: "OAuth Legacy Secret", ownerId: userId)
    let created = try accounts.oauth.createClient(
        serverId: serverId,
        createdByUserId: userId,
        name: "OAuth Legacy Secret Client",
        clientId: "oauth-legacy-secret"
    )
    #expect(created.clientSecret.wholeMatch(of: /^raft_secret_[0-9a-f]{48}$/) != nil)
    let legacySecret = "slock_secret_" + String(repeating: "a", count: 48)
    accounts.oauth.setClientSecretForTesting(clientRecordId: created.id, secret: legacySecret)

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let login = try await client.send(.post, headers: [.contentType: "application/json"], to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"oauth-legacy-secret@slock.test\",\"password\":\"password123\"}")
            }
            #expect(login.status == .ok)
            let loginBody = (try? JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            let access = loginBody["accessToken"] as? String ?? ""
            #expect(!access.isEmpty)

            let issueCode = { () async throws -> String in
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(access)"
                headers[.contentType] = "application/json"
                let response = try await client.send(.post, headers: headers, to: "/api/oauth/authorize/human") { request in
                    request.body = .init(string: "{\"clientId\":\"oauth-legacy-secret\",\"serverId\":\"\(serverId)\",\"scopes\":[\"openid\",\"profile\"]}")
                }
                #expect(response.status == .ok)
                let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
                return body["code"] as? String ?? ""
            }

            let legacyCode = try await issueCode()
            let pair = Data("oauth-legacy-secret:\(legacySecret)".utf8).base64EncodedString()
            var legacyHeaders = HTTPFields()
            legacyHeaders[.authorization] = "Basic \(pair)"
            legacyHeaders[.contentType] = "application/json"
            let legacyCodeJSON = String(decoding: try JSONEncoder().encode(legacyCode), as: UTF8.self)
            let legacy = try await client.send(.post, headers: legacyHeaders, to: "/api/oauth/token") { request in
                request.body = .init(string: "{\"grant_type\":\"authorization_code\",\"code\":\(legacyCodeJSON)}")
            }
            #expect(legacy.status == .ok, Comment(rawValue: legacy.body.string ?? ""))
            let legacyBody = (try? JSONSerialization.jsonObject(with: Data((legacy.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            #expect(legacyBody["access_token"] as? String != nil)

            let raftCode = try await issueCode()
            let raftPair = Data("oauth-legacy-secret:\(created.clientSecret)".utf8).base64EncodedString()
            var raftHeaders = HTTPFields()
            raftHeaders[.authorization] = "Basic \(raftPair)"
            raftHeaders[.contentType] = "application/json"
            let raftCodeJSON = String(decoding: try JSONEncoder().encode(raftCode), as: UTF8.self)
            let rejected = try await client.send(.post, headers: raftHeaders, to: "/api/oauth/token") { request in
                request.body = .init(string: "{\"grant_type\":\"authorization_code\",\"code\":\(raftCodeJSON)}")
            }
            #expect(rejected.status == .unauthorized || rejected.status == .badRequest)
        }
    }
}

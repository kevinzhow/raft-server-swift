import TestSupport
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct ContendedOAuthReply: Sendable {
    var status: Int
    var body: String
}

private struct AgentRequestWire: Decodable, Sendable {
    var requestId: String
    var status: String
}

private struct AccessTokenWire: Decodable, Sendable {
    var access_token: String
}

private func contendOAuth(_ client: any Client, path: String, body: String) async throws -> [ContendedOAuthReply] {
    var mutableHeaders = HTTPFields()
    mutableHeaders[.contentType] = "application/json"
    let headers = mutableHeaders
    return try await withThrowingTaskGroup(of: ContendedOAuthReply.self) { group in
        for _ in 0..<32 {
            group.addTask {
                let response = try await client.send(.post, headers: headers, to: URI(string: path)) {
                    $0.body = .init(string: body)
                }
                return ContendedOAuthReply(status: response.status.code, body: response.body.string ?? "")
            }
        }
        var replies: [ContendedOAuthReply] = []
        for try await reply in group { replies.append(reply) }
        return replies
    }
}

@Test(arguments: [false, true])
func oauthStateCodeConsumptionHasOneWinnerUnderContention(oidc: Bool) async throws {
    let accounts = EmailLoginDirectory()
    accounts.configureOAuthForTesting { $0.serverURL = "https://api.raft.test" }
    let serverId = UUID().uuidString.lowercased()
    let ownerId = UUID().uuidString.lowercased()
    accounts.oauth.addOwnedServer(id: serverId, slug: "state-code", name: "Code", ownerId: ownerId)
    let app = try accounts.oauth.createClient(serverId: serverId, createdByUserId: ownerId, name: "App",
        clientId: "state-code", returnUrl: "https://rp.test/callback")
    let oidcFields = oidc ? ",\"oidc\":true,\"nonce\":\"state-nonce\",\"codeChallenge\":\"4lHxhn3RWN1r50LRPOPTsUXp-dh5hd_mKVHMGvXAufY\",\"codeChallengeMethod\":\"S256\"" : ""
    let code = try accounts.oauthAuthorization.issueHumanAuthorization(
        session: .user(OAuthHuman(id: ownerId, email: "owner@raft.test", name: "Owner")),
        body: "{\"clientId\":\"state-code\",\"serverId\":\"\(serverId)\",\"scopes\":[\"openid\",\"profile\"]\(oidcFields)}"
    ).code
    let verifier = oidc ? ",\"redirect_uri\":\"https://rp.test/callback\",\"code_verifier\":\"oidc-standard-verifier-abcdefghijklmnopqrstuvwxyz-0123456789\"" : ""
    let body = "{\"clientId\":\"state-code\",\"clientSecret\":\"\(app.clientSecret)\",\"grantType\":\"authorization_code\",\"code\":\"\(code)\"\(verifier)}"
    try await withApp { application in
        try await application.register(collection: OAuthFeature(services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        )))
        try await application.testing { client in
            let replies = try await contendOAuth(client, path: "/api/oauth/token", body: body)
            #expect(replies.filter { $0.status == 200 }.count == 1)
            let refusal = oidc
                ? "{\"error\":\"invalid_grant\",\"error_description\":\"The authorization request is invalid or has expired\"}"
                : "{\"error\":\"request_already_consumed\",\"error_description\":\"This Login with Raft request is one-time and has already been exchanged. Discard it and obtain a fresh request before retrying.\",\"next_action\":\"obtain_fresh_request\"}"
            #expect(replies.filter { $0.status == (oidc ? 400 : 409) && $0.body == refusal }.count == 31)
            #expect(accounts.oauth.accessTokenCount(requestId: code) == 1)
            let winner = try #require(replies.first { $0.status == 200 })
            let token = try JSONDecoder().decode(AccessTokenWire.self, from: Data(winner.body.utf8))
            var bearer = HTTPFields()
            bearer[.authorization] = "Bearer \(token.access_token)"
            #expect(try await client.get("/api/oauth/userinfo", headers: bearer).status == .ok)
        }
    }
}

@Test func oauthStateAgentGrantAndRequestConsumptionRemainAtomic() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = UUID().uuidString.lowercased()
    let ownerId = UUID().uuidString.lowercased()
    accounts.oauth.addOwnedServer(id: serverId, slug: "state-agent", name: "Agent", ownerId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "Bot", creatorUserId: ownerId)
    let app = try accounts.oauth.createClient(serverId: serverId, createdByUserId: ownerId, name: "App", clientId: "state-agent")
    let body = "{\"clientId\":\"state-agent\",\"clientSecret\":\"\(app.clientSecret)\",\"serverSlug\":\"state-agent\",\"agentId\":\"\(agentId)\",\"scopes\":[\"openid\",\"profile\"]}"
    try await withApp { application in
        try await application.register(collection: OAuthFeature(services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        )))
        try await application.testing { client in
            let replies = try await contendOAuth(client, path: "/api/oauth/requests/agent", body: body)
            #expect(replies.allSatisfy { $0.status == 200 })
            let requests = try replies.map { try JSONDecoder().decode(AgentRequestWire.self, from: Data($0.body.utf8)) }
            #expect(requests.allSatisfy { $0.status == "approved" })
            #expect(Set(requests.map(\.requestId)).count == 32)
            let grants = try #require(accounts.oauth.agentGrantListVisible(userId: ownerId, agentId: agentId))
            #expect(grants.count == 1)
            let requestId = try #require(requests.first?.requestId)
            let exchanged = try await contendOAuth(client, path: "/api/oauth/token", body: "{\"clientId\":\"state-agent\",\"clientSecret\":\"\(app.clientSecret)\",\"grantType\":\"urn:slock:grant-type:agent_request\",\"requestId\":\"\(requestId)\"}")
            #expect(exchanged.filter { $0.status == 200 }.count == 1)
            #expect(exchanged.filter { $0.status == 409 }.count == 31)
            #expect(accounts.oauth.accessTokenCount(requestId: requestId) == 1)

            let grant = try #require(grants.first)
            #expect(accounts.oauth.revokeAgentGrant(userId: ownerId, grantId: grant.id) == .done)
            let blocked = try await contendOAuth(client, path: "/api/oauth/requests/agent", body: body)
            let blockedRequests = try blocked.map { try JSONDecoder().decode(AgentRequestWire.self, from: Data($0.body.utf8)) }
            #expect(blockedRequests.allSatisfy { $0.status == "pending" })
            #expect(accounts.oauth.agentGrantListVisible(userId: ownerId, agentId: agentId)?.isEmpty == true)

            let created = await withTaskGroup(of: Bool.self) { group in
                for _ in 0..<32 {
                    group.addTask {
                        accounts.oauth.createAgentGrant(userId: ownerId, agentId: agentId, clientRecordId: app.id, scopes: ["openid", "profile"])?.created == true
                    }
                }
                var wins = 0
                for await won in group where won { wins += 1 }
                return wins
            }
            #expect(created == 1)
            #expect(accounts.oauth.agentGrantListVisible(userId: ownerId, agentId: agentId)?.count == 1)
        }
    }
}

import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private func makePrepareFixture() -> (accounts: EmailLoginDirectory, key: String, channelName: String, serverId: String) {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111651"
    let serverId = "33333333-3333-4333-8333-333333333691"
    accounts.addAccount(id: ownerId, email: "prepare-action@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "prepare-action", name: "Prepare Action", ownerId: ownerId)
    let channelName = "prepare-action"
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: channelName, creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: channelName)
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "PrepareBot", creatorUserId: ownerId, runtime: "claude")
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: agentId, kind: "channel", name: channelName)
    accounts.oauth.addChannelAgent(channelId: channelId, agentId: agentId)
    let key = accounts.mintAgentCredential(agentId: agentId, scopes: ["send", "read"], name: "prepare")
    return (accounts, key, channelName, serverId)
}

@Test func genericPrepareRejectsIntegrationApprovalCards() async throws {
    let f = makePrepareFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(f.key)"
            headers[.contentType] = "application/json"
            let payload: [String: Any] = [
                "target": "#\(f.channelName)",
                "action": [
                    "type": "integration:approve_agent_login",
                    "requestId": UUID().uuidString.lowercased(),
                    "agentName": "Spoofed Agent",
                ],
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            let response = try await client.send(.post, headers: headers, to: "/internal/agent-api/prepare-action") { request in
                request.body = .init(data: data)
            }
            #expect(response.status == .badRequest)
            let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            #expect(body["errorCode"] as? String == "ACTION_TYPE_NOT_PREPARABLE")
            #expect((body["error"] as? String)?.contains("raft integration commands") == true)
        }
    }
}

@Test func integrationAppPrepareRejectsUnsafeIpv6ScopesAndCategories() async throws {
    let f = makePrepareFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(f.key)"
            headers[.contentType] = "application/json"
            func prepare(_ extra: [String: Any]) async throws -> (HTTPResponse.Status, [String: Any]) {
                var payload: [String: Any] = [
                    "mode": "register",
                    "target": "#\(f.channelName)",
                    "name": "Demo",
                    "clientKey": "demo-app-\(UUID().uuidString.prefix(6).lowercased())",
                    "scopes": ["openid"],
                ]
                for (key, value) in extra { payload[key] = value }
                let data = try JSONSerialization.data(withJSONObject: payload)
                let response = try await client.send(.post, headers: headers, to: "/internal/agent-api/integrations/app/prepare") { request in
                    request.body = .init(data: data)
                }
                return (response.status, (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:])
            }
            for host in ["[::1]", "[fc00::1]", "[fd00::1]", "[fe80::1]"] {
                let response = try await prepare([
                    "homepageUrl": "http://\(host)/app",
                    "returnUrl": "http://\(host)/auth/raft/callback",
                ])
                #expect(response.0 == .badRequest, Comment(rawValue: "\(host) status=\(response.0) body=\(response.1)"))
                #expect(response.1["errorCode"] as? String == "UNSAFE_DEMO_URL_REQUIRES_OVERRIDE", Comment(rawValue: host))
            }
            let badScope = try await prepare([
                "returnUrl": "https://example.test/auth/raft/callback",
                "scopes": ["not:a:raft:scope"],
            ])
            #expect(badScope.0 == .badRequest)
            #expect(badScope.1["errorCode"] as? String == "INVALID_SCOPE")
            let badCategory = try await prepare([
                "returnUrl": "https://example.test/auth/raft/callback",
                "category": "Not A Category",
            ])
            #expect(badCategory.0 == .badRequest)
            #expect(badCategory.1["errorCode"] as? String == "INVALID_CATEGORY")
        }
    }
}

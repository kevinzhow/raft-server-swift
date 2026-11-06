import TestSupport
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

@Test func readOnlyAgentCredentialIsDeniedOnMutatingAgentApiRoutes() async throws {
    let f = makePrepareFixture()
    let readKey = f.accounts.mintAgentCredential(
        agentId: f.accounts.oauth.activeAgentIds(serverId: f.serverId).first ?? "",
        scopes: ["read"],
        name: "read-only"
    )
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(readKey)"
            headers[.contentType] = "application/json"
            func post(_ path: String, _ json: [String: Any]) async throws -> (HTTPResponse.Status, [String: Any]) {
                let data = try JSONSerialization.data(withJSONObject: json)
                let response = try await client.send(.post, headers: headers, to: URI(string: path)) { request in
                    request.body = .init(data: data)
                }
                return (response.status, (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:])
            }
            let send = try await post("/internal/agent-api/send", ["target": "#\(f.channelName)", "content": "should not send"])
            #expect(send.0 == .forbidden)
            #expect(send.1["code"] as? String == "capability_not_authorized")

            let resolve = try await post("/internal/agent-api/resolve-channel", ["target": "#\(f.channelName)"])
            #expect(resolve.0 == .forbidden)
            #expect(resolve.1["requiredCapability"] as? String == "send")

            let claim = try await post("/internal/agent-api/tasks/claim", ["channel": "#\(f.channelName)", "task_numbers": [1]])
            #expect(claim.0 == .forbidden)
            #expect(claim.1["requiredCapability"] as? String == "tasks")

            let reminder = try await post("/internal/agent-api/reminders", ["title": "no", "delaySeconds": 60, "msgId": UUID().uuidString.lowercased()])
            #expect(reminder.0 == .forbidden)
            #expect(reminder.1["requiredCapability"] as? String == "tasks")

            let reaction = try await post("/internal/agent-api/messages/\(UUID().uuidString.lowercased())/reactions", ["emoji": "👍"])
            #expect(reaction.0 == .forbidden)
            #expect(reaction.1["requiredCapability"] as? String == "reactions")

            let profile = try await post("/internal/agent-api/profile", ["displayName": "Nope"])
            #expect(profile.0 == .forbidden)
            #expect(profile.1["requiredCapability"] as? String == "send")

            let mute = try await post("/internal/agent-api/channels/\(f.channelName)/mute", [:])
            #expect(mute.0 == .forbidden)
            #expect(mute.1["requiredCapability"] as? String == "channels")

            for path in ["/internal/agent-api/channels/archive", "/internal/agent-api/channels/unarchive"] {
                let response = try await post(path, ["target": "#\(f.channelName)"])
                #expect(response.0 == .forbidden, Comment(rawValue: path))
                #expect(response.1["requiredCapability"] as? String == "channels", Comment(rawValue: path))
            }
        }
    }
}

@Test func genericPrepareActionCanPostAgentCreateCardToDMThread() async throws {
    let f = makePrepareFixture()
    let agentId = f.accounts.oauth.activeAgentIds(serverId: f.serverId).first ?? ""
    let ownerId = "11111111-1111-4111-8111-111111111651"
    let dmId = f.accounts.oauth.createDirectChannel(serverId: f.serverId, firstUserId: ownerId, secondUserId: agentId)
    for member in [ownerId, agentId] {
        f.accounts.addPostableChannel(serverId: f.serverId, channelId: dmId, memberId: member, kind: "dm", name: "dm")
    }
    f.accounts.oauth.addChannelHuman(channelId: dmId, userId: agentId)
    let parentId = UUID().uuidString.lowercased()
    f.accounts.insertHumanMessage(id: parentId, channelId: dmId, senderId: ownerId, content: "dm thread action-card parent")

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(f.key)"
            headers[.contentType] = "application/json"
            let payload: [String: Any] = [
                "target": "dm:@prepare-action:\(String(parentId.prefix(8)))",
                "action": [
                    "type": "agent:create",
                    "name": "PreparedInDmThread",
                    "description": "Prepared from a DM thread target",
                ],
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            let response = try await client.send(.post, headers: headers, to: "/internal/agent-api/prepare-action") { request in
                request.body = .init(data: data)
            }
            #expect(response.status == .created, Comment(rawValue: response.body.string ?? ""))
            let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            #expect(body["messageId"] as? String != nil)
            let metadata = try #require(body["metadata"] as? [String: Any])
            #expect(metadata["kind"] as? String == "action-card")
            #expect(metadata["state"] as? String == "prepared")
            let action = try #require(metadata["action"] as? [String: Any])
            #expect(action["type"] as? String == "agent:create")
            #expect(action["name"] as? String == "PreparedInDmThread")
        }
    }
}

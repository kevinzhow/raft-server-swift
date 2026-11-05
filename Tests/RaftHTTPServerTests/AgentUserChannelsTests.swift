import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func agentUserChannelsGatesCapabilitiesVisibilityAndPaging() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111635"
    let subjectId = "11111111-1111-4111-8111-111111111636"
    let serverId = "33333333-3333-4333-8333-333333333678"
    accounts.addAccount(id: ownerId, email: "user-channels-owner@test.invalid", password: "password123")
    accounts.addAccount(id: subjectId, email: "user-channels-subject@test.invalid", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.markEmailVerified(userId: subjectId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "user-channels", name: "User Channels", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: subjectId, role: "member")
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "UserChannelsBot", creatorUserId: ownerId, runtime: "claude")
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "user-channels-room", creatorUserId: ownerId, type: "channel")
    accounts.oauth.addChannelHuman(channelId: channelId, userId: subjectId)
    let fullScopes = ["channels", "read", "channel:read", "server:read"]
    let key = accounts.mintAgentCredential(agentId: agentId, scopes: fullScopes, name: "user-channels")
    let channelsOnly = accounts.mintAgentCredential(agentId: agentId, scopes: ["channels"], name: "channels-only")
    let noChannelRead = accounts.mintAgentCredential(agentId: agentId, scopes: ["channels", "read", "server:read"], name: "no-channel-read")
    let noServerRead = accounts.mintAgentCredential(agentId: agentId, scopes: ["channels", "read", "channel:read"], name: "no-server-read")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            func call(_ key: String, _ name: String, query: String = "") async throws -> (ClientResponse, [String: Any]) {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(key)"
                let encoded = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name
                let response = try await client.get(URI(string: "/internal/agent-api/users/\(encoded)/channels\(query)"), headers: headers)
                return (response, (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:])
            }
            let channelsCap = try await call(channelsOnly, "user-channels-subject")
            #expect(channelsCap.0.status == .forbidden)
            #expect(channelsCap.1["requiredCapability"] as? String == "read")
            let channelRead = try await call(noChannelRead, "user-channels-subject")
            #expect(channelRead.0.status == .forbidden)
            #expect(channelRead.1["requiredScope"] as? String == "channel:read")
            let serverRead = try await call(noServerRead, "user-channels-subject")
            #expect(serverRead.0.status == .forbidden)
            #expect(serverRead.1["requiredScope"] as? String == "server:read")

            let unknown = try await call(key, "nobody")
            #expect(unknown.0.status == .notFound)
            #expect(unknown.1["code"] as? String == "user_not_found")
            let caseSensitive = try await call(key, "User-Channels-Subject")
            #expect(caseSensitive.0.status == .notFound)

            for query in ["?limit=201", "?limit=0", "?limit=-1", "?offset=-1", "?offset=1.5", "?limit=abc"] {
                let invalid = try await call(key, "user-channels-subject", query: query)
                #expect(invalid.0.status == .badRequest, "\(query)")
                #expect(invalid.1["code"] as? String == "agent_api_contract_invalid", "\(query)")
            }
            let page = try await call(key, "@user-channels-subject", query: "?limit=200")
            #expect(page.0.status == .ok)
            let pageInfo = page.1["page"] as? [String: Any]
            #expect(pageInfo?["limit"] as? Int == 200)
            #expect(pageInfo?["offset"] as? Int == 0)
            let memberships = page.1["memberships"] as? [[String: Any]] ?? []
            #expect(memberships.contains { $0["id"] as? String == channelId })

            accounts.setHideHumansFromMembers(serverId: serverId, hidden: true)
            let hidden = try await call(key, "user-channels-subject")
            #expect(hidden.0.status == .notFound)
            accounts.oauth.setAgentRole(serverId: serverId, agentId: agentId, role: "admin")
            let admin = try await call(key, "user-channels-subject")
            #expect(admin.0.status == .ok)
        }
    }
}

import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func sendHoldsOnlyForAnUnseenChannelCardTheClientNamed() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001109001"
    let ownerId = "11111111-1111-4111-8111-000001109001"
    accounts.addAccount(id: ownerId, email: "card-owner@test.invalid", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "card-send", name: "Card Send", ownerId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "CardBot", creatorUserId: ownerId, runtime: "claude")
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "card-room", creatorUserId: ownerId, type: "channel")
    accounts.seedPostableChannelForTesting(serverId: serverId, channelId: channelId, name: "card-room", humanIds: [ownerId], agentIds: [agentId])
    let key = accounts.mintAgentCredential(agentId: agentId, scopes: ["send", "read"], name: "card")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            func send(_ body: [String: Any]) async throws -> (ClientResponse, [String: Any]) {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(key)"
                headers[.contentType] = "application/json"
                let data = try JSONSerialization.data(withJSONObject: body)
                let response = try await client.send(.post, headers: headers, to: URI(string: "/internal/agent-api/v2/send")) { request in
                    request.body = .init(data: data)
                }
                return (response, (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:])
            }
            let plain = try await send(["target": "#card-room", "content": "no card field"])
            #expect(plain.1["state"] as? String == "sent")
            #expect(plain.1["channelCard"] == nil)
            let plainSeq = try #require(plain.1["messageSeq"] as? Int)
            let before = accounts.messageCountForTesting(channelId: channelId)

            let unseen = try await send(["target": "#card-room", "content": "first post", "seenUpToSeq": plainSeq, "seenCards": ["channel": NSNull()]])
            #expect(unseen.1["state"] as? String == "held")
            #expect(unseen.1["holdReasons"] as? [String] == ["channel_card"])
            #expect(unseen.1["newMessageCount"] as? Int == 0)
            #expect((unseen.1["channelCard"] as? [String: Any])?["id"] as? String == channelId)
            #expect(unseen.1["channelCardChanged"] == nil)
            #expect(accounts.messageCountForTesting(channelId: channelId) == before)

            let rev = try #require(accounts.channelCardRevisionForTesting(channelId: channelId))

            let seen = try await send(["target": "#card-room", "content": "card seen", "seenUpToSeq": plainSeq, "seenCards": ["channel": rev]])
            #expect(seen.1["state"] as? String == "sent")
            #expect(seen.1["channelCard"] == nil)
            let seenSeq = try #require(seen.1["messageSeq"] as? Int)

            accounts.oauth.setChannelArchived(id: channelId, archivedAt: Date())
            let changed = try await send(["target": "#card-room", "content": "card changed", "seenUpToSeq": seenSeq, "seenCards": ["channel": rev]])
            #expect(changed.1["state"] as? String == "sent")
            #expect((changed.1["channelCard"] as? [String: Any])?["archived"] as? Bool == true)
            #expect(changed.1["channelCardChanged"] as? Bool == true)
        }
    }
}

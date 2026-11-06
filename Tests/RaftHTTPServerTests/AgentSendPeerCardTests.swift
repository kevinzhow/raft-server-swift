import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func dmReadsCarryThePeerCardAndSendHoldsOnlyForAnUnseenPeer() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001110001"
    let ownerId = "11111111-1111-4111-8111-000001110001"
    accounts.addAccount(id: ownerId, email: "peer-card-owner@test.invalid", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "peer-card", name: "Peer Card", ownerId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "PeerBot", creatorUserId: ownerId, runtime: "claude")
    let dmId = accounts.seedDMForTesting(serverId: serverId, humanUserId: ownerId, agentId: agentId)
    let key = accounts.mintAgentCredential(agentId: agentId, scopes: ["send", "read"], name: "peer")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            func send(_ body: [String: Any]) async throws -> [String: Any] {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(key)"
                headers[.contentType] = "application/json"
                let data = try JSONSerialization.data(withJSONObject: body)
                let response = try await client.send(.post, headers: headers, to: URI(string: "/internal/agent-api/v2/send")) { request in
                    request.body = .init(data: data)
                }
                return (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            }
            func history(_ target: String) async throws -> [String: Any] {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(key)"
                let encoded = target.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? target
                let response = try await client.get(URI(string: "/internal/agent-api/history?channel=\(encoded)&consume=false"), headers: headers)
                return (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            }
            let empty = try await send(["target": "dm:@peer-card-owner", "content": "hi", "seenCards": ["peer": NSNull()]])
            #expect(empty["state"] as? String == "sent")

            accounts.setAccountDescriptionForTesting(userId: ownerId, description: "Founder. Prefers short updates.")
            let root = accounts.addHumanMessageForTesting(channelId: dmId, senderId: ownerId, content: "from Shanghai", senderTimezone: "Asia/Shanghai")
            let rootSeq = accounts.messageSeqForTesting(messageId: root) ?? 0
            let read = try await history("dm:@peer-card-owner")
            let readCard = try #require(read["peer_card"] as? [String: Any])
            #expect(readCard["kind"] as? String == "human")
            #expect(readCard["description"] as? String == "Founder. Prefers short updates.")
            #expect(readCard["timezone"] as? String == "Asia/Shanghai")
            #expect(read["channel_card"] == nil)

            let unseen = try await send(["target": "dm:@peer-card-owner", "content": "reply", "seenUpToSeq": rootSeq, "seenCards": ["peer": NSNull()]])
            #expect(unseen["state"] as? String == "held")
            #expect(unseen["holdReasons"] as? [String] == ["peer_card"])
            #expect((unseen["peerCard"] as? [String: Any])?["timezone"] as? String == "Asia/Shanghai")

            let seen = try await send(["target": "dm:@peer-card-owner", "content": "reply", "seenUpToSeq": rootSeq, "seenCards": ["peer": "v-any"]])
            #expect(seen["state"] as? String == "sent")
            #expect(seen["peerCard"] == nil)

            let moved = accounts.addHumanMessageForTesting(channelId: dmId, senderId: ownerId, content: "now in Berlin", senderTimezone: "Europe/Berlin")
            let movedSeq = accounts.messageSeqForTesting(messageId: moved) ?? 0
            let travelled = try await send(["target": "dm:@peer-card-owner", "content": "ok", "seenUpToSeq": movedSeq, "seenCards": ["peer": "v-from-shanghai"]])
            #expect(travelled["state"] as? String == "sent")
            #expect(travelled["peerCard"] == nil)

            let threadId = accounts.oauth.createThreadChannel(parentChannelId: dmId, parentMessageId: moved)
            accounts.addThreadChannel(serverId: serverId, threadChannelId: threadId, parentChannelId: dmId, parentMessageId: moved, memberId: ownerId)
            accounts.addPostableChannel(serverId: serverId, channelId: threadId, memberId: agentId, kind: "thread", parentChannelId: dmId, parentMessageId: moved, name: "thread")
            let threadRead = try await history("dm:@peer-card-owner:\(moved.prefix(8))")
            #expect((threadRead["peer_card"] as? [String: Any])?["timezone"] as? String == "Europe/Berlin")
            let threadSend = try await send(["target": "dm:@peer-card-owner:\(moved.prefix(8))", "content": "in thread", "seenUpToSeq": movedSeq, "seenCards": ["peer": NSNull()]])
            #expect(threadSend["state"] as? String == "held")
            #expect(threadSend["holdReasons"] as? [String] == ["peer_card"])
        }
    }
}

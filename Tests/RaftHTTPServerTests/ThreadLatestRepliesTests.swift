import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func threadSummariesPreviewLatestConversationRepliesOnly() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111558"
    let serverId = "33333333-3333-4333-8333-333333333625"
    accounts.addAccount(id: ownerId, email: "latest-replies-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "latest-replies", name: "Latest Replies", ownerId: ownerId)
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "latest-replies-channel", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "latest-replies-channel")
    accounts.oauth.addChannelHuman(channelId: channel, userId: ownerId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var loginHeaders = HTTPFields()
            loginHeaders[.contentType] = "application/json"
            let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"latest-replies-owner@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            func send(_ channelId: String, _ content: String) async throws {
                let response = try await client.send(.post, headers: headers, to: "/api/messages") { request in
                    request.body = .init(string: "{\"channelId\":\"\(channelId)\",\"content\":\"\(content)\"}")
                }
                #expect(response.status == .ok)
            }
            let parentResponse = try await client.send(.post, headers: headers, to: "/api/messages") { request in
                request.body = .init(string: "{\"channelId\":\"\(channel)\",\"content\":\"parent\"}")
            }
            let parentId = (try JSONSerialization.jsonObject(with: Data((parentResponse.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String ?? ""
            let threadResponse = try await client.send(.post, headers: headers, to: "/api/channels/\(channel)/threads") { request in
                request.body = .init(string: "{\"parentMessageId\":\"\(parentId)\"}")
            }
            let threadId = (try JSONSerialization.jsonObject(with: Data((threadResponse.body.string ?? "").utf8)) as? [String: Any])?["threadChannelId"] as? String ?? ""
            try await send(threadId, "human reply one")
            try await send(threadId, "human reply two")
            try await send(threadId, "human reply three")
            _ = accounts.addHumanMessageForTesting(channelId: threadId, senderId: ownerId, content: "system receipt", messageType: "system")

            let summaries = try await client.send(.get, headers: headers, to: "/api/channels/\(channel)/threads")
            let body = try JSONSerialization.jsonObject(with: Data((summaries.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            let summary = body[parentId] as? [String: Any]
            #expect(summary?["replyCount"] as? Int == 4)
            let latest = summary?["latestReplies"] as? [[String: Any]] ?? []
            #expect(latest.map { $0["preview"] as? String } == ["human reply one", "human reply two", "human reply three"])
            #expect(!latest.contains { $0["senderType"] as? String == "system" })
            #expect(latest.first?["senderName"] as? String == "latest-replies-owner")

            let agent = accounts.oauth.createAgent(serverId: serverId, name: "MingQi")
            accounts.oauth.updateAgentDisplayName(id: agent, displayName: "明启")
            _ = accounts.addHumanMessageForTesting(channelId: threadId, senderId: agent, content: "agent reply", senderType: "agent")
            let refreshed = try await client.send(.get, headers: headers, to: "/api/channels/\(channel)/threads")
            let refreshedBody = try JSONSerialization.jsonObject(with: Data((refreshed.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            let refreshedSummary = refreshedBody[parentId] as? [String: Any]
            let refreshedLatest = refreshedSummary?["latestReplies"] as? [[String: Any]] ?? []
            let agentReply = refreshedLatest.last
            #expect(agentReply?["senderName"] as? String == "MingQi")
            #expect(agentReply?["senderDisplayName"] as? String == "明启")
            #expect(agentReply?["senderType"] as? String == "agent")
        }
    }
}

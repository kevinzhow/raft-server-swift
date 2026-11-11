import TestSupport
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func agentHistoryPagesReadAndUpdatesReadReceipts() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111497"
    let serverId = "33333333-3333-4333-8333-333333333593"
    accounts.addAccount(id: ownerId, email: "history-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "history", name: "History", ownerId: ownerId)
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "receipt-channel", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "receipt-channel")
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "history-agent")
    accounts.oauth.addChannelAgent(channelId: channel, agentId: agent)
    let key = accounts.mintAgentCredential(agentId: agent, scopes: ["read"], name: "history")
    let first = accounts.oauth.createMessageRecord(channelId: channel, content: "history first", senderId: ownerId)
    let second = accounts.oauth.createMessageRecord(channelId: channel, content: "history second", senderId: ownerId)
    let third = accounts.oauth.createMessageRecord(channelId: channel, content: "history third", senderId: agent)
    accounts.enableReadReceiptsForServer(serverId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func history(_ query: String) async throws -> [String: Any] {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(key)"
                let response = try await client.send(.get, headers: headers, to: URI(string: "/internal/agent-api/history?channel=%23receipt-channel&\(query)"))
                #expect(response.status == .ok)
                return try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            }
            func messageIds(_ body: [String: Any]) -> [String] {
                (body["messages"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            }

            // A window that leaves older rows unseen does not consume them.
            let page = try await history("limit=2")
            #expect(messageIds(page) == [second.id, third.id])
            #expect(page["has_more"] as? Bool == true)
            #expect(page["has_older"] as? Bool == true)
            #expect(page["has_newer"] as? Bool == false)
            #expect(page["last_read_seq"] as? Int == 0)
            #expect(page["model_seen_up_to_seq"] == nil || page["model_seen_up_to_seq"] is NSNull)

            // The full window joins the prior boundary and consumes through it.
            let all = try await history("limit=3")
            #expect(messageIds(all) == [first.id, second.id, third.id])
            #expect(all["has_older"] as? Bool == false)
            #expect(all["model_seen_up_to_seq"] as? Int == third.seq)
            #expect(all["last_read_seq"] as? Int == 0)
            let firstMessage = (page["messages"] as? [[String: Any]] ?? []).first
            #expect(firstMessage?["senderType"] as? String == "user")
            #expect((firstMessage?["senderName"] as? String)?.isEmpty == false)
            #expect(firstMessage?["createdAt"] is String)

            let machine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "history-machine")
            accounts.assignAgentMachineForTesting(agentId: agent, machineId: machine)
            let machineKey = accounts.machineAPIKey(machineId: machine) ?? ""
            var legacyHeaders = HTTPFields()
            legacyHeaders[.authorization] = "Bearer \(machineKey)"
            let legacy = try await client.send(.get, headers: legacyHeaders, to: URI(string: "/internal/agent/\(agent)/history?channel=%23receipt-channel&limit=2"))
            #expect(legacy.status == .ok)
            let legacyBody = try JSONSerialization.jsonObject(with: Data((legacy.body.string ?? "").utf8)) as? [String: Any]
            #expect((legacyBody?["messages"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String } == [second.id, third.id])

            let threadId = accounts.oauth.createThreadChannel(parentChannelId: channel, parentMessageId: "abcdef1234567890")
            accounts.addPostableChannel(serverId: serverId, channelId: threadId, memberId: ownerId, kind: "thread", parentChannelId: channel, parentMessageId: "abcdef1234567890", name: "thread")
            accounts.oauth.addChannelHuman(channelId: threadId, userId: ownerId)
            accounts.oauth.addChannelAgent(channelId: threadId, agentId: agent)
            _ = accounts.oauth.createMessageRecord(channelId: threadId, content: "thread history", senderId: ownerId)
            var threadHeaders = HTTPFields()
            threadHeaders[.authorization] = "Bearer \(key)"
            let threadResponse = try await client.send(.get, headers: threadHeaders, to: URI(string: "/internal/agent-api/history?channel=%23receipt-channel%3Aabcdef12"))
            #expect(threadResponse.status == .ok)
            let threadHistory = try JSONSerialization.jsonObject(with: Data((threadResponse.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            #expect(messageIds(threadHistory) == [accounts.oauth.historyMessages(channelId: threadId).first?.id ?? "missing"])

            let around = try await history("around=\(String(second.id.prefix(8)))&limit=3")
            #expect(messageIds(around) == [first.id, second.id, third.id])
            #expect(around["has_newer"] as? Bool == false)

            let after = try await history("after=\(first.seq)&limit=1")
            #expect(messageIds(after) == [second.id])
            #expect(after["has_more"] as? Bool == true)
            #expect(after["has_older"] as? Bool == false)
            #expect(after["has_newer"] as? Bool == true)

            var loginHeaders = HTTPFields()
            loginHeaders[.contentType] = "application/json"
            let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"history-owner@slock.test\",\"password\":\"password123\"}")
            }
            let ownerToken = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var detailHeaders = HTTPFields()
            detailHeaders[.authorization] = "Bearer \(ownerToken)"
            detailHeaders[HTTPField.Name("X-Server-Id")!] = serverId
            let detail = try await client.send(.get, headers: detailHeaders, to: "/api/channels/\(channel)")
            let detailBody = try JSONSerialization.jsonObject(with: Data((detail.body.string ?? "").utf8)) as? [String: Any]
            let peers = detailBody?["peerReadStates"] as? [[String: Any]] ?? []
            #expect(peers.first?["peerId"] as? String == agent)
            #expect(peers.first?["maxReadSeq"] as? Int == third.seq)
        }
    }
}

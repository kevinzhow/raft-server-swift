import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

/// Published-path parity for the durable mention-delivery occurrence spine:
/// the sender projection is derived from the occurrence receipts, real sends
/// record the occurrence before any delivery, and the internal agent surface
/// publishes the pinned occurrence-row shape.
private struct OccurrenceSeed {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let ownerEmail: String
    let channelId: String
    let agentId: String
    let agentName: String
}

private func occurrenceSeed(_ suffix: String) -> OccurrenceSeed {
    let accounts = EmailLoginDirectory()
    let n = Int(suffix) ?? 0
    let serverId = String(format: "33333333-3333-4333-8333-%012d", 960_000 + n)
    let ownerId = String(format: "11111111-1111-4111-8111-%012d", 960_000 + n)
    let ownerEmail = "occurrence-owner-\(suffix)@raft.test"
    accounts.addAccount(id: ownerId, email: ownerEmail, password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: ownerId, role: "member")
    accounts.oauth.addOwnedServer(id: serverId, slug: "occurrence-\(suffix)", name: "Occurrence \(suffix)",
                                  ownerId: ownerId)
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "occurrence-\(suffix)",
                                               creatorUserId: ownerId, type: "private")
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId,
                                kind: "private", name: "occurrence-\(suffix)")
    accounts.oauth.addChannelHuman(channelId: channel, userId: ownerId)
    let agentName = "CindyOccurrence\(n)"
    let agent = accounts.oauth.createAgent(serverId: serverId, name: agentName, runtime: "codex")
    // A formal notifiable mention requires the agent to be a real channel member.
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: agent,
                                kind: "private", name: "occurrence-\(suffix)")
    accounts.oauth.addChannelAgent(channelId: channel, agentId: agent)
    return OccurrenceSeed(accounts: accounts, serverId: serverId, ownerId: ownerId, ownerEmail: ownerEmail,
                          channelId: channel, agentId: agent, agentName: agentName)
}

private func occurrenceLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
}

private func occurrenceSend(_ client: any Client, token: String, serverId: String, channelId: String,
                            agentId: String, agentName: String, content: String) async throws -> String {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    let body: [String: Any] = [
        "channelId": channelId,
        "content": content,
        "mentions": [["type": "agent", "id": agentId, "name": agentName]],
    ]
    let data = try JSONSerialization.data(withJSONObject: body)
    let response = try await client.send(.post, headers: headers, to: "/api/v2/messages") { request in
        request.body = .init(data: data)
    }
    let object = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any]
    return (object?["message"] as? [String: Any])?["id"] as? String ?? ""
}

private func occurrenceDeliveries(_ client: any Client, token: String, serverId: String,
                                  messageId: String) async throws -> (status: HTTPResponse.Status, rows: [[String: Any]]) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    let response = try await client.get(URI(string: "/api/messages/\(messageId)/mention-deliveries"), headers: headers)
    let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    return (response.status, body["deliveries"] as? [[String: Any]] ?? [])
}

@Test func formalMentionPublishesPendingThenDeliveredFromOccurrenceReceipts() async throws {
    let seed = occurrenceSeed("601")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: seed.accounts
        ))
        try await app.testing { client in
            let token = try await occurrenceLogin(client, email: seed.ownerEmail)
            let message = try await occurrenceSend(
                client, token: token, serverId: seed.serverId, channelId: seed.channelId,
                agentId: seed.agentId, agentName: seed.agentName, content: "@\(seed.agentName) first ping")
            #expect(!message.isEmpty)
            // The occurrence is recorded atomically with the mention facts.
            #expect(seed.accounts.mentionDeliveryOccurrenceStateForTesting(
                messageId: message, agentId: seed.agentId) == "recorded")

            // No daemon receipt yet: a broken server-decision hop is in flight.
            let pending = try await occurrenceDeliveries(client, token: token, serverId: seed.serverId,
                                                         messageId: message)
            #expect(pending.status == .ok)
            let pendingRow = try #require(pending.rows.first)
            #expect(pendingRow["targetId"] as? String == seed.agentId)
            #expect(pendingRow["targetHandle"] as? String == seed.agentName)
            #expect(pendingRow["outcome"] as? String == "pending")

            // The daemon's receipt chain (received -> drained -> ack) is the only
            // fact that publishes delivered.
            #expect(seed.accounts.advanceMentionDeliveryForTesting(
                messageId: message, agentId: seed.agentId, outcome: "delivered"))
            let delivered = try await occurrenceDeliveries(client, token: token, serverId: seed.serverId,
                                                           messageId: message)
            let deliveredRow = try #require(delivered.rows.first)
            #expect(deliveredRow["outcome"] as? String == "delivered")
            #expect(deliveredRow["reasonCategory"] == nil)
        }
    }
}

@Test func daemonTerminalCodesPublishTheirClosedCategoryAndInstrumentFailureStaysUnknown() async throws {
    let seed = occurrenceSeed("602")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: seed.accounts
        ))
        try await app.testing { client in
            let token = try await occurrenceLogin(client, email: seed.ownerEmail)
            func post(_ content: String) async throws -> String {
                try await occurrenceSend(client, token: token, serverId: seed.serverId,
                                         channelId: seed.channelId, agentId: seed.agentId,
                                         agentName: seed.agentName, content: content)
            }

            let quota = try await post("@\(seed.agentName) quota ping")
            #expect(seed.accounts.advanceMentionDeliveryForTesting(
                messageId: quota, agentId: seed.agentId, outcome: "QUOTA_LIMITED"))
            let quotaRow = try #require(try await occurrenceDeliveries(
                client, token: token, serverId: seed.serverId, messageId: quota).rows.first)
            #expect(quotaRow["outcome"] as? String == "lost")
            #expect(quotaRow["reasonCategory"] as? String == "quota")

            let runtime = try await post("@\(seed.agentName) runtime ping")
            #expect(seed.accounts.advanceMentionDeliveryForTesting(
                messageId: runtime, agentId: seed.agentId, outcome: "DELIVERY_REJECTED"))
            let runtimeRow = try #require(try await occurrenceDeliveries(
                client, token: token, serverId: seed.serverId, messageId: runtime).rows.first)
            #expect(runtimeRow["outcome"] as? String == "lost")
            #expect(runtimeRow["reasonCategory"] as? String == "runtime_error")

            // The instrument broke: never dressed as a verdict about the target.
            let instrument = try await post("@\(seed.agentName) instrument ping")
            #expect(seed.accounts.advanceMentionDeliveryForTesting(
                messageId: instrument, agentId: seed.agentId, outcome: "INSTRUMENT_FAILED"))
            let instrumentRow = try #require(try await occurrenceDeliveries(
                client, token: token, serverId: seed.serverId, messageId: instrument).rows.first)
            #expect(instrumentRow["outcome"] as? String == "unknown")
            #expect(instrumentRow["reasonCategory"] == nil)

            // Identity drift is a real terminal loss with no seat category.
            let drift = try await post("@\(seed.agentName) drift ping")
            #expect(seed.accounts.advanceMentionDeliveryForTesting(
                messageId: drift, agentId: seed.agentId, outcome: "IDENTITY_DRIFT"))
            let driftRow = try #require(try await occurrenceDeliveries(
                client, token: token, serverId: seed.serverId, messageId: drift).rows.first)
            #expect(driftRow["outcome"] as? String == "lost")
            #expect(driftRow["reasonCategory"] as? String == "unclassified")
        }
    }
}

@Test func internalSenderRoutePublishesOccurrenceRowsWithTheAuthoredHandleOnly() async throws {
    let seed = occurrenceSeed("603")
    // The agent surface is sender-bound: seed an agent-authored message.
    let author = seed.accounts.oauth.createAgent(serverId: seed.serverId, name: "OccurrenceAuthor", runtime: "codex")
    seed.accounts.oauth.addChannelAgent(channelId: seed.channelId, agentId: author)
    let message = seed.accounts.addChannelMessageForTesting(
        channelId: seed.channelId, content: "ping @OldName", senderId: author, senderType: "agent")
    seed.accounts.addStoredMentionForTesting(
        channelId: seed.channelId, messageId: message, targetId: seed.agentId,
        targetType: "agent", handle: "@OldName")
    // No occurrence => the same not-found join miss upstream maps to unknown.
    let authorKey = seed.accounts.mintAgentCredential(agentId: author, scopes: ["read"], name: "occurrence-author")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: seed.accounts
        ))
        try await app.testing { client in
            func read() async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(authorKey)"
                let response = try await client.get(
                    URI(string: "/internal/agent-api/messages/\(message)/mention-deliveries"), headers: headers)
                let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
                return (response.status, body)
            }

            // Upstream lists occurrence rows. A mention with no occurrence is
            // simply absent here (the public human route is where a missing
            // occurrence becomes `unknown`).
            let missing = try await read()
            #expect(missing.status == .ok)
            #expect(missing.body["messageId"] as? String == message)
            #expect((missing.body["deliveries"] as? [[String: Any]])?.isEmpty == true)

            #expect(seed.accounts.ensureMentionDeliveryOccurrenceForTesting(
                messageId: message, agentId: seed.agentId) != nil)
            let recorded = try await read()
            let recordedRow = try #require((recorded.body["deliveries"] as? [[String: Any]])?.first)
            #expect(recordedRow["targetHandle"] as? String == "@OldName")
            #expect(recordedRow["outcome"] as? String == "pending")
            #expect(seed.accounts.advanceMentionDeliveryForTesting(
                messageId: message, agentId: seed.agentId, outcome: "delivered"))
            let delivered = try await read()
            let deliveredRow = try #require((delivered.body["deliveries"] as? [[String: Any]])?.first)
            #expect(deliveredRow["targetHandle"] as? String == "@OldName")
            #expect(deliveredRow["outcome"] as? String == "delivered")
            #expect(deliveredRow.keys.sorted() == ["outcome", "targetHandle"])
        }
    }
}

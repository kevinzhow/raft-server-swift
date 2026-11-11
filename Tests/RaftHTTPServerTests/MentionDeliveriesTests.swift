import Foundation
import HTTPTypes
@testable import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct MentionDeliverySeed {
    let accounts: EmailLoginDirectory
    let serverId: String
    let otherServerId: String
    let authorId: String
    let authorEmail: String
    let peerEmail: String
    let channelId: String
    let agentId: String
}

private func mentionDeliverySeed(_ suffix: String) -> MentionDeliverySeed {
    let accounts = EmailLoginDirectory()
    let n = Int(suffix) ?? 0
    let serverId = String(format: "33333333-3333-4333-8333-%012d", 900_000 + n)
    let otherServerId = String(format: "33333333-3333-4333-8333-%012d", 950_000 + n)
    let authorId = String(format: "11111111-1111-4111-8111-%012d", 700_000 + n)
    let peerId = String(format: "11111111-1111-4111-8111-%012d", 750_000 + n)
    let authorEmail = "mention-author-\(suffix)@raft.test"
    let peerEmail = "mention-peer-\(suffix)@raft.test"
    for (id, email) in [(authorId, authorEmail), (peerId, peerEmail)] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
        accounts.oauth.addMember(serverId: serverId, userId: id, role: "member")
        accounts.oauth.addMember(serverId: otherServerId, userId: id, role: "member")
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "mention-one-\(suffix)", name: "Mention One \(suffix)", ownerId: authorId)
    accounts.oauth.addOwnedServer(id: otherServerId, slug: "mention-two-\(suffix)", name: "Mention Two \(suffix)", ownerId: authorId)
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "mention-\(suffix)", creatorUserId: authorId, type: "private")
    for id in [authorId, peerId] {
        accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: id, kind: "private", name: "mention-\(suffix)")
        accounts.oauth.addChannelHuman(channelId: channel, userId: id)
    }
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "mention-agent-\(suffix)", runtime: "codex")
    return MentionDeliverySeed(
        accounts: accounts,
        serverId: serverId,
        otherServerId: otherServerId,
        authorId: authorId,
        authorEmail: authorEmail,
        peerEmail: peerEmail,
        channelId: channel,
        agentId: agent
    )
}

private func mentionLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
}

private func mentionSend(_ client: any Client, token: String, serverId: String, channelId: String, content: String) async throws -> String {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    let response = try await client.send(.post, headers: headers, to: "/api/messages") { request in
        request.body = .init(string: "{\"channelId\":\"\(channelId)\",\"content\":\"\(content)\"}")
    }
    return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String ?? ""
}

private func mentionRead(_ client: any Client, token: String?, serverId: String, messageId: String) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    var headers = HTTPFields()
    if let token { headers[.authorization] = "Bearer \(token)" }
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    let response = try await client.get(URI(string: "/api/messages/\(messageId)/mention-deliveries"), headers: headers)
    let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    return (response.status, body)
}

@Test func mentionDeliveriesAreVisibleOnlyToTheAuthorWithCurrentAccess() async throws {
    let seed = mentionDeliverySeed("501")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: seed.accounts
        ))
        try await app.testing { client in
            let author = try await mentionLogin(client, email: seed.authorEmail)
            let peer = try await mentionLogin(client, email: seed.peerEmail)
            let message = try await mentionSend(client, token: author, serverId: seed.serverId, channelId: seed.channelId, content: "synthetic")
            seed.accounts.addStoredMentionForTesting(
                channelId: seed.channelId,
                messageId: message,
                targetId: seed.agentId,
                targetType: "agent",
                handle: "original-name",
                terminalCode: "IDENTITY_DRIFT"
            )
            _ = seed.accounts.ensureMentionDeliveryOccurrenceForTesting(messageId: message, agentId: seed.agentId)
            _ = seed.accounts.advanceMentionDeliveryForTesting(
                messageId: message, agentId: seed.agentId, outcome: "IDENTITY_DRIFT")

            let read = try await mentionRead(client, token: author, serverId: seed.serverId, messageId: message)
            #expect(read.status == .ok)
            #expect(read.body["messageId"] as? String == message)
            let deliveries = read.body["deliveries"] as? [[String: Any]] ?? []
            #expect(deliveries.count == 1)
            #expect(deliveries.first?["targetId"] as? String == seed.agentId)
            #expect(deliveries.first?["targetHandle"] as? String == "original-name")
            #expect(deliveries.first?["outcome"] as? String == "lost")
            #expect(deliveries.first?["reasonCategory"] as? String == "unclassified")

            for (token, server, messageId) in [
                (peer, seed.serverId, message),
                (author, seed.otherServerId, message),
                (author, seed.serverId, "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"),
            ] {
                let denied = try await mentionRead(client, token: token, serverId: server, messageId: messageId)
                #expect(denied.status == .notFound)
                #expect(denied.body["status"] as? String == "NOT_JOINABLE")
            }

            seed.accounts.removeChannelMemberForTesting(channelId: seed.channelId, userId: seed.authorId)
            let revoked = try await mentionRead(client, token: author, serverId: seed.serverId, messageId: message)
            #expect(revoked.status == .notFound)
            #expect(revoked.body["status"] as? String == "NOT_JOINABLE")
        }
    }
}

@Test func mentionDeliveriesWithoutOccurrencesAreUnknown() async throws {
    let seed = mentionDeliverySeed("502")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: seed.accounts
        ))
        try await app.testing { client in
            let author = try await mentionLogin(client, email: seed.authorEmail)
            let message = try await mentionSend(client, token: author, serverId: seed.serverId, channelId: seed.channelId, content: "synthetic")
            seed.accounts.addStoredMentionForTesting(
                channelId: seed.channelId,
                messageId: message,
                targetId: seed.agentId,
                targetType: "agent",
                handle: "original-name"
            )
            let read = try await mentionRead(client, token: author, serverId: seed.serverId, messageId: message)
            #expect(read.status == .ok)
            let deliveries = read.body["deliveries"] as? [[String: Any]] ?? []
            #expect(deliveries.first?["outcome"] as? String == "unknown")
            #expect(deliveries.first?["targetHandle"] as? String == "original-name")
        }
    }
}

@Test func mentionDeliveriesRejectAgentCredentials() async throws {
    let seed = mentionDeliverySeed("503")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: seed.accounts
        ))
        try await app.testing { client in
            let author = try await mentionLogin(client, email: seed.authorEmail)
            let message = try await mentionSend(client, token: author, serverId: seed.serverId, channelId: seed.channelId, content: "synthetic")
            seed.accounts.addStoredMentionForTesting(
                channelId: seed.channelId,
                messageId: message,
                targetId: seed.agentId,
                targetType: "agent",
                handle: "original-name",
                terminalCode: "IDENTITY_DRIFT"
            )
            let credential = seed.accounts.mintAgentCredential(agentId: seed.agentId, scopes: ["mentions"], name: "mention-reader")
            let read = try await mentionRead(client, token: credential, serverId: seed.serverId, messageId: message)
            #expect(read.status == .unauthorized)
            #expect(read.body["deliveries"] == nil)
        }
    }
}

@Test func mentionDeliveriesReportTheOccurrenceReceipts() async throws {
    let seed = mentionDeliverySeed("504")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: seed.accounts
        ))
        try await app.testing { client in
            let author = try await mentionLogin(client, email: seed.authorEmail)
            let message = try await mentionSend(client, token: author, serverId: seed.serverId, channelId: seed.channelId, content: "synthetic")
            seed.accounts.addStoredMentionForTesting(
                channelId: seed.channelId,
                messageId: message,
                targetId: seed.agentId,
                targetType: "agent",
                handle: "original-name"
            )
            // No occurrence: unknown, never inferred from unrelated queues or
            // delivery commands.
            seed.accounts.agentsRuntimeStore.withState { state in
                let key = AgentExecutionState.key(seed.serverId, seed.agentId, seed.channelId, message)
                state.execution.pendingHumanDeliveries = [key: AgentExecutionPendingDelivery(
                    serverId: seed.serverId, agentId: seed.agentId, channelId: seed.channelId,
                    messageId: message, createdAt: Date())]
            }
            let unknown = try await mentionRead(client, token: author, serverId: seed.serverId, messageId: message)
            #expect((unknown.body["deliveries"] as? [[String: Any]])?.first?["outcome"] as? String == "unknown")

            // The recorded occurrence with no receipt is a broken server
            // decision: pending, never delivered or lost.
            _ = seed.accounts.ensureMentionDeliveryOccurrenceForTesting(messageId: message, agentId: seed.agentId)
            let pending = try await mentionRead(client, token: author, serverId: seed.serverId, messageId: message)
            #expect((pending.body["deliveries"] as? [[String: Any]])?.first?["outcome"] as? String == "pending")

            // The daemon receipt chain is the only fact that publishes delivered.
            #expect(seed.accounts.advanceMentionDeliveryForTesting(
                messageId: message, agentId: seed.agentId, outcome: "delivered"))
            let delivered = try await mentionRead(client, token: author, serverId: seed.serverId, messageId: message)
            let row = try #require((delivered.body["deliveries"] as? [[String: Any]])?.first)
            #expect(row["outcome"] as? String == "delivered")
            #expect(row["reasonCategory"] == nil)
            #expect(row["targetHandle"] as? String == "original-name")
        }
    }
}

@Test func legacyTerminalCodeWithoutAnOccurrenceIsNotADeliveryFact() async throws {
    let seed = mentionDeliverySeed("505")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: seed.accounts
        ))
        try await app.testing { client in
            let author = try await mentionLogin(client, email: seed.authorEmail)
            let message = try await mentionSend(client, token: author, serverId: seed.serverId,
                                                channelId: seed.channelId, content: "synthetic")
            // The retired pre-occurrence fixture wrote only this column. It is
            // not a daemon receipt and must not publish a verdict.
            seed.accounts.addStoredMentionForTesting(
                channelId: seed.channelId, messageId: message, targetId: seed.agentId,
                targetType: "agent", handle: "original-name", terminalCode: "IDENTITY_DRIFT")
            let read = try await mentionRead(client, token: author, serverId: seed.serverId, messageId: message)
            #expect(read.status == .ok)
            let rows = read.body["deliveries"] as? [[String: Any]] ?? []
            #expect(rows.first?["outcome"] as? String == "unknown")
            #expect(rows.first?["reasonCategory"] == nil)
        }
    }
}

import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private final class ReceiptEventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(room: String, event: String, payload: String?)] = []

    func append(_ room: String, _ event: String, _ payload: String?) {
        lock.lock()
        storage.append((room, event, payload))
        lock.unlock()
    }

    var receipts: [(room: String, event: String, payload: String?)] {
        lock.lock()
        defer { lock.unlock() }
        return storage.filter { $0.event == "scope_read:updated" }
    }
}

private struct ReceiptFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let ownerEmail: String
    let memberEmail: String
    let channelId: String
    let channelName: String
    let agentId: String
    let secondSeq: Int
}

private func makeReceiptFixture() -> ReceiptFixture {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001009001"
    let ownerId = "11111111-1111-4111-8111-000001009001"
    let memberId = "11111111-1111-4111-8111-000001009002"
    let ownerEmail = "receipt-owner@slock.test"
    let memberEmail = "receipt-member@slock.test"
    for (id, email) in [(ownerId, ownerEmail), (memberId, memberEmail)] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "receipt-server", name: "Receipt Server", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "receipt-channel", creatorUserId: ownerId, type: "private")
    for id in [ownerId, memberId] {
        accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: id, kind: "private", name: "receipt-channel")
        accounts.oauth.addChannelHuman(channelId: channel, userId: id)
    }
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "receipt-agent")
    accounts.oauth.addChannelAgent(channelId: channel, agentId: agent)
    let first = accounts.oauth.createMessageRecord(channelId: channel, content: "receipt first", senderId: ownerId)
    let second = accounts.oauth.createMessageRecord(channelId: channel, content: "receipt second", senderId: ownerId)
    accounts.oauth.setChannelReadCursor(channelId: channel, userId: memberId, seq: first.seq)
    accounts.setAgentReadCursorForTesting(agentId: agent, channelId: channel, seq: second.seq)
    return ReceiptFixture(
        accounts: accounts,
        serverId: serverId,
        ownerId: ownerId,
        ownerEmail: ownerEmail,
        memberEmail: memberEmail,
        channelId: channel,
        channelName: "receipt-channel",
        agentId: agent,
        secondSeq: second.seq
    )
}

private func receiptLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
}

private func receiptHeaders(_ token: String, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

@Test func readReceiptsExposeOnlyAgentWatermarksAndEmitOnAdvance() async throws {
    let fixture = makeReceiptFixture()
    let events = ReceiptEventCollector()
    fixture.accounts.realtimeEmitter = { room, event, payload in
        events.append(room, event, payload)
    }
    fixture.accounts.enableReadReceiptsForServer(fixture.serverId)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let owner = try await receiptLogin(client, email: fixture.ownerEmail)
            let member = try await receiptLogin(client, email: fixture.memberEmail)
            let detail = try await client.get(URI(string: "/api/channels/\(fixture.channelId)"), headers: receiptHeaders(owner, fixture.serverId))
            #expect(detail.status == .ok)
            let detailBody = (try JSONSerialization.jsonObject(with: Data((detail.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            let peers = detailBody["peerReadStates"] as? [[String: Any]] ?? []
            #expect(peers.count == 1)
            #expect(peers.first?["peerKind"] as? String == "agent")
            #expect(peers.first?["peerId"] as? String == fixture.agentId)
            #expect(peers.first?["maxReadSeq"] as? Int == fixture.secondSeq)
            #expect(detailBody["peerReadSummary"] == nil)

            let third = fixture.accounts.oauth.createMessageRecord(channelId: fixture.channelId, content: "receipt third", senderId: fixture.ownerId)
            let credential = fixture.accounts.mintAgentCredential(agentId: fixture.agentId, scopes: ["read"], name: "receipt-history")
            var agentHeaders = HTTPFields()
            agentHeaders[.authorization] = "Bearer \(credential)"
            let history = try await client.get(URI(string: "/internal/agent-api/history?channel=%23\(fixture.channelName)&limit=10"), headers: agentHeaders)
            #expect(history.status == .ok)
            let receipts = events.receipts
            #expect(receipts.count == 1)
            #expect(receipts.first?.room == "channel:\(fixture.channelId)")
            let payload = (try JSONSerialization.jsonObject(with: Data((receipts.first?.payload ?? "").utf8))) as? [String: Any] ?? [:]
            #expect(payload["scopeId"] as? String == fixture.channelId)
            #expect(payload["peerKind"] as? String == "agent")
            #expect(payload["peerId"] as? String == fixture.agentId)
            #expect(payload["maxReadSeq"] as? Int == third.seq)

            _ = try await client.get(URI(string: "/internal/agent-api/history?channel=%23\(fixture.channelName)&limit=10"), headers: agentHeaders)
            #expect(events.receipts.count == 1)

            let humanRead = try await client.send(.post, headers: receiptHeaders(member, fixture.serverId), to: URI(string: "/api/channels/\(fixture.channelId)/read")) { request in
                request.body = .init(string: "{\"seq\":\(third.seq)}")
            }
            #expect(humanRead.status == .ok)
            let unread = try await client.send(.post, headers: receiptHeaders(member, fixture.serverId), to: URI(string: "/api/channels/\(fixture.channelId)/unread"))
            #expect(unread.status == .ok)
            #expect(events.receipts.count == 1)
        }
    }
}

@Test func readReceiptsHydrateDMPeersAndSummaryAboveFiftyAgents() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001009002"
    let ownerId = "11111111-1111-4111-8111-000001009002"
    let ownerEmail = "receipt-dm-owner@slock.test"
    accounts.addAccount(id: ownerId, email: ownerEmail, password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "receipt-dm", name: "Receipt DM", ownerId: ownerId)
    let dmAgent = accounts.oauth.createAgent(serverId: serverId, name: "receipt-dm-agent")
    let dm = accounts.oauth.createDirectChannel(serverId: serverId, firstUserId: ownerId, secondUserId: dmAgent)
    accounts.addDirectMessage(serverId: serverId, channelId: dm, participantIds: [ownerId, dmAgent], agentId: dmAgent)
    accounts.oauth.addChannelAgent(channelId: dm, agentId: dmAgent)
    let dmMessage = accounts.oauth.createMessageRecord(channelId: dm, content: "dm receipt", senderId: ownerId)
    accounts.setAgentReadCursorForTesting(agentId: dmAgent, channelId: dm, seq: dmMessage.seq)

    let bigChannel = accounts.oauth.createChannel(serverId: serverId, name: "receipt-big", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: bigChannel, memberId: ownerId, name: "receipt-big")
    accounts.oauth.addChannelHuman(channelId: bigChannel, userId: ownerId)
    for index in 0..<51 {
        let agent = accounts.oauth.createAgent(serverId: serverId, name: "receipt-big-agent-\(index)")
        accounts.oauth.addChannelAgent(channelId: bigChannel, agentId: agent)
        accounts.setAgentReadCursorForTesting(agentId: agent, channelId: bigChannel, seq: index + 1)
    }
    accounts.enableReadReceiptsForServer(serverId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let owner = try await receiptLogin(client, email: ownerEmail)
            let dmDetail = try await client.get(URI(string: "/api/channels/\(dm)"), headers: receiptHeaders(owner, serverId))
            let dmPeers = ((try JSONSerialization.jsonObject(with: Data((dmDetail.body.string ?? "").utf8))) as? [String: Any])?["peerReadStates"] as? [[String: Any]] ?? []
            #expect(dmPeers.count == 1)
            #expect(dmPeers.first?["peerId"] as? String == dmAgent)

            let bigDetail = try await client.get(URI(string: "/api/channels/\(bigChannel)"), headers: receiptHeaders(owner, serverId))
            let bigBody = (try JSONSerialization.jsonObject(with: Data((bigDetail.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            #expect(bigBody["peerReadStates"] == nil)
            let summary = bigBody["peerReadSummary"] as? [String: Any]
            #expect(summary?["peerCount"] as? Int == 51)
            #expect((summary?["readCountAtSeq"] as? [[String: Any]] ?? []).isEmpty == false)
        }
    }
}

import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

/// The agent history envelope prints `senderName` as the canonical handle
/// (`users.name` / `agents.name`, the same value `senderHandle` carries), not
/// the peer's display name. A history target resolves through the exact peer
/// rules, so the selected conversation and the printed sender handle agree.
private struct HistorySenderNameFixture {
    let accounts: EmailLoginDirectory
    let serverId = "33333333-3333-4333-8333-000001310001"
    let ownerId = "11111111-1111-4111-8111-000001310001"
    let aliceId = "11111111-1111-4111-8111-000001310002"
    let bobId = "11111111-1111-4111-8111-000001310003"
    var graceId = ""
    var aliceDM = ""
    var bobDM = ""
    var twinAgentDM = ""
    var agentKey = ""
}

private func makeHistorySenderNameFixture() -> HistorySenderNameFixture {
    var f = HistorySenderNameFixture(accounts: EmailLoginDirectory())
    let accounts = f.accounts
    accounts.addAccount(id: f.ownerId, email: "history-sender-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: f.ownerId)
    accounts.addAccount(id: f.aliceId, email: "history-sender-alice@slock.test", password: "password123")
    accounts.markEmailVerified(userId: f.aliceId)
    accounts.addAccount(id: f.bobId, email: "history-sender-bob@slock.test", password: "password123")
    accounts.markEmailVerified(userId: f.bobId)
    accounts.oauth.addOwnedServer(id: f.serverId, slug: "history-sender", name: "History Sender", ownerId: f.ownerId)
    accounts.setAccountProfileForTesting(id: f.aliceId, name: "alice", displayName: "bob")
    accounts.setAccountProfileForTesting(id: f.bobId, name: "bob", displayName: "Bobby")
    accounts.oauth.addMember(serverId: f.serverId, userId: f.aliceId, role: "member")
    accounts.oauth.addMember(serverId: f.serverId, userId: f.bobId, role: "member")
    let grace = accounts.oauth.createAgent(serverId: f.serverId, name: "Grace", runtime: "claude")
    let twinAgent = accounts.oauth.createAgent(
        serverId: f.serverId, name: "TwinAgent", displayName: "Agent Display", runtime: "claude"
    )

    func humanDM(_ userId: String) -> String {
        let channelId = accounts.oauth.createDirectChannel(
            serverId: f.serverId, firstUserId: grace, secondUserId: userId,
            firstKind: .agent, secondKind: .human
        )
        for member in [grace, userId] {
            accounts.addPostableChannel(serverId: f.serverId, channelId: channelId, memberId: member, kind: "dm", name: "dm")
        }
        return channelId
    }
    let aliceDM = humanDM(f.aliceId)
    let bobDM = humanDM(f.bobId)
    _ = accounts.oauth.createMessageRecord(channelId: aliceDM, content: "from alice", senderId: f.aliceId)
    _ = accounts.oauth.createMessageRecord(channelId: bobDM, content: "from bob", senderId: f.bobId)

    let twinDM = accounts.oauth.createDirectChannel(
        serverId: f.serverId, firstUserId: grace, secondUserId: twinAgent,
        firstKind: .agent, secondKind: .agent
    )
    for member in [grace, twinAgent] {
        accounts.addPostableChannel(serverId: f.serverId, channelId: twinDM, memberId: member, kind: "dm", name: "dm")
    }
    _ = accounts.oauth.createMessageRecord(
        channelId: twinDM, content: "from the agent twin", senderId: twinAgent, senderType: "agent"
    )
    f.graceId = grace
    f.aliceDM = aliceDM
    f.bobDM = bobDM
    f.twinAgentDM = twinDM
    f.agentKey = accounts.mintAgentCredential(agentId: grace, scopes: ["send", "read"], name: "history-sender")
    return f
}

private func historyRead(
    _ client: any Client, apiKey: String, target: String
) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(apiKey)"
    let encoded = target.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? target
    let response = try await client.get(URI(string: "/internal/agent-api/history?channel=\(encoded)"), headers: headers)
    let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    return (response.status, body)
}

private extension Array where Element == [String: Any] {
    func senderNames() -> [String] {
        compactMap { $0["senderName"] as? String }
    }
}

@Test func historySenderNameIsTheCanonicalHandleNotTheDisplayName() async throws {
    let f = makeHistorySenderNameFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts
        ))
        try await app.testing { client in
            let bob = try await historyRead(client, apiKey: f.agentKey, target: "dm:@bob")
            #expect(bob.status == .ok)
            let bobMessages = bob.body["messages"] as? [[String: Any]] ?? []
            #expect(bobMessages.compactMap { $0["content"] as? String } == ["from bob"])
            #expect(bobMessages.senderNames() == ["bob"])
            #expect(!bobMessages.senderNames().contains("Bobby"))
            #expect(!bobMessages.senderNames().contains("alice"))

            let alice = try await historyRead(client, apiKey: f.agentKey, target: "dm:@alice")
            #expect(alice.status == .ok)
            let aliceMessages = alice.body["messages"] as? [[String: Any]] ?? []
            #expect(aliceMessages.compactMap { $0["content"] as? String } == ["from alice"])
            #expect(aliceMessages.senderNames() == ["alice"])
            #expect(!aliceMessages.senderNames().contains("bob"))

            // The machine-on-behalf surface prints the same canonical handle.
            let agentTwin = try await historyRead(client, apiKey: f.agentKey, target: "dm:@TwinAgent")
            #expect(agentTwin.status == .ok)
            let agentMessages = agentTwin.body["messages"] as? [[String: Any]] ?? []
            #expect(agentMessages.compactMap { $0["content"] as? String } == ["from the agent twin"])
            #expect(agentMessages.senderNames() == ["TwinAgent"])
            #expect(!agentMessages.senderNames().contains("Agent Display"))

            // Display names are not targets.
            for target in ["dm:@Agent Display", "dm:@Bobby", "dm:@Alice"] {
                let displayNameTarget = try await historyRead(client, apiKey: f.agentKey, target: target)
                #expect(displayNameTarget.status == .notFound, "\(target) must not resolve a peer")
            }
        }
    }
}

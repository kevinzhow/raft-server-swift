import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct DMPeerKindFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let serverSlug: String
    let graceId: String
    let humanTwinId: String
    let agentTwinId: String
    let apiKey: String
    let humanMsgId: String
    let agentMsgId: String
    let agentThreadId: String
}

private func makeDMPeerKindFixture(suffix: String) -> DMPeerKindFixture {
    let accounts = EmailLoginDirectory()
    let number = Int(suffix) ?? 0
    let serverId = String(format: "33333333-3333-4333-8333-%012d", 200_000 + number)
    let ownerId = String(format: "11111111-1111-4111-8111-%012d", 230_000 + number)
    let humanTwinId = String(format: "11111111-1111-4111-8111-%012d", 240_000 + number)
    accounts.addAccount(id: ownerId, email: "dm-kind-owner-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: humanTwinId, email: "dm-kind-twin-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: humanTwinId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "dm-kind-\(suffix)", name: "DM Peer Kind", ownerId: ownerId)
    accounts.setAccountProfileForTesting(id: humanTwinId, name: "Twin")
    accounts.oauth.addMember(serverId: serverId, userId: humanTwinId, role: "member")
    let grace = accounts.oauth.createAgent(serverId: serverId, name: "Grace-\(suffix)", runtime: "claude")
    let agentTwin = accounts.oauth.createAgent(serverId: serverId, name: "Twin", runtime: "claude")

    let humanDM = accounts.oauth.createDirectChannel(serverId: serverId, firstUserId: humanTwinId, secondUserId: grace)
    for member in [humanTwinId, grace] {
        accounts.addPostableChannel(serverId: serverId, channelId: humanDM, memberId: member, kind: "dm", name: "dm")
    }
    let humanMsg = accounts.oauth.createMessageRecord(channelId: humanDM, content: "from the human Twin", senderId: humanTwinId).id

    let agentDM = accounts.oauth.createDirectChannel(serverId: serverId, firstUserId: grace, secondUserId: agentTwin)
    for member in [grace, agentTwin] {
        accounts.addPostableChannel(serverId: serverId, channelId: agentDM, memberId: member, kind: "dm", name: "dm")
    }
    let agentMsg = accounts.oauth.createMessageRecord(channelId: agentDM, content: "from the agent Twin", senderId: agentTwin).id
    let agentThread = accounts.oauth.createThreadChannel(parentChannelId: agentDM, parentMessageId: agentMsg)
    for member in [grace, agentTwin] {
        accounts.addPostableChannel(serverId: serverId, channelId: agentThread, memberId: member, kind: "thread", parentChannelId: agentDM, parentMessageId: agentMsg, name: "thread")
    }
    _ = accounts.oauth.createMessageRecord(channelId: agentThread, content: "a reply in the agent Twin thread", senderId: agentTwin)

    let apiKey = accounts.mintAgentCredential(agentId: grace, scopes: ["send", "read"], name: "dm-peer-kind-\(suffix)")
    return DMPeerKindFixture(
        accounts: accounts,
        serverId: serverId,
        serverSlug: "dm-kind-\(suffix)",
        graceId: grace,
        humanTwinId: humanTwinId,
        agentTwinId: agentTwin,
        apiKey: apiKey,
        humanMsgId: humanMsg,
        agentMsgId: agentMsg,
        agentThreadId: agentThread
    )
}

private func dmRead(_ client: any Client, apiKey: String, target: String, around: String? = nil) async throws -> (status: HTTPResponse.Status, body: [String: Any], contents: [String]) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(apiKey)"
    let encoded = target.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? target
    var path = "/internal/agent-api/history?channel=\(encoded)"
    if let around, let encodedAround = around.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
        path += "&around=\(encodedAround)"
    }
    let response = try await client.get(URI(string: path), headers: headers)
    let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    let contents = (body["messages"] as? [[String: Any]] ?? []).compactMap { $0["content"] as? String }
    return (response.status, body, contents)
}

private func dmSend(_ client: any Client, apiKey: String, path: String, target: String) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(apiKey)"
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: URI(string: "/internal/agent-api/\(path)")) { request in
        request.body = .init(string: "{\"target\":\"\(target)\",\"content\":\"hello \(target)\",\"idempotencyKey\":\"\(UUID().uuidString.lowercased())\"}")
    }
    let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    return (response.status, body)
}

@Test func dmPeerKindSelectsAndPinsConversations() async throws {
    let fixture = makeDMPeerKindFixture(suffix: "861")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let bare = try await dmRead(client, apiKey: fixture.apiKey, target: "dm:@Twin")
            #expect(bare.status == .conflict)
            #expect(bare.body["code"] as? String == "DM_TARGET_AMBIGUOUS")

            let agent = try await dmRead(client, apiKey: fixture.apiKey, target: "dm:@Twin~agent")
            #expect(agent.status == .ok)
            #expect(agent.contents.contains("from the agent Twin"))
            #expect(!agent.contents.contains("from the human Twin"))

            let human = try await dmRead(client, apiKey: fixture.apiKey, target: "dm:@Twin~human")
            #expect(human.status == .ok)
            #expect(human.contents.contains("from the human Twin"))
            #expect(!human.contents.contains("from the agent Twin"))

            let anchor = String(fixture.agentMsgId.prefix(8))
            let control = try await dmRead(client, apiKey: fixture.apiKey, target: "dm:@Twin~agent", around: anchor)
            #expect(control.status == .ok)
            #expect(control.contents.contains("from the agent Twin"))
            let crossed = try await dmRead(client, apiKey: fixture.apiKey, target: "dm:@Twin~human", around: anchor)
            #expect(crossed.status != .ok)
            #expect(!crossed.contents.contains("from the agent Twin"))

            for suffix in [String(fixture.agentMsgId.prefix(8)), String(fixture.agentThreadId.prefix(8))] {
                let right = try await dmRead(client, apiKey: fixture.apiKey, target: "dm:@Twin~agent:\(suffix)")
                #expect(right.status == .ok)
                #expect(right.contents.contains("a reply in the agent Twin thread"))
                let wrong = try await dmRead(client, apiKey: fixture.apiKey, target: "dm:@Twin~human:\(suffix)")
                #expect(wrong.status != .ok)
                #expect(!wrong.contents.contains("a reply in the agent Twin thread"))
            }

            for path in ["send", "v2/send"] {
                let ambiguous = try await dmSend(client, apiKey: fixture.apiKey, path: path, target: "dm:@Twin")
                #expect(ambiguous.status == .conflict)
                #expect(ambiguous.body["code"] as? String == "DM_TARGET_AMBIGUOUS")
                #expect((ambiguous.body["error"] as? String)?.contains("dm:@Twin~agent") == true)
                let suggestion = ambiguous.body["suggestedNextAction"] as? String ?? ""
                #expect(suggestion.contains("dm:@Twin~agent"))
                #expect(suggestion.contains("dm:@Twin~human"))

                let badKind = try await dmSend(client, apiKey: fixture.apiKey, path: path, target: "dm:@Twin~bot")
                #expect(badKind.status == .badRequest)
                #expect(badKind.body["code"] as? String == "DM_TARGET_INVALID_PEER_KIND")
                #expect(badKind.body["suggestedNextAction"] is String)

                let pinned = try await dmSend(client, apiKey: fixture.apiKey, path: path, target: "dm:@Twin~agent")
                #expect(pinned.status == .ok)
            }

            let newcomer = fixture.accounts.oauth.createAgent(serverId: fixture.serverId, name: "Newcomer-\(UUID().uuidString.prefix(4))", runtime: "claude")
            let newcomerKey = fixture.accounts.mintAgentCredential(agentId: newcomer, scopes: ["send", "read"], name: "dm-newcomer")
            let newcomerBare = try await dmSend(client, apiKey: newcomerKey, path: "v2/send", target: "dm:@Twin")
            #expect(newcomerBare.status == .conflict)
            #expect(newcomerBare.body["code"] as? String == "DM_TARGET_AMBIGUOUS")
            #expect((newcomerBare.body["suggestedNextAction"] as? String)?.contains("dm:@Twin~human") == true)
            let unknown = try await dmSend(client, apiKey: newcomerKey, path: "v2/send", target: "dm:@NobodyByThisName")
            #expect(unknown.status == .notFound)
            let newcomerPinned = try await dmSend(client, apiKey: newcomerKey, path: "v2/send", target: "dm:@Twin~human")
            #expect(newcomerPinned.status == .ok)
        }
    }
}

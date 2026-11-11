import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct DmTargetFixture {
    let accounts: EmailLoginDirectory
    let senderKey: String
}

/// An agent sender plus an ambiguous `Twin` pair: one human member and one agent
/// share the name, which is exactly the case the DM-target error contract exists
/// for.
private func makeDmTargetFixture() -> DmTargetFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111633"
    let twinHumanId = "11111111-1111-4111-8111-111111111634"
    let serverId = "33333333-3333-4333-8333-333333333674"
    accounts.addAccount(id: ownerId, email: "dm-target-owner@slock.test", password: "password123")
    accounts.addAccount(id: twinHumanId, email: "Twin@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.markEmailVerified(userId: twinHumanId)
    // The handle is a profile fact, not the email local part: the fixture needs
    // the human's canonical `users.name` to be exactly `Twin` so the cross-kind
    // twin rule (exact names) is what makes the bare ref ambiguous.
    accounts.setAccountProfileForTesting(id: twinHumanId, name: "Twin")
    accounts.oauth.addOwnedServer(id: serverId, slug: "dm-target", name: "DM Target", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: twinHumanId, role: "member")
    _ = accounts.oauth.createAgent(serverId: serverId, name: "Twin", creatorUserId: ownerId)
    let sender = accounts.oauth.createAgent(serverId: serverId, name: "Sender", creatorUserId: ownerId)
    return DmTargetFixture(
        accounts: accounts,
        senderKey: accounts.mintAgentCredential(agentId: sender, scopes: ["send", "read"], name: "sender-key")
    )
}

private func agentSend(
    _ client: any Client,
    key: String,
    body: String
) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(key)"
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/internal/agent-api/send") { request in
        request.body = .init(string: body)
    }
    let json = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    return (response.status, json)
}

@Test func anAmbiguousDmTargetIsA409ThatNamesBothRefs() async throws {
    let f = makeDmTargetFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let res = try await agentSend(client, key: f.senderKey, body: "{\"target\":\"dm:@Twin\",\"content\":\"hello\"}")
            #expect(res.status == .conflict)
            #expect(res.body["code"] as? String == "DM_TARGET_AMBIGUOUS")
            let error = (res.body["error"] as? String) ?? ""
            #expect(error.contains("dm:@Twin~agent"))
            let nextAction = (res.body["suggestedNextAction"] as? String) ?? ""
            #expect(nextAction.contains("dm:@Twin~agent"))
            #expect(nextAction.contains("dm:@Twin~human"))
        }
    }
}

@Test func anUnknownDmPeerKindIsA400WithThePeerRefHint() async throws {
    let f = makeDmTargetFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let res = try await agentSend(client, key: f.senderKey, body: "{\"target\":\"dm:@Twin~bot\",\"content\":\"hello\"}")
            #expect(res.status == .badRequest)
            #expect(res.body["code"] as? String == "DM_TARGET_INVALID_PEER_KIND")
            let nextAction = res.body["suggestedNextAction"] as? String
            #expect((nextAction ?? "").contains("dm:@<name>~human"))
            #expect((nextAction ?? "").contains("dm:@<name>~agent"))

            // The typed refs themselves still resolve, so the errors above were
            // about ambiguity, not about a missing peer.
            let agentRef = try await agentSend(client, key: f.senderKey, body: "{\"target\":\"dm:@Twin~agent\",\"content\":\"hello agent twin\"}")
            #expect(agentRef.status == .ok, "an explicit ~agent ref resolves: \(agentRef.body)")
            let humanRef = try await agentSend(client, key: f.senderKey, body: "{\"target\":\"dm:@Twin~human\",\"content\":\"hello human twin\"}")
            #expect(humanRef.status == .ok, "an explicit ~human ref resolves: \(humanRef.body)")
        }
    }
}

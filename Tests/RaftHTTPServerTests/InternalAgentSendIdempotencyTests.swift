import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct SendIdempotencyFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let ownerToken: String
    let channelId: String
    let channelName: String
    let otherChannelId: String
    let otherChannelName: String
    let agentKey: String
}

private func makeSendIdempotencyFixture(_ suffix: String) -> SendIdempotencyFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001140\(suffix)"
    let serverId = "33333333-3333-4333-8333-000001140\(suffix)"
    accounts.addAccount(id: ownerId, email: "send-idem-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "send-idem-\(suffix)", name: "Send Idem \(suffix)", ownerId: ownerId)
    func channel(_ name: String) -> String {
        let id = accounts.oauth.createChannel(serverId: serverId, name: name, creatorUserId: ownerId)
        accounts.addPostableChannel(serverId: serverId, channelId: id, memberId: ownerId, kind: "channel", name: name)
        accounts.oauth.addChannelHuman(channelId: id, userId: ownerId)
        return id
    }
    let channelName = "send-idem-room-\(suffix)"
    let channelId = channel(channelName)
    let otherChannelName = "send-idem-other-\(suffix)"
    let otherChannelId = channel(otherChannelName)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "IdemBot\(suffix)", creatorUserId: ownerId, runtime: "claude")
    accounts.oauth.addChannelAgent(channelId: channelId, agentId: agentId)
    accounts.oauth.addChannelAgent(channelId: otherChannelId, agentId: agentId)
    return SendIdempotencyFixture(
        accounts: accounts,
        serverId: serverId,
        ownerId: ownerId,
        ownerToken: accounts.mintAccessTokenForTesting(userId: ownerId),
        channelId: channelId,
        channelName: channelName,
        otherChannelId: otherChannelId,
        otherChannelName: otherChannelName,
        agentKey: accounts.mintAgentCredential(agentId: agentId, scopes: ["read", "send"], name: "idem-\(suffix)")
    )
}

private func idemHumanHeaders(_ token: String, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

private func idemAgentHeaders(_ key: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(key)"
    headers[.contentType] = "application/json"
    return headers
}

private func idemJSON(_ response: ClientResponse) throws -> [String: Any] {
    (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

private func idemSend(
    _ client: any Client,
    key: String,
    path: String,
    body: String
) async throws -> ClientResponse {
    try await client.send(.post, headers: idemAgentHeaders(key), to: URI(string: path)) { request in
        request.body = .init(string: body)
    }
}

private func idemChannelMessages(
    _ client: any Client,
    fixture: SendIdempotencyFixture,
    channelId: String
) async throws -> [[String: Any]] {
    let response = try await client.get(
        URI(string: "/api/messages/channel/\(channelId)"),
        headers: idemHumanHeaders(fixture.ownerToken, fixture.serverId)
    )
    return (try idemJSON(response)["messages"] as? [[String: Any]]) ?? []
}

@Test func agentApiSendReplaysAnIdempotencyKeyOnlyForTheSameRequest() async throws {
    let f = makeSendIdempotencyFixture("001")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            for path in ["/internal/agent-api/send", "/internal/agent-api/v2/send"] {
                let key = "replay-\(path.hasSuffix("v2/send") ? "v2" : "v1")-001"
                let request = "{\"target\":\"#\(f.channelName)\",\"content\":\"exactly once\",\"idempotencyKey\":\"\(key)\"}"
                let first = try await idemSend(client, key: f.agentKey, path: path, body: request)
                #expect(first.status == .ok)
                let firstBody = try idemJSON(first)
                #expect(firstBody["state"] as? String == "sent")
                let messageId = try #require(firstBody["messageId"] as? String)

                let identical = try await idemSend(client, key: f.agentKey, path: path, body: request)
                #expect(identical.status == .ok)
                let identicalBody = try idemJSON(identical)
                #expect(identicalBody["state"] as? String == "sent")
                #expect(identicalBody["messageId"] as? String == messageId)
                #expect(identicalBody["messageSeq"] as? Int == firstBody["messageSeq"] as? Int)

                let otherContent = try await idemSend(
                    client,
                    key: f.agentKey,
                    path: path,
                    body: "{\"target\":\"#\(f.channelName)\",\"content\":\"something else\",\"idempotencyKey\":\"\(key)\"}"
                )
                #expect(otherContent.status == .conflict)
                let contentBody = try idemJSON(otherContent)
                #expect(contentBody["code"] as? String == "idempotency_key_reused")
                #expect(contentBody["mismatch"] as? String == "content")
                #expect((contentBody["suggestedNextAction"] as? String ?? "").contains("new idempotencyKey"))
                #expect(contentBody["messageId"] == nil)

                let otherTarget = try await idemSend(
                    client,
                    key: f.agentKey,
                    path: path,
                    body: "{\"target\":\"#\(f.otherChannelName)\",\"content\":\"exactly once\",\"idempotencyKey\":\"\(key)\"}"
                )
                #expect(otherTarget.status == .conflict)
                let targetBody = try idemJSON(otherTarget)
                #expect(targetBody["code"] as? String == "idempotency_key_reused")
                #expect(targetBody["mismatch"] as? String == "target")
            }

            let rows = try await idemChannelMessages(client, fixture: f, channelId: f.channelId)
            #expect(rows.filter { $0["content"] as? String == "exactly once" }.count == 2, "one message per key")
            #expect(!rows.contains { $0["content"] as? String == "something else" })
        }
    }
}

@Test func agentApiSendReconcilesAnIdempotencyKeyWithoutWriting() async throws {
    let f = makeSendIdempotencyFixture("002")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let key = "reconcile-002"
            let before = try await idemSend(
                client,
                key: f.agentKey,
                path: "/internal/agent-api/v2/send",
                body: "{\"target\":\"#\(f.channelName)\",\"idempotencyKey\":\"\(key)\",\"reconcileOnly\":true}"
            )
            #expect(before.status == .ok)
            let beforeBody = try idemJSON(before)
            #expect(beforeBody["state"] as? String == "not_found")
            #expect(beforeBody["reconciliation"] as? Bool == true)
            #expect(try await idemChannelMessages(client, fixture: f, channelId: f.channelId).isEmpty)

            let sent = try await idemSend(
                client,
                key: f.agentKey,
                path: "/internal/agent-api/v2/send",
                body: "{\"target\":\"#\(f.channelName)\",\"content\":\"commit once\",\"idempotencyKey\":\"\(key)\"}"
            )
            #expect(sent.status == .ok)
            let sentBody = try idemJSON(sent)
            #expect(sentBody["state"] as? String == "sent")

            let after = try await idemSend(
                client,
                key: f.agentKey,
                path: "/internal/agent-api/v2/send",
                body: "{\"target\":\"#\(f.channelName)\",\"idempotencyKey\":\"\(key)\",\"reconcileOnly\":true}"
            )
            #expect(after.status == .ok)
            let afterBody = try idemJSON(after)
            #expect(afterBody["state"] as? String == "committed")
            #expect(afterBody["messageId"] as? String == sentBody["messageId"] as? String)
            #expect(afterBody["messageSeq"] as? Int == sentBody["messageSeq"] as? Int)
            #expect(afterBody["reconciliation"] as? Bool == true)
            #expect(afterBody["receiptComplete"] as? Bool == false)
            #expect(try await idemChannelMessages(client, fixture: f, channelId: f.channelId).count == 1)
        }
    }
}

@Test func agentApiSendRejectsMalformedAttachmentIDsWithoutEchoingThem() async throws {
    let f = makeSendIdempotencyFixture("003")
    let first = "11111111-1111-4111-8111-111111111111"
    let second = "22222222-2222-4222-8222-222222222222"
    let cases: [(path: String, ids: String, entry: Int)] = [
        ("/internal/agent-api/send", "[\"\(first) \(second)\"]", 1),
        ("/internal/agent-api/send", "[\"\(first),\(second)\"]", 1),
        ("/internal/agent-api/v2/send", "[\"\(first)\",\"not-an-id\"]", 2),
    ]
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            for (index, entry) in cases.enumerated() {
                let response = try await idemSend(
                    client,
                    key: f.agentKey,
                    path: entry.path,
                    body: "{\"target\":\"#\(f.channelName)\",\"content\":\"malformed attachment \(index)\",\"attachmentIds\":\(entry.ids)\(index == 1 ? ",\"idempotencyKey\":\"malformed-attachment-replay\"" : "")}"
                )
                #expect(response.status == .badRequest, "case \(index)")
                let body = try idemJSON(response)
                #expect(body["code"] as? String == "attachment_id_invalid")
                let error = (body["error"] as? String) ?? ""
                #expect(error.hasPrefix("Not sent: attachmentIds entry \(entry.entry) is not a single attachment ID."))
                #expect(error.contains("one ID per --attachment-id"))
                #expect(!(response.body.string ?? "").contains(first), "the rejected value is not echoed")
            }
            let rows = try await idemChannelMessages(client, fixture: f, channelId: f.channelId)
            #expect(!rows.contains { ($0["content"] as? String ?? "").hasPrefix("malformed attachment") })
        }
    }
}

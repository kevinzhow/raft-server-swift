import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct ReceiptDmFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let agentId: String
    let otherAgentId: String
    let agentKey: String
    let otherKey: String
    let receiptChannelId: String
    let target: String
}

private func makeReceiptDmFixture() -> ReceiptDmFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111643"
    let serverId = "33333333-3333-4333-8333-333333333683"
    accounts.addAccount(id: ownerId, email: "receipt-dm-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "receipt-dm", name: "Receipt DM", ownerId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "mover", creatorUserId: ownerId, runtime: "codex")
    let otherAgentId = accounts.oauth.createAgent(serverId: serverId, name: "bystander", creatorUserId: ownerId, runtime: "codex")
    let supportRef = "mig-receipt-123"
    let receiptChannelId = accounts.createMigrationReceiptDmForTesting(agentId: agentId, supportRef: supportRef) ?? ""
    return ReceiptDmFixture(
        accounts: accounts,
        serverId: serverId,
        agentId: agentId,
        otherAgentId: otherAgentId,
        agentKey: accounts.mintAgentCredential(agentId: agentId, scopes: ["send", "read"], name: "receipt-dm"),
        otherKey: accounts.mintAgentCredential(agentId: otherAgentId, scopes: ["send", "read"], name: "receipt-dm-other"),
        receiptChannelId: receiptChannelId,
        target: "dm:@migration-receipt-\(supportRef)"
    )
}

private func receiptRequest(
    _ client: any Client,
    key: String,
    method: HTTPRequest.Method,
    path: String,
    body: String? = nil
) async throws -> (status: HTTPResponse.Status, body: [String: Any], raw: String) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(key)"
    if body != nil { headers[.contentType] = "application/json" }
    let response = try await client.send(method, headers: headers, to: URI(string: path)) { request in
        if let body { request.body = .init(string: body) }
    }
    let raw = response.body.string ?? ""
    let json = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
    return (response.status, json, raw)
}

@Test func migratedAgentReadsItsReceiptUnderTheInboxName() async throws {
    let f = makeReceiptDmFixture()
    #expect(!f.receiptChannelId.isEmpty)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            // The inbox prints the same name the agent can address.
            let inbox = try await receiptRequest(client, key: f.agentKey, method: .get, path: "/internal/agent-api/inbox/conversations")
            #expect(inbox.status == .ok)
            let items = (inbox.body["items"] as? [[String: Any]]) ?? []
            #expect(items.contains { ($0["target"] as? String) == f.target }, "the receipt DM is listed under dm:@migration-receipt-<ref>")

            let encoded = f.target.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            let history = try await receiptRequest(client, key: f.agentKey, method: .get, path: "/internal/agent-api/history?channel=\(encoded)")
            #expect(history.status == .ok)
            #expect(history.raw.contains("Migration completed"))
            #expect(history.raw.contains("mig-receipt-123"))

            // Another agent learns nothing beyond a channel it cannot see.
            let other = try await receiptRequest(client, key: f.otherKey, method: .get, path: "/internal/agent-api/history?channel=\(encoded)")
            #expect(other.status == .notFound)
            #expect(other.body["error"] as? String == "Channel not found or not visible")
            #expect(!other.raw.contains("Migration completed"))
        }
    }
}

@Test func replyingToAReceiptIsAReadOnlyConflictAndPostsNothing() async throws {
    let f = makeReceiptDmFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let countBefore = f.accounts.messageCountForTesting(channelId: f.receiptChannelId)
            for route in ["/internal/agent-api/send", "/internal/agent-api/v2/send"] {
                let sent = try await receiptRequest(
                    client, key: f.agentKey, method: .post, path: route,
                    body: "{\"target\":\"\(f.target)\",\"content\":\"thanks!\"}"
                )
                #expect(sent.status == .conflict, "\(route) refuses a receipt reply")
                #expect(sent.body["code"] as? String == "MIGRATION_RECEIPT_READ_ONLY")
                #expect(((sent.body["error"] as? String) ?? "").contains("one-way notice"))
                #expect(((sent.body["suggestedNextAction"] as? String) ?? "").contains("owner's DM"))
            }
            #expect(f.accounts.messageCountForTesting(channelId: f.receiptChannelId) == countBefore, "no agent message landed in the receipt DM")

            let other = try await receiptRequest(
                client, key: f.otherKey, method: .post, path: "/internal/agent-api/send",
                body: "{\"target\":\"\(f.target)\",\"content\":\"hi\"}"
            )
            #expect(other.status == .notFound)
        }
    }
}

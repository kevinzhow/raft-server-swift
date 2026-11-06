import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

/// Locks the `POST /api/actions/:messageId/mark-executed` contract that the
/// other action-card tests only reach through guest/private refusals: the
/// result-kind checks and the canonical executed metadata.
@Test func markExecutedValidatesTheResultKindAndReturnsTheExecutedMetadata() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111710"
    let serverId = "33333333-3333-4333-8333-333333333710"
    accounts.addAccount(id: ownerId, email: "mark-executed-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "mark-executed", name: "Mark Executed", ownerId: ownerId)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "mark-executed-agent", runtime: "claude")
    let carrier = accounts.oauth.createChannel(serverId: serverId, name: "mark-executed-carrier", creatorUserId: ownerId)
    let cardId = accounts.addActionCardForTesting(
        serverId: serverId,
        agentId: agent,
        carrierChannelId: carrier,
        actionType: "channel:create",
        state: "prepared"
    )
    let token = accounts.mintAccessTokenForTesting(userId: ownerId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId

            func mark(_ body: String) async throws -> ClientResponse {
                try await client.send(.post, headers: headers, to: URI(string: "/api/actions/\(cardId)/mark-executed")) { request in
                    request.body = .init(string: body)
                }
            }
            func object(_ response: ClientResponse) throws -> [String: Any] {
                (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]) ?? [:]
            }

            let missing = try await mark("{}")
            #expect(missing.status == .badRequest)
            #expect(missing.body.string == #"{"code":"INVALID_RESULT","error":"A result is required"}"#)
            #expect(accounts.actionCardStateForTesting(messageId: cardId) == "prepared")

            let mismatch = try await mark(#"{"result":{"kind":"message"}}"#)
            #expect(mismatch.status == .conflict)
            #expect(mismatch.body.string == #"{"code":"INCOMPATIBLE_RESULT","error":"The result kind does not match this action"}"#)
            #expect(accounts.actionCardStateForTesting(messageId: cardId) == "prepared")

            let marked = try await mark(#"{"result":{"kind":"channel","id":"made-up","name":"made-up"}}"#)
            #expect(marked.status == .ok)
            #expect(marked.body.string == #"{"messageId":"\#(cardId)","metadata":{"kind":"action-card","state":"executed"}}"#)
            let body = try object(marked)
            #expect(body["messageId"] as? String == cardId)
            let metadata = body["metadata"] as? [String: Any]
            #expect(metadata?["kind"] as? String == "action-card")
            #expect(metadata?["state"] as? String == "executed")
            #expect(accounts.actionCardStateForTesting(messageId: cardId) == "executed")

            // Marking an already-executed card is idempotent and answers the
            // same canonical metadata.
            let repeated = try await mark(#"{"result":{"kind":"channel"}}"#)
            #expect(repeated.status == .ok)
            #expect(repeated.body.string == marked.body.string)
        }
    }
}

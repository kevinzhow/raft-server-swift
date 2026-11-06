import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func joinedGuestsReadActionCardsButCannotExecuteOrMarkThem() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111672"
    let guestId = "11111111-1111-4111-8111-111111111673"
    let serverId = "33333333-3333-4333-8333-333333333698"
    accounts.addAccount(id: ownerId, email: "card-guest-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: guestId, email: "card-guest-guest@slock.test", password: "password123")
    accounts.markEmailVerified(userId: guestId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "card-guest", name: "Card Guest", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: guestId, role: "guest")
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "card-guest-agent", runtime: "codex")
    let carrier = accounts.oauth.createChannel(serverId: serverId, name: "card-guest-carrier", creatorUserId: ownerId)
    for member in [ownerId, agent] {
        accounts.addPostableChannel(serverId: serverId, channelId: carrier, memberId: member, name: "card-guest-carrier")
    }
    accounts.oauth.addChannelHuman(channelId: carrier, userId: guestId)
    accounts.oauth.addChannelHuman(channelId: carrier, userId: ownerId)
    accounts.oauth.addChannelAgent(channelId: carrier, agentId: agent)
    accounts.setChannelGuestVisibleForTesting(channelId: carrier, visible: true)
    let apiKey = accounts.mintAgentCredential(agentId: agent, scopes: ["send", "read", "mentions"], name: "card-guest")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            var prepareHeaders = HTTPFields()
            prepareHeaders[.authorization] = "Bearer \(apiKey)"
            prepareHeaders[.contentType] = "application/json"
            let prepared = try await client.send(.post, headers: prepareHeaders, to: "/internal/agent-api/prepare-action") { request in
                request.body = .init(string: ##"{"target":"#card-guest-carrier","action":{"type":"channel:create","name":"guest-must-not-create","visibility":"public"}}"##)
            }
            #expect(prepared.status == .created, "\(prepared.status) \((prepared.body.string ?? "").prefix(160))")
            let messageId = (try JSONSerialization.jsonObject(with: Data((prepared.body.string ?? "").utf8)) as? [String: Any])?["messageId"] as? String ?? ""
            #expect(!messageId.isEmpty)

            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(accounts.mintAccessTokenForTesting(userId: guestId))"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let history = try await client.get(URI(string: "/api/messages/channel/\(carrier)"), headers: headers)
            #expect(history.status == .ok)
            #expect((history.body.string ?? "").contains(messageId), "the guest may read the card summary")

            func post(_ suffix: String, _ body: String) async throws -> HTTPResponse.Status {
                let response = try await client.send(.post, headers: headers, to: URI(string: "/api/actions/\(messageId)/\(suffix)")) { request in
                    request.body = .init(string: body)
                }
                return response.status
            }
            let execute = try await post("execute", #"{"expectedState":"prepared"}"#)
            #expect(execute == .forbidden)
            let mark = try await post("mark-executed", #"{"result":{"kind":"channel","id":"\#(carrier)","name":"fake"}}"#)
            #expect(mark == .forbidden)
        }
    }
}

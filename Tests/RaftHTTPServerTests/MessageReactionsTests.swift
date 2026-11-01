import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct ReactionFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let channelId: String
    let messageId: String
    let ownerId: String
    let ownerEmail: String
    let ownerDisplay: String
}

private func makeReactionFixture(suffix: String) -> ReactionFixture {
    let accounts = EmailLoginDirectory()
    let number = Int(suffix) ?? 0
    let serverId = String(format: "33333333-3333-4333-8333-%012d", 950_000 + number)
    let ownerId = String(format: "11111111-1111-4111-8111-%012d", 950_000 + number)
    let ownerEmail = "reaction-owner-\(suffix)@slock.test"
    let ownerDisplay = "Reaction Owner \(suffix)"
    accounts.addAccount(id: ownerId, email: ownerEmail, password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.setAccountProfileForTesting(id: ownerId, name: "reaction-owner-\(suffix)", displayName: ownerDisplay)
    accounts.oauth.addOwnedServer(id: serverId, slug: "reaction-server-\(suffix)", name: "Reaction Server", ownerId: ownerId)
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "reaction-channel-\(suffix)", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "reaction-channel-\(suffix)")
    accounts.oauth.addChannelHuman(channelId: channel, userId: ownerId)
    let message = accounts.addChannelMessageForTesting(channelId: channel, content: "reactable message", senderId: ownerId)
    return ReactionFixture(
        accounts: accounts,
        serverId: serverId,
        channelId: channel,
        messageId: message,
        ownerId: ownerId,
        ownerEmail: ownerEmail,
        ownerDisplay: ownerDisplay
    )
}

private func reactionLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
}

private func reactionHeaders(_ token: String, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

private func reactionObject(_ response: ClientResponse) throws -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

@Test func messageReactionsAddIdempotentlyEnrichAndRemoveCleanly() async throws {
    let fixture = makeReactionFixture(suffix: "981")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let token = try await reactionLogin(client, email: fixture.ownerEmail)
            let headers = reactionHeaders(token, fixture.serverId)
            let path = "/api/messages/\(fixture.messageId)/reactions"

            let first = try await client.send(.post, headers: headers, to: URI(string: path)) { request in
                request.body = .init(string: "{\"emoji\":\"👍\"}")
            }
            #expect(first.status == .ok)
            #expect(try reactionObject(first)["reactions"] as? NSArray == [
                ["emoji": "👍", "count": 1, "reactorIds": [fixture.ownerId], "reactorNames": [fixture.ownerDisplay]] as NSDictionary
            ] as NSArray)

            let second = try await client.send(.post, headers: headers, to: URI(string: path)) { request in
                request.body = .init(string: "{\"emoji\":\"👍\"}")
            }
            #expect(second.status == .ok)
            let secondReactions = try reactionObject(second)["reactions"] as? [[String: Any]] ?? []
            #expect(secondReactions.first { $0["emoji"] as? String == "👍" }?["count"] as? Int == 1)

            let list = try await client.get("/api/messages/channel/\(fixture.channelId)", headers: headers)
            #expect(list.status == .ok)
            let rows = try reactionObject(list)["messages"] as? [[String: Any]] ?? []
            let row = try #require(rows.first { $0["id"] as? String == fixture.messageId })
            let listedReactions = row["reactions"] as? [[String: Any]] ?? []
            #expect(listedReactions.first?["count"] as? Int == 1)

            let remove = try await client.send(.delete, headers: headers, to: URI(string: path)) { request in
                request.body = .init(string: "{\"emoji\":\"👍\"}")
            }
            #expect(remove.status == .ok)
            #expect(try reactionObject(remove)["reactions"] as? NSArray == [] as NSArray)
            #expect(fixture.accounts.storedMessageReactionActors(messageId: fixture.messageId).isEmpty)
        }
    }
}

import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct ReadAllFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let ownerToken: String
    let memberId: String
    let memberToken: String
    let senderId: String
    let senderToken: String
    let agentId: String
    let privateChannelId: String
    let publicChannelId: String
}

private func makeReadAllFixture(_ suffix: String) -> ReadAllFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001300\(suffix)"
    let memberId = "11111111-1111-4111-8111-000001301\(suffix)"
    let senderId = "11111111-1111-4111-8111-000001302\(suffix)"
    let serverId = "33333333-3333-4333-8333-000001300\(suffix)"
    for (id, email) in [
        (ownerId, "read-all-owner-\(suffix)@slock.test"),
        (memberId, "read-all-member-\(suffix)@slock.test"),
        (senderId, "read-all-sender-\(suffix)@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "read-all-\(suffix)", name: "Read All \(suffix)", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    accounts.oauth.addMember(serverId: serverId, userId: senderId, role: "member")
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "ReadAllBot\(suffix)", creatorUserId: ownerId, runtime: "codx")
    let privateChannelId = accounts.oauth.createChannel(serverId: serverId, name: "read-all-private-\(suffix)", creatorUserId: ownerId, type: "private")
    accounts.addPostableChannel(serverId: serverId, channelId: privateChannelId, memberId: senderId, kind: "private", name: "read-all-private-\(suffix)")
    accounts.oauth.addChannelHuman(channelId: privateChannelId, userId: senderId)
    accounts.oauth.addChannelAgent(channelId: privateChannelId, agentId: agentId)
    let publicChannelId = accounts.oauth.createChannel(serverId: serverId, name: "read-all-public-\(suffix)", creatorUserId: ownerId)
    for id in [ownerId, senderId] {
        accounts.addPostableChannel(serverId: serverId, channelId: publicChannelId, memberId: id, kind: "channel", name: "read-all-public-\(suffix)")
        accounts.oauth.addChannelHuman(channelId: publicChannelId, userId: id)
    }
    accounts.enableReadReceiptsForServer(serverId)
    return ReadAllFixture(
        accounts: accounts,
        serverId: serverId,
        ownerId: ownerId,
        ownerToken: accounts.mintAccessTokenForTesting(userId: ownerId),
        memberId: memberId,
        memberToken: accounts.mintAccessTokenForTesting(userId: memberId),
        senderId: senderId,
        senderToken: accounts.mintAccessTokenForTesting(userId: senderId),
        agentId: agentId,
        privateChannelId: privateChannelId,
        publicChannelId: publicChannelId
    )
}

private func readAllHeaders(_ token: String, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

private func readAllPost(
    _ client: any Client,
    f: ReadAllFixture,
    token: String,
    channelId: String,
    body: String = "{}"
) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    let response = try await client.send(.post, headers: readAllHeaders(token, f.serverId), to: "/api/channels/\(channelId)/read-all") { request in
        request.body = .init(string: body)
    }
    let json = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    return (response.status, json)
}

@Test func readAllDelegatesToAnAgentReceiverWithoutTouchingHumanState() async throws {
    let f = makeReadAllFixture("901")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let message = try await client.send(.post, headers: readAllHeaders(f.senderToken, f.serverId), to: "/api/messages") { request in
                request.body = .init(string: "{\"channelId\":\"\(f.privateChannelId)\",\"content\":\"delegated read\"}")
            }
            let messageBody = (try? JSONSerialization.jsonObject(with: Data((message.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            let messageId = try #require(messageBody["id"] as? String)
            let seq = try #require(f.accounts.humanMessageSequence(id: messageId))

            let delegated = try await readAllPost(
                client,
                f: f,
                token: f.ownerToken,
                channelId: f.privateChannelId,
                body: "{\"receiver\":{\"kind\":\"agent\",\"id\":\"\(f.agentId)\"}}"
            )
            #expect(delegated.status == .ok)
            #expect(delegated.body["ok"] as? Bool == true)
            #expect(delegated.body["seq"] as? Int == seq)
            #expect(delegated.body["readStateVersion"] as? Int == 1)
            #expect(f.accounts.agentReadCursor(channelId: f.privateChannelId, agentId: f.agentId) == seq)
            #expect(f.accounts.humanReadCursor(channelId: f.privateChannelId, userId: f.ownerId) == 0, "the human caller frontier stays untouched")
        }
    }
}

@Test func readAllDelegationIsAuthorityCheckedAndNeverFallsBack() async throws {
    let f = makeReadAllFixture("902")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            _ = try await client.send(.post, headers: readAllHeaders(f.senderToken, f.serverId), to: "/api/messages") { request in
                request.body = .init(string: "{\"channelId\":\"\(f.privateChannelId)\",\"content\":\"delegated read\"}")
            }

            let denied = try await readAllPost(
                client,
                f: f,
                token: f.memberToken,
                channelId: f.privateChannelId,
                body: "{\"receiver\":{\"kind\":\"agent\",\"id\":\"\(f.agentId)\"}}"
            )
            #expect(denied.status == .forbidden)
            #expect(f.accounts.agentReadCursor(channelId: f.privateChannelId, agentId: f.agentId) == 0, "an unauthorized delegation is a zero-write")
            #expect(f.accounts.humanReadCursor(channelId: f.privateChannelId, userId: f.memberId) == 0)

            let mismatched = try await readAllPost(
                client,
                f: f,
                token: f.ownerToken,
                channelId: f.privateChannelId,
                body: "{\"receiver\":{\"kind\":\"human\",\"id\":\"\(f.ownerId)\"}}"
            )
            #expect(mismatched.status == .forbidden)
            #expect(f.accounts.humanReadCursor(channelId: f.privateChannelId, userId: f.ownerId) == 0)
        }
    }
}

@Test func readAllWithoutAReceiverMarksTheCallersOwnScope() async throws {
    let f = makeReadAllFixture("903")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let message = try await client.send(.post, headers: readAllHeaders(f.senderToken, f.serverId), to: "/api/messages") { request in
                request.body = .init(string: "{\"channelId\":\"\(f.publicChannelId)\",\"content\":\"own scope read\"}")
            }
            let messageBody = (try? JSONSerialization.jsonObject(with: Data((message.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            let messageId = try #require(messageBody["id"] as? String)
            let seq = try #require(f.accounts.humanMessageSequence(id: messageId))

            let result = try await readAllPost(client, f: f, token: f.ownerToken, channelId: f.publicChannelId)
            #expect(result.status == .ok)
            #expect(result.body["ok"] as? Bool == true)
            #expect(result.body["seq"] as? Int == seq)
            #expect(result.body["readStateVersion"] as? Int == 1)
            let detail = try await client.get(URI(string: "/api/channels/\(f.publicChannelId)"), headers: readAllHeaders(f.ownerToken, f.serverId))
            let detailBody = (try? JSONSerialization.jsonObject(with: Data((detail.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            #expect(detailBody["maxReadSeq"] as? Int == seq)
            #expect(f.accounts.agentReadCursor(channelId: f.publicChannelId, agentId: f.agentId) == 0)
        }
    }
}

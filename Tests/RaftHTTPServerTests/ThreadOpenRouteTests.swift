import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct ThreadOpenFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let ownerEmail: String
    let replierId: String
    let replierEmail: String
    let channelId: String
    let parentMessageId: String
}

private func makeThreadOpenFixture(suffix: String) -> ThreadOpenFixture {
    let accounts = EmailLoginDirectory()
    let number = Int(suffix) ?? 0
    let serverId = String(format: "33333333-3333-4333-8333-%012d", 950_000 + number)
    let ownerId = String(format: "11111111-1111-4111-8111-%012d", 950_000 + number)
    let replierId = String(format: "11111111-1111-4111-8111-%012d", 951_000 + number)
    let ownerEmail = "thread-open-owner-\(suffix)@slock.test"
    let replierEmail = "thread-open-replier-\(suffix)@slock.test"
    for (id, email) in [(ownerId, ownerEmail), (replierId, replierEmail)] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "thread-open-\(suffix)", name: "Thread Open", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: replierId, role: "member")
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "thread-open-\(suffix)", creatorUserId: ownerId)
    for id in [ownerId, replierId] {
        accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: id, name: "thread-open-\(suffix)")
        accounts.oauth.addChannelHuman(channelId: channel, userId: id)
    }
    let parent = accounts.addChannelMessageForTesting(channelId: channel, content: "original", senderId: ownerId)
    return ThreadOpenFixture(
        accounts: accounts,
        serverId: serverId,
        ownerId: ownerId,
        ownerEmail: ownerEmail,
        replierId: replierId,
        replierEmail: replierEmail,
        channelId: channel,
        parentMessageId: parent
    )
}

private func threadOpenLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
}

private func threadOpenHeaders(_ token: String, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

private func threadOpenObject(_ response: ClientResponse) throws -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

private func threadOpenCreate(
    _ client: any Client,
    token: String,
    serverId: String,
    channelId: String,
    body: String
) async throws -> ClientResponse {
    try await client.send(
        .post,
        headers: threadOpenHeaders(token, serverId),
        to: URI(string: "/api/channels/\(channelId)/threads")
    ) { request in
        request.body = .init(string: body)
    }
}

private func followedThreadIDs(_ client: any Client, token: String, serverId: String) async throws -> [String] {
    let response = try await client.send(.get, headers: threadOpenHeaders(token, serverId), to: "/api/channels/threads/followed")
    #expect(response.status == .ok)
    let rows = (try threadOpenObject(response))["threads"] as? [[String: Any]] ?? []
    return rows.compactMap { $0["threadChannelId"] as? String }
}

@Test func threadOpenCreatesAnEmptyThreadWithoutFollowingTheViewer() async throws {
    let fixture = makeThreadOpenFixture(suffix: "1301")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let replier = try await threadOpenLogin(client, email: fixture.replierEmail)
            let response = try await threadOpenCreate(
                client,
                token: replier,
                serverId: fixture.serverId,
                channelId: fixture.channelId,
                body: "{\"parentMessageId\":\"\(fixture.parentMessageId)\"}"
            )
            #expect(response.status == .ok)
            let body = try threadOpenObject(response)
            let threadId = try #require(body["threadChannelId"] as? String)
            #expect(body["replyCount"] as? Int == 0)
            #expect(body["lastReplyAt"] is NSNull)
            #expect(body["participantIds"] as? [String] == [])
            #expect(try await followedThreadIDs(client, token: replier, serverId: fixture.serverId).contains(threadId) == false)
        }
    }
}

@Test func threadOpenRejectsAMissingBodyAndForeignParents() async throws {
    let fixture = makeThreadOpenFixture(suffix: "1302")
    let otherChannel = fixture.accounts.oauth.createChannel(
        serverId: fixture.serverId,
        name: "thread-open-other-1302",
        creatorUserId: fixture.ownerId
    )
    fixture.accounts.addPostableChannel(
        serverId: fixture.serverId,
        channelId: otherChannel,
        memberId: fixture.ownerId,
        name: "thread-open-other-1302"
    )
    let foreignParent = fixture.accounts.addChannelMessageForTesting(
        channelId: otherChannel,
        content: "parent from another channel",
        senderId: fixture.ownerId
    )
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let owner = try await threadOpenLogin(client, email: fixture.ownerEmail)
            let missing = try await client.send(
                .post,
                headers: threadOpenHeaders(owner, fixture.serverId),
                to: URI(string: "/api/channels/\(fixture.channelId)/threads")
            )
            #expect(missing.status == .badRequest)
            #expect(try threadOpenObject(missing) as NSDictionary == ["error": "parentMessageId is required"] as NSDictionary)

            let foreign = try await threadOpenCreate(
                client,
                token: owner,
                serverId: fixture.serverId,
                channelId: fixture.channelId,
                body: "{\"parentMessageId\":\"\(foreignParent)\"}"
            )
            #expect(foreign.status == .notFound)
            #expect(try threadOpenObject(foreign) as NSDictionary == ["error": "Parent message not found"] as NSDictionary)
        }
    }
}

@Test func firstThreadReplyFollowsTheSenderAndTheParentAuthor() async throws {
    let fixture = makeThreadOpenFixture(suffix: "1303")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let owner = try await threadOpenLogin(client, email: fixture.ownerEmail)
            let replier = try await threadOpenLogin(client, email: fixture.replierEmail)
            let response = try await threadOpenCreate(
                client,
                token: replier,
                serverId: fixture.serverId,
                channelId: fixture.channelId,
                body: "{\"parentMessageId\":\"\(fixture.parentMessageId)\",\"content\":\"first reply\"}"
            )
            #expect(response.status == .ok)
            let threadId = try #require(try threadOpenObject(response)["threadChannelId"] as? String)
            #expect(try await followedThreadIDs(client, token: replier, serverId: fixture.serverId).contains(threadId))
            #expect(try await followedThreadIDs(client, token: owner, serverId: fixture.serverId).contains(threadId))
        }
    }
}

@Test func newThreadActivityClearsDoneAndReactivatesTheFollowedThread() async throws {
    let fixture = makeThreadOpenFixture(suffix: "1304")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let owner = try await threadOpenLogin(client, email: fixture.ownerEmail)
            let replier = try await threadOpenLogin(client, email: fixture.replierEmail)
            let created = try await threadOpenCreate(
                client,
                token: replier,
                serverId: fixture.serverId,
                channelId: fixture.channelId,
                body: "{\"parentMessageId\":\"\(fixture.parentMessageId)\",\"content\":\"first reply\"}"
            )
            let threadId = try #require(try threadOpenObject(created)["threadChannelId"] as? String)
            #expect(try await followedThreadIDs(client, token: owner, serverId: fixture.serverId).contains(threadId))

            let done = try await client.send(
                .post,
                headers: threadOpenHeaders(owner, fixture.serverId),
                to: "/api/channels/threads/done"
            ) { request in
                request.body = .init(string: "{\"threadChannelId\":\"\(threadId)\"}")
            }
            #expect(done.status == .ok)
            #expect(try await followedThreadIDs(client, token: owner, serverId: fixture.serverId).contains(threadId) == false)

            let reply = try await client.send(
                .post,
                headers: threadOpenHeaders(replier, fixture.serverId),
                to: "/api/messages"
            ) { request in
                request.body = .init(string: "{\"channelId\":\"\(threadId)\",\"content\":\"new activity\"}")
            }
            #expect(reply.status == .ok)
            #expect(try await followedThreadIDs(client, token: owner, serverId: fixture.serverId).contains(threadId))
        }
    }
}

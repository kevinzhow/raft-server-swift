import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

/// A thread is readable through its parent channel. The pinned
/// `canUserAccessChannel` recurses from a thread to the parent message's
/// channel (`channelService.ts:4994-5003`), and every channel-scoped read route
/// that uses it must do the same.
private struct ThreadReadFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let parentChannelId: String
    let ownerId: String
    let memberId: String
    let ownerToken: String
    let memberToken: String
}

private func makeThreadReadFixture(_ suffix: String) -> ThreadReadFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001360\(suffix)"
    let memberId = "11111111-1111-4111-8111-000001361\(suffix)"
    let serverId = "33333333-3333-4333-8333-000001360\(suffix)"
    for (id, email) in [
        (ownerId, "thread-read-owner-\(suffix)@slock.test"),
        (memberId, "thread-read-member-\(suffix)@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "thread-read-\(suffix)", name: "Thread Read \(suffix)", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let parentChannelId = accounts.oauth.createChannel(
        serverId: serverId, name: "thread-read-parent-\(suffix)", creatorUserId: ownerId)
    accounts.addPostableChannel(
        serverId: serverId, channelId: parentChannelId, memberId: ownerId,
        kind: "channel", name: "thread-read-parent-\(suffix)")
    accounts.oauth.addChannelHuman(channelId: parentChannelId, userId: ownerId)
    return ThreadReadFixture(
        accounts: accounts,
        serverId: serverId,
        parentChannelId: parentChannelId,
        ownerId: ownerId,
        memberId: memberId,
        ownerToken: accounts.mintAccessTokenForTesting(userId: ownerId),
        memberToken: accounts.mintAccessTokenForTesting(userId: memberId)
    )
}

private func threadReadHeaders(_ token: String, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

private func threadReadJSON(_ response: ClientResponse) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: response.body.data ?? Data()) as? [String: Any])
}

@Test func threadReadStateRoutesResolveAccessThroughTheParentChannel() async throws {
    let f = makeThreadReadFixture("960")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let parent = try await client.send(
                .post, headers: threadReadHeaders(f.ownerToken, f.serverId), to: "/api/messages") { request in
                    request.body = .init(string: #"{"channelId":"\#(f.parentChannelId)","content":"thread parent"}"#)
                }
            #expect(parent.status == .ok)
            let parentBody = try threadReadJSON(parent)
            let parentMessageId = try #require(parentBody["id"] as? String)

            let created = try await client.send(
                .post, headers: threadReadHeaders(f.ownerToken, f.serverId),
                to: "/api/channels/\(f.parentChannelId)/threads") { request in
                    request.body = .init(string: #"{"parentMessageId":"\#(parentMessageId)","content":"first thread reply"}"#)
                }
            #expect(created.status == .ok)
            let createdBody = try threadReadJSON(created)
            let threadId = try #require(createdBody["threadChannelId"] as? String)

            // The viewer can read the thread but does not participate in it.
            let detail = try await client.get(
                URI(string: "/api/channels/\(threadId)"), headers: threadReadHeaders(f.memberToken, f.serverId))
            #expect(detail.status == .ok)

            let readAll = try await client.send(
                .post, headers: threadReadHeaders(f.memberToken, f.serverId),
                to: "/api/channels/\(threadId)/read-all") { request in
                    request.body = .init(string: "{}")
                }
            #expect(readAll.status == .ok)
            let readAllBody = try threadReadJSON(readAll)
            #expect((readAllBody["seq"] as? Int ?? 0) > 0)

            let read = try await client.send(
                .post, headers: threadReadHeaders(f.memberToken, f.serverId),
                to: "/api/channels/\(threadId)/read") { request in
                    request.body = .init(string: #"{"seq":\#(readAllBody["seq"] as? Int ?? 1)}"#)
                }
            #expect(read.status == .ok)

            let unread = try await client.send(
                .post, headers: threadReadHeaders(f.memberToken, f.serverId),
                to: "/api/channels/\(threadId)/unread") { request in
                    request.body = .init(string: "{}")
                }
            #expect(unread.status == .ok)

            let outsider = try await client.send(
                .post, headers: threadReadHeaders(f.memberToken, f.serverId),
                to: "/api/channels/99999999-9999-4999-8999-999999999999/read-all") { request in
                    request.body = .init(string: "{}")
                }
            #expect(outsider.status == .notFound)
        }
    }
}

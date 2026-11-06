import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private final class FollowerEventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(room: String, event: String, payload: String?)] = []

    func append(room: String, event: String, payload: String?) {
        lock.lock()
        storage.append((room, event, payload))
        lock.unlock()
    }

    func eventCount(_ name: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.filter { $0.event == name }.count
    }
}

private struct FollowerManagementFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let ownerEmail: String
    let authorId: String
    let authorEmail: String
    let followerEmail: String
    let threadId: String
    let agentId: String
}

private func makeFollowerManagementFixture() -> FollowerManagementFixture {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000000998001"
    let ownerId = "11111111-1111-4111-8111-000000998001"
    let authorId = "11111111-1111-4111-8111-000000998002"
    let followerId = "11111111-1111-4111-8111-000000998003"
    let ownerEmail = "follower-mgmt-owner@slock.test"
    let authorEmail = "follower-mgmt-author@slock.test"
    let followerEmail = "follower-mgmt-follower@slock.test"
    for (id, email) in [(ownerId, ownerEmail), (authorId, authorEmail), (followerId, followerEmail)] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "follower-mgmt", name: "Follower Management", ownerId: ownerId)
    for id in [authorId, followerId] {
        accounts.oauth.addMember(serverId: serverId, userId: id, role: "member")
    }
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "follower-mgmt", creatorUserId: ownerId)
    for id in [ownerId, authorId, followerId] {
        accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: id, name: "follower-mgmt")
        accounts.oauth.addChannelHuman(channelId: channel, userId: id)
    }
    let parent = accounts.addChannelMessageForTesting(channelId: channel, content: "thread parent", senderId: authorId)
    let thread = accounts.oauth.createThreadChannel(parentChannelId: channel, parentMessageId: parent)
    accounts.addPostableChannel(
        serverId: serverId,
        channelId: thread,
        memberId: ownerId,
        kind: "thread",
        parentChannelId: channel,
        parentMessageId: parent,
        name: "thread"
    )
    for id in [authorId, followerId] {
        accounts.addPostableChannel(
            serverId: serverId,
            channelId: thread,
            memberId: id,
            kind: "thread",
            parentChannelId: channel,
            parentMessageId: parent,
            name: "thread"
        )
    }
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "follower-mgmt-agent", runtime: "codex")
    accounts.oauth.addChannelAgent(channelId: thread, agentId: agent)
    accounts.addChannelAgent(channelId: thread, agentId: agent)
    return FollowerManagementFixture(
        accounts: accounts,
        serverId: serverId,
        ownerId: ownerId,
        ownerEmail: ownerEmail,
        authorId: authorId,
        authorEmail: authorEmail,
        followerEmail: followerEmail,
        threadId: thread,
        agentId: agent
    )
}

private func followerMgmtLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
}

private func followerMgmtHeaders(_ token: String, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

private func followerMgmtObject(_ response: ClientResponse) throws -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

private func followerMgmtRoster(_ client: any Client, token: String, fixture: FollowerManagementFixture) async throws -> [String: Any] {
    let response = try await client.get(
        URI(string: "/api/channels/threads/followers?threadChannelIds=\(fixture.threadId)"),
        headers: followerMgmtHeaders(token, fixture.serverId)
    )
    #expect(response.status == .ok)
    let threads = try followerMgmtObject(response)["threads"] as? [[String: Any]] ?? []
    return try #require(threads.first)
}

@Test func threadFollowerRemovalIsAuthorizedIdempotentAndReversible() async throws {
    let fixture = makeFollowerManagementFixture()
    let events = FollowerEventCollector()
    fixture.accounts.realtimeEmitter = { room, event, payload in
        events.append(room: room, event: event, payload: payload)
    }
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let owner = try await followerMgmtLogin(client, email: fixture.ownerEmail)
            let author = try await followerMgmtLogin(client, email: fixture.authorEmail)
            let follower = try await followerMgmtLogin(client, email: fixture.followerEmail)

            let followerRoster = try await followerMgmtRoster(client, token: follower, fixture: fixture)
            #expect(followerRoster["canManage"] as? Bool == false)
            #expect((followerRoster["agents"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String } == [fixture.agentId])

            let denied = try await client.send(
                .delete,
                headers: followerMgmtHeaders(follower, fixture.serverId),
                to: URI(string: "/api/channels/threads/\(fixture.threadId)/followers/agents/\(fixture.agentId)")
            )
            #expect(denied.status == .forbidden)

            let removePath = "/api/channels/threads/\(fixture.threadId)/followers/agents/\(fixture.agentId)"
            let first = try await client.send(.delete, headers: followerMgmtHeaders(author, fixture.serverId), to: URI(string: removePath))
            #expect(first.status == .ok)
            let firstBody = try followerMgmtObject(first)
            #expect(firstBody["removed"] as? Bool == true)
            let firstToken = try #require(firstBody["undoToken"] as? String)
            let afterFirst = try await followerMgmtRoster(client, token: owner, fixture: fixture)
            #expect(afterFirst["canManage"] as? Bool == true)
            #expect((afterFirst["agents"] as? [[String: Any]] ?? []).isEmpty)

            let retry = try await client.send(.delete, headers: followerMgmtHeaders(author, fixture.serverId), to: URI(string: removePath))
            #expect(retry.status == .ok)
            #expect(try followerMgmtObject(retry)["undoToken"] as? String == firstToken)
            #expect(events.eventCount("thread:followers-updated") == 1)

            let restorePath = "\(removePath)/restore"
            let restored = try await client.send(.post, headers: followerMgmtHeaders(owner, fixture.serverId), to: URI(string: restorePath)) { request in
                request.body = .init(string: "{\"undoToken\":\"\(firstToken)\"}")
            }
            #expect(restored.status == .ok)
            #expect(try followerMgmtObject(restored) as NSDictionary == ["ok": true, "restored": true] as NSDictionary)
            let afterRestore = try await followerMgmtRoster(client, token: owner, fixture: fixture)
            #expect((afterRestore["agents"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String } == [fixture.agentId])

            let second = try await client.send(.delete, headers: followerMgmtHeaders(owner, fixture.serverId), to: URI(string: removePath))
            let secondToken = try #require(try followerMgmtObject(second)["undoToken"] as? String)
            #expect(secondToken != firstToken)

            let stale = try await client.send(.post, headers: followerMgmtHeaders(owner, fixture.serverId), to: URI(string: restorePath)) { request in
                request.body = .init(string: "{\"undoToken\":\"\(firstToken)\"}")
            }
            #expect(stale.status == .ok)
            #expect(try followerMgmtObject(stale) as NSDictionary == ["ok": true, "restored": false] as NSDictionary)
            let afterStale = try await followerMgmtRoster(client, token: owner, fixture: fixture)
            #expect((afterStale["agents"] as? [[String: Any]] ?? []).isEmpty)

            let secondRestore = try await client.send(.post, headers: followerMgmtHeaders(owner, fixture.serverId), to: URI(string: restorePath)) { request in
                request.body = .init(string: "{\"undoToken\":\"\(secondToken)\"}")
            }
            #expect(try followerMgmtObject(secondRestore) as NSDictionary == ["ok": true, "restored": true] as NSDictionary)
        }
    }
}

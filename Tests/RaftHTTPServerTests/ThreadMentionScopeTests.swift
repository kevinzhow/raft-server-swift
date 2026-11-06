import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct MentionScopeFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let ownerEmail: String
    let outsiderId: String
    let outsiderEmail: String
    let outsiderAgent: String
}

private func makeMentionScopeFixture(suffix: String) -> MentionScopeFixture {
    let accounts = EmailLoginDirectory()
    let serverId = String(format: "33333333-3333-4333-8333-%012d", 995_000 + (Int(suffix) ?? 0))
    let ownerId = String(format: "11111111-1111-4111-8111-%012d", 995_000 + (Int(suffix) ?? 0))
    let outsiderId = String(format: "11111111-1111-4111-8111-%012d", 996_000 + (Int(suffix) ?? 0))
    let ownerEmail = "mention-scope-owner-\(suffix)@slock.test"
    let outsiderEmail = "mention-scope-outsider-\(suffix)@slock.test"
    for (id, email) in [(ownerId, ownerEmail), (outsiderId, outsiderEmail)] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "mention-scope-\(suffix)", name: "Mention Scope", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: outsiderId, role: "member")
    let outsiderAgent = accounts.oauth.createAgent(serverId: serverId, name: "mention-scope-agent-\(suffix)", runtime: "codex")
    return MentionScopeFixture(
        accounts: accounts,
        serverId: serverId,
        ownerId: ownerId,
        ownerEmail: ownerEmail,
        outsiderId: outsiderId,
        outsiderEmail: outsiderEmail,
        outsiderAgent: outsiderAgent
    )
}

private func mentionScopeLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
}

private func mentionScopeHeaders(_ token: String, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

@Test func dmThreadMentionsCannotPullOutsidersIntoThePrivateScope() async throws {
    let fixture = makeMentionScopeFixture(suffix: "1401")
    let dmAgent = fixture.accounts.oauth.createAgent(serverId: fixture.serverId, name: "dm-mention-agent-1401", runtime: "codex")
    let dm = fixture.accounts.oauth.createDirectChannel(serverId: fixture.serverId, firstUserId: fixture.ownerId, secondUserId: dmAgent)
    fixture.accounts.addDirectMessage(serverId: fixture.serverId, channelId: dm, participantIds: [fixture.ownerId, dmAgent], agentId: dmAgent)
    let parent = fixture.accounts.addChannelMessageForTesting(channelId: dm, content: "private hi", senderId: fixture.ownerId)
    let thread = fixture.accounts.oauth.createThreadChannel(parentChannelId: dm, parentMessageId: parent)
    fixture.accounts.addPostableChannel(
        serverId: fixture.serverId,
        channelId: thread,
        memberId: fixture.ownerId,
        kind: "thread",
        parentChannelId: dm,
        parentMessageId: parent,
        name: "thread"
    )
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let owner = try await mentionScopeLogin(client, email: fixture.ownerEmail)
            let response = try await client.send(.post, headers: mentionScopeHeaders(owner, fixture.serverId), to: "/api/messages") { request in
                request.body = .init(string: "{\"channelId\":\"\(thread)\",\"content\":\"hi @mention-scope-outsider-1401 @mention-scope-agent-1401\",\"mentions\":[{\"type\":\"user\",\"id\":\"\(fixture.outsiderId)\",\"name\":\"mention-scope-outsider-1401\"},{\"type\":\"agent\",\"id\":\"\(fixture.outsiderAgent)\",\"name\":\"mention-scope-agent-1401\"}]}")
            }
            #expect(response.status == .ok)
            let followers = fixture.accounts.threadFollowerIdsForTesting(threadChannelId: thread)
            #expect(!followers.contains(fixture.outsiderId))
            #expect(!followers.contains(fixture.outsiderAgent))
            #expect(followers.contains(fixture.ownerId))
        }
    }
}

@Test func privateThreadMentionsCannotPullInNonParentMembers() async throws {
    let fixture = makeMentionScopeFixture(suffix: "1402")
    let channel = fixture.accounts.oauth.createChannel(serverId: fixture.serverId, name: "private-thread-parent-1402", creatorUserId: fixture.ownerId, type: "private")
    fixture.accounts.addPostableChannel(serverId: fixture.serverId, channelId: channel, memberId: fixture.ownerId, kind: "private", name: "private-thread-parent-1402")
    fixture.accounts.oauth.addChannelHuman(channelId: channel, userId: fixture.ownerId)
    let parent = fixture.accounts.addChannelMessageForTesting(channelId: channel, content: "private parent", senderId: fixture.ownerId)
    let thread = fixture.accounts.oauth.createThreadChannel(parentChannelId: channel, parentMessageId: parent)
    fixture.accounts.addPostableChannel(
        serverId: fixture.serverId,
        channelId: thread,
        memberId: fixture.ownerId,
        kind: "thread",
        parentChannelId: channel,
        parentMessageId: parent,
        name: "thread"
    )
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let owner = try await mentionScopeLogin(client, email: fixture.ownerEmail)
            let response = try await client.send(.post, headers: mentionScopeHeaders(owner, fixture.serverId), to: "/api/messages") { request in
                request.body = .init(string: "{\"channelId\":\"\(thread)\",\"content\":\"hi @mention-scope-outsider-1402 @mention-scope-agent-1402\",\"mentions\":[{\"type\":\"user\",\"id\":\"\(fixture.outsiderId)\",\"name\":\"mention-scope-outsider-1402\"},{\"type\":\"agent\",\"id\":\"\(fixture.outsiderAgent)\",\"name\":\"mention-scope-agent-1402\"}]}")
            }
            #expect(response.status == .ok)
            let followers = fixture.accounts.threadFollowerIdsForTesting(threadChannelId: thread)
            #expect(!followers.contains(fixture.outsiderId))
            #expect(!followers.contains(fixture.outsiderAgent))
        }
    }
}

@Test func manualThreadFollowMutationsCloakAPrivateParent() async throws {
    let fixture = makeMentionScopeFixture(suffix: "1403")
    let channel = fixture.accounts.oauth.createChannel(serverId: fixture.serverId, name: "manual-private-1403", creatorUserId: fixture.ownerId, type: "private")
    fixture.accounts.addPostableChannel(serverId: fixture.serverId, channelId: channel, memberId: fixture.ownerId, kind: "private", name: "manual-private-1403")
    fixture.accounts.oauth.addChannelHuman(channelId: channel, userId: fixture.ownerId)
    let parent = fixture.accounts.addChannelMessageForTesting(channelId: channel, content: "private parent", senderId: fixture.ownerId)
    let thread = fixture.accounts.oauth.createThreadChannel(parentChannelId: channel, parentMessageId: parent)
    fixture.accounts.addPostableChannel(
        serverId: fixture.serverId,
        channelId: thread,
        memberId: fixture.ownerId,
        kind: "thread",
        parentChannelId: channel,
        parentMessageId: parent,
        name: "thread"
    )
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let outsider = try await mentionScopeLogin(client, email: fixture.outsiderEmail)
            let headers = mentionScopeHeaders(outsider, fixture.serverId)

            let follow = try await client.send(.post, headers: headers, to: "/api/channels/threads/follow") { request in
                request.body = .init(string: "{\"parentMessageId\":\"\(parent)\"}")
            }
            #expect(follow.status == .notFound)

            for path in ["unfollow", "done", "undone"] {
                let response = try await client.send(.post, headers: headers, to: URI(string: "/api/channels/threads/\(path)")) { request in
                    request.body = .init(string: "{\"threadChannelId\":\"\(thread)\"}")
                }
                #expect(response.status == .notFound)
            }
            #expect(fixture.accounts.threadFollowerIdsForTesting(threadChannelId: thread).isEmpty)
        }
    }
}

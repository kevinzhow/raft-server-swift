import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

/// The thread routes project their service result through `respond`, so these
/// tests lock the exact published bytes and headers of the migrated surface.
/// Timestamps that the fixture controls are fixed; the one dynamic field
/// (`unfollowedAt`, written from the request clock) is asserted by its exact
/// surrounding bytes, and its format is locked by `ThreadsServiceTests`.
@Test func threadRoutesPublishTheExactLegacyBytes() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000000995001"
    let ownerId = "11111111-1111-4111-8111-000000995001"
    let memberId = "11111111-1111-4111-8111-000000995002"
    let ownerEmail = "route-owner@slock.test"
    let memberEmail = "route-member@slock.test"
    for (id, email) in [(ownerId, ownerEmail), (memberId, memberEmail)] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "route-bytes", name: "Route Bytes", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "route-bytes", creatorUserId: ownerId)
    for id in [ownerId, memberId] {
        accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: id, name: "route-bytes")
        accounts.oauth.addChannelHuman(channelId: channel, userId: id)
    }
    let parentOne = accounts.addChannelMessageForTesting(
        channelId: channel,
        content: "parent one",
        senderId: ownerId,
        createdAt: Date(timeIntervalSince1970: 1_767_225_600.123)
    )
    let parentTwo = accounts.addChannelMessageForTesting(
        channelId: channel,
        content: "parent two",
        senderId: ownerId,
        createdAt: Date(timeIntervalSince1970: 1_767_225_601.123)
    )

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func login(_ email: String) async throws -> String {
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                    request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
                }
                return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            }
            func headers(_ token: String) -> HTTPFields {
                var fields = HTTPFields()
                fields[.authorization] = "Bearer \(token)"
                fields[.contentType] = "application/json"
                fields[HTTPField.Name("X-Server-Id")!] = serverId
                return fields
            }
            func object(_ response: ClientResponse) -> [String: Any] {
                (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            }
            let owner = try await login(ownerEmail)
            let member = try await login(memberEmail)
            let ownerHeaders = headers(owner)
            let memberHeaders = headers(member)

            func createThread(parentMessageId: String) async throws -> String {
                let response = try await client.send(
                    .post,
                    headers: ownerHeaders,
                    to: "/api/channels/\(channel)/threads"
                ) { request in
                    request.body = .init(string: "{\"parentMessageId\":\"\(parentMessageId)\"}")
                }
                #expect(response.status == .ok)
                return object(response)["threadChannelId"] as? String ?? ""
            }
            let threadOne = try await createThread(parentMessageId: parentOne)
            let threadTwo = try await createThread(parentMessageId: parentTwo)
            let replyOne = accounts.addChannelMessageForTesting(
                channelId: threadOne,
                content: "reply one",
                senderId: memberId,
                createdAt: Date(timeIntervalSince1970: 1_767_225_605.5)
            )
            let replyTwo = accounts.addChannelMessageForTesting(
                channelId: threadTwo,
                content: "reply two",
                senderId: memberId,
                createdAt: Date(timeIntervalSince1970: 1_767_225_606.5)
            )
            let agentId = accounts.oauth.createAgent(serverId: serverId, name: "Route Agent", runtime: "codex")
            accounts.oauth.addChannelAgent(channelId: threadOne, agentId: agentId)

            // MARK: Roster

            let roster = try await client.get(
                URI(string: "/api/channels/threads/followers?threadChannelIds=\(threadOne),\(threadTwo)"),
                headers: ownerHeaders
            )
            let rosterBody = "{\"threads\":[{\"threadChannelId\":\"\(threadOne)\",\"canManage\":true,\"agents\":[{\"id\":\"\(agentId)\",\"name\":\"Route Agent\"}]},{\"threadChannelId\":\"\(threadTwo)\",\"canManage\":true,\"agents\":[]}]}"
            #expect(roster.status == .ok)
            #expect(roster.body.string == rosterBody)
            #expect(roster.headers[.contentType] == "application/json; charset=utf-8")
            #expect(roster.headers[HTTPField.Name("X-Robots-Tag")!] == "noindex, nofollow")
            #expect(roster.headers[.contentLength] == String(rosterBody.utf8.count))
            #expect(roster.headers[HTTPField.Name("Cache-Control")!] == "private, no-store")

            // MARK: Follow and unfollow

            let follow = try await client.send(.post, headers: ownerHeaders, to: "/api/channels/threads/follow") { request in
                request.body = .init(string: "{\"threadChannelId\":\"\(threadOne)\"}")
            }
            #expect(follow.status == .ok)
            #expect(follow.body.string == "{\"ok\":true,\"following\":true}")

            let unknown = try await client.send(.post, headers: ownerHeaders, to: "/api/channels/threads/follow") { request in
                request.body = .init(string: "{\"threadChannelId\":\"99999999-9999-4999-8999-999999999999\"}")
            }
            #expect(unknown.status == .notFound)
            #expect(unknown.body.string == "{\"error\":\"Thread not found\"}")

            let malformed = try await client.send(.post, headers: ownerHeaders, to: "/api/channels/threads/follow") { request in
                request.body = .init(string: "not json")
            }
            #expect(malformed.status == .notFound)
            #expect(malformed.body.string == "{\"error\":\"Thread not found\"}")

            // MARK: Followed page

            #expect(try await client.send(.post, headers: ownerHeaders, to: "/api/channels/threads/follow") { request in
                request.body = .init(string: "{\"parentMessageId\":\"\(parentTwo)\"}")
            }.status == .ok)

            let followed = try await client.get(URI(string: "/api/channels/threads/followed?limit=1"), headers: ownerHeaders)
            let followedBody = "{\"threads\":[{\"threadChannelId\":\"\(threadTwo)\",\"parentChannelId\":\"\(channel)\",\"parentMessageCreatedAt\":\"2026-01-01T00:00:01.123Z\",\"unreadCount\":1,\"firstUnreadMessageId\":\"\(replyTwo)\",\"hasMention\":false,\"taskId\":null,\"taskClaimedByType\":null,\"taskClaimedById\":null,\"taskClaimedByName\":null}],\"next\":\"v1:1\"}"
            #expect(followed.status == .ok)
            #expect(followed.body.string == followedBody)

            // MARK: Thread info

            let info = try await client.get(
                URI(string: "/api/channels/\(channel)/threads/\(parentOne)"),
                headers: ownerHeaders
            )
            let infoBody = "{\"threadChannelId\":\"\(threadOne)\",\"replyCount\":1,\"lastReplyAt\":\"2026-01-01T00:00:05Z\",\"participantIds\":[\"\(ownerId)\",\"\(memberId)\"]}"
            #expect(info.status == .ok)
            #expect(info.body.string == infoBody)

            // MARK: Channel summaries

            let summaries = try await client.get(URI(string: "/api/channels/\(channel)/threads"), headers: ownerHeaders)
            let latestReplyOne = "{\"preview\":\"reply one\",\"senderType\":\"user\",\"senderId\":\"\(memberId)\",\"senderName\":\"route-member\",\"senderDisplayName\":\"route-member\"}"
            let latestReplyTwo = "{\"preview\":\"reply two\",\"senderType\":\"user\",\"senderId\":\"\(memberId)\",\"senderName\":\"route-member\",\"senderDisplayName\":\"route-member\"}"
            let summariesBody = "{\"\(parentOne)\":{\"threadChannelId\":\"\(threadOne)\",\"replyCount\":1,\"latestReplies\":[\(latestReplyOne)],\"unreadCount\":1,\"firstUnreadMessageId\":\"\(replyOne)\",\"participantIds\":[\"\(ownerId)\",\"\(memberId)\"],\"followed\":true},\"\(parentTwo)\":{\"threadChannelId\":\"\(threadTwo)\",\"replyCount\":1,\"latestReplies\":[\(latestReplyTwo)],\"unreadCount\":1,\"firstUnreadMessageId\":\"\(replyTwo)\",\"participantIds\":[\"\(ownerId)\",\"\(memberId)\"],\"followed\":true}}"
            #expect(summaries.status == .ok)
            #expect(summaries.body.string == summariesBody)

            let missingAuth = try await client.get(URI(string: "/api/channels/\(channel)/threads"))
            #expect(missingAuth.status == .unauthorized)
            #expect(missingAuth.body.string == "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
            #expect(missingAuth.headers[HTTPField.Name("Cache-Control")!] == "private, no-store")
            #expect(missingAuth.headers[.contentLength] == String("{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}".utf8.count))

            // MARK: Unfollowed inbox

            let unfollow = try await client.send(.post, headers: ownerHeaders, to: "/api/channels/threads/unfollow") { request in
                request.body = .init(string: "{\"threadChannelId\":\"\(threadOne)\"}")
            }
            #expect(unfollow.status == .ok)
            #expect(unfollow.body.string == "{\"ok\":true,\"following\":false}")

            let inbox = try await client.get(URI(string: "/api/channels/inbox/unfollowed"), headers: ownerHeaders)
            let inboxBody = try #require(inbox.body.string)
            #expect(inbox.status == .ok)
            #expect(inbox.headers[HTTPField.Name("Cache-Control")!] == "private, no-store")
            #expect(inboxBody.hasPrefix("{\"items\":[{\"kind\":\"thread\",\"threadChannelId\":\"\(threadOne)\",\"latestActivityMessageId\":\"\(parentOne)\",\"replyCount\":0,\"unreadCount\":0,\"hasMention\":false,\"isFollowing\":false,\"unfollowedAt\":\""))
            #expect(inboxBody.hasSuffix("\"}],\"hasMore\":false,\"totalCount\":null}"))
            #expect(inbox.headers[.contentLength] == String(inboxBody.utf8.count))
        }
    }
}

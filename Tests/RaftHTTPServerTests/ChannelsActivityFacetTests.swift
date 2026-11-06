import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

// Coverage for the `channels.api` groups the existing suite does not exercise:
// the Activity All/Done/Restore facets with unfollow and completion kept
// independent, unfollow suppression until a direct mention reactivates, the
// canonical Done frontier rules, >100-row mixed-follow pagination, the V1
// read/done response shapes, and the resume-all-agents skipped-start report.

private struct ChannelFacetFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let ownerEmail: String
    let ownerName: String
    let memberId: String
    let memberEmail: String
    let channelId: String
    let parentMessageId: String
    let threadId: String
}

private func makeChannelFacetFixture(_ suffix: Int) -> ChannelFacetFixture {
    let accounts = EmailLoginDirectory()
    let serverId = String(format: "33333333-3333-4333-8333-%012d", 1_080_000 + suffix)
    let ownerId = String(format: "11111111-1111-4111-8111-%012d", 1_080_000 + suffix)
    let memberId = String(format: "11111111-1111-4111-8111-%012d", 1_080_500 + suffix)
    let ownerName = "facetowner\(suffix)"
    let memberName = "facetmember\(suffix)"
    let ownerEmail = "\(ownerName)@slock.test"
    let memberEmail = "\(memberName)@slock.test"
    accounts.addAccount(id: ownerId, email: ownerEmail, password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: memberEmail, password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "facet-\(suffix)", name: "Facet \(suffix)", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "facet-room-\(suffix)", creatorUserId: ownerId)
    for id in [ownerId, memberId] {
        accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: id, name: "facet-room-\(suffix)")
        accounts.oauth.addChannelHuman(channelId: channel, userId: id)
    }
    let parent = accounts.addChannelMessageForTesting(channelId: channel, content: "facet parent", senderId: ownerId)
    let thread = accounts.oauth.createThreadChannel(parentChannelId: channel, parentMessageId: parent)
    for id in [ownerId, memberId] {
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
    return ChannelFacetFixture(
        accounts: accounts,
        serverId: serverId,
        ownerId: ownerId,
        ownerEmail: ownerEmail,
        ownerName: ownerName,
        memberId: memberId,
        memberEmail: memberEmail,
        channelId: channel,
        parentMessageId: parent,
        threadId: thread
    )
}

/// Seeds one thread reply plus the owner's inbox fact for it, mirroring the
/// durable activity row the real send pipeline leaves behind.
@discardableResult
private func seedThreadActivity(
    _ fixture: ChannelFacetFixture,
    content: String,
    from senderId: String? = nil,
    at date: Date = Date()
) -> String {
    let messageId = fixture.accounts.addHumanMessageForTesting(
        channelId: fixture.threadId,
        senderId: senderId ?? fixture.memberId,
        content: content
    )
    fixture.accounts.setMessageCreatedAtForTesting(messageId: messageId, at: date)
    fixture.accounts.addInboxFactForTesting(
        receiverId: fixture.ownerId,
        serverId: fixture.serverId,
        channelId: fixture.threadId,
        messageId: messageId
    )
    return messageId
}

private func facetLogin(_ client: any TestClient, _ email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
}

private func facetHeaders(_ token: String, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

private func facetObject(_ response: ClientResponse) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

private func facetPost(
    _ client: any TestClient,
    _ headers: HTTPFields,
    _ path: String,
    _ body: String
) async throws -> ClientResponse {
    try await client.send(.post, headers: headers, to: URI(string: path)) { request in
        request.body = .init(string: body)
    }
}

private func facetGet(
    _ client: any TestClient,
    _ headers: HTTPFields,
    _ path: String
) async throws -> ClientResponse {
    try await client.get(URI(string: path), headers: headers)
}

private func facetInboxBody(
    _ client: any TestClient,
    _ headers: HTTPFields,
    _ query: String = ""
) async throws -> [String: Any] {
    let response = try await facetGet(client, headers, "/api/channels/inbox\(query)")
    #expect(response.status == .ok)
    return facetObject(response)
}

private func facetInboxItems(
    _ client: any TestClient,
    _ headers: HTTPFields,
    _ query: String = ""
) async throws -> [[String: Any]] {
    try await facetInboxBody(client, headers, query)["items"] as? [[String: Any]] ?? []
}

private func facetThreadRow(_ items: [[String: Any]], _ threadId: String) -> [String: Any]? {
    items.first { $0["kind"] as? String == "thread" && $0["threadChannelId"] as? String == threadId }
}

private func withFacetApp(
    _ fixture: ChannelFacetFixture,
    _ body: (any TestClient, String, HTTPFields, HTTPFields) async throws -> Void
) async throws {
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let ownerToken = try await facetLogin(client, fixture.ownerEmail)
            let memberToken = try await facetLogin(client, fixture.memberEmail)
            try await body(
                client,
                ownerToken,
                facetHeaders(ownerToken, fixture.serverId),
                facetHeaders(memberToken, fixture.serverId)
            )
        }
    }
}

// MARK: - Unfollow suppression and mention reactivation (upstream 1680)

@Test func unfollowBlocksOrdinaryRepliesUntilDirectMention() async throws {
    let fixture = makeChannelFacetFixture(5101)
    fixture.accounts.addThreadFollowForTesting(
        serverId: fixture.serverId,
        userId: fixture.ownerId,
        threadChannelId: fixture.threadId,
        parentMessageId: fixture.parentMessageId
    )
    seedThreadActivity(fixture, content: "activity before unfollow")

    try await withFacetApp(fixture) { client, _, ownerHeaders, memberHeaders in
        let unfollow = try await facetPost(
            client,
            ownerHeaders,
            "/api/channels/threads/unfollow",
            "{\"threadChannelId\":\"\(fixture.threadId)\"}"
        )
        #expect(unfollow.status == .ok)
        #expect(fixture.accounts.threadUnfollowSuppressedForTesting(
            serverId: fixture.serverId,
            userId: fixture.ownerId,
            threadChannelId: fixture.threadId
        ))

        let ordinaryReply = try await facetPost(
            client,
            memberHeaders,
            "/api/messages",
            "{\"channelId\":\"\(fixture.threadId)\",\"content\":\"reply after owner unfollow\"}"
        )
        #expect(ordinaryReply.status == .ok)

        let all = try await facetInboxItems(client, ownerHeaders)
        let attentionless = try #require(facetThreadRow(all, fixture.threadId))
        #expect(attentionless["isFollowing"] as? Bool == false)
        #expect(attentionless["unreadCount"] as? Int == 0)
        #expect(attentionless["hasMention"] as? Bool == false)
        #expect(attentionless["firstUnreadMessageId"] is NSNull)
        #expect(try await facetInboxItems(client, ownerHeaders, "?filter=unread").isEmpty)
        #expect(try await facetInboxItems(client, ownerHeaders, "?filter=mentions").isEmpty)

        let mentionReply = try await facetPost(
            client,
            memberHeaders,
            "/api/messages",
            "{\"channelId\":\"\(fixture.threadId)\",\"content\":\"ping @\(fixture.ownerName) after unfollow\"}"
        )
        #expect(mentionReply.status == .ok)
        let mentionBody = facetObject(mentionReply)
        let mentionMessageId = try #require(mentionBody["id"] as? String)
        let mentionState = try #require(fixture.accounts.mentionNotificationStateForTesting(
            messageId: mentionMessageId,
            targetId: fixture.ownerId
        ))
        #expect(mentionState.notifiableAtSend)
        #expect(!fixture.accounts.threadUnfollowSuppressedForTesting(
            serverId: fixture.serverId,
            userId: fixture.ownerId,
            threadChannelId: fixture.threadId
        ))
        #expect(fixture.accounts.threadFollowerIdsForTesting(threadChannelId: fixture.threadId).contains(fixture.ownerId))

        let followedResponse = try await facetGet(client, ownerHeaders, "/api/channels/threads/followed")
        let followedThreads = facetObject(followedResponse)["threads"] as? [[String: Any]] ?? []
        #expect(followedThreads.contains { $0["threadChannelId"] as? String == fixture.threadId })

        let reactivated = try #require(facetThreadRow(try await facetInboxItems(client, ownerHeaders), fixture.threadId))
        #expect(reactivated["isFollowing"] as? Bool == true)
        #expect(reactivated["hasMention"] as? Bool == true)
        #expect((reactivated["unreadCount"] as? Int ?? 0) > 0)

        let unread = try await facetInboxItems(client, ownerHeaders, "?filter=unread")
        #expect(facetThreadRow(unread, fixture.threadId) != nil)
        let mentions = try await facetInboxItems(client, ownerHeaders, "?filter=mentions")
        let mentionRow = try #require(facetThreadRow(mentions, fixture.threadId))
        #expect(mentionRow["hasMention"] as? Bool == true)
        #expect((mentionRow["unreadCount"] as? Int ?? 0) > 0)

        let laterReply = try await facetPost(
            client,
            memberHeaders,
            "/api/messages",
            "{\"channelId\":\"\(fixture.threadId)\",\"content\":\"ordinary reply after mention reactivation\"}"
        )
        #expect(laterReply.status == .ok)
        let after = try await facetInboxItems(client, ownerHeaders, "?filter=unread")
        #expect(facetThreadRow(after, fixture.threadId) != nil)
    }
}

// MARK: - Activity All / Done / Restore facets (upstream 1813, 1896, 1947)

@Test func activityAllDoneRestoreKeepUnfollowAndCompletionIndependent() async throws {
    let fixture = makeChannelFacetFixture(5102)
    fixture.accounts.addThreadFollowForTesting(
        serverId: fixture.serverId,
        userId: fixture.ownerId,
        threadChannelId: fixture.threadId,
        parentMessageId: fixture.parentMessageId
    )
    seedThreadActivity(fixture, content: "activity before unfollow")

    try await withFacetApp(fixture) { client, _, ownerHeaders, memberHeaders in
        #expect(try await facetPost(
            client,
            ownerHeaders,
            "/api/channels/threads/unfollow",
            "{\"threadChannelId\":\"\(fixture.threadId)\"}"
        ).status == .ok)
        #expect(try await facetPost(
            client,
            memberHeaders,
            "/api/messages",
            "{\"channelId\":\"\(fixture.threadId)\",\"content\":\"ordinary activity advances an unfollowed All row\"}"
        ).status == .ok)

        let unfollowed = try #require(facetThreadRow(try await facetInboxItems(client, ownerHeaders), fixture.threadId))
        #expect(unfollowed["isFollowing"] as? Bool == false)
        #expect(unfollowed["unreadCount"] as? Int == 0)
        #expect(unfollowed["hasMention"] as? Bool == false)

        // Done works on an unfollowed row and keeps the suppression.
        let done = try await facetPost(
            client,
            ownerHeaders,
            "/api/channels/threads/done",
            "{\"threadChannelId\":\"\(fixture.threadId)\",\"throughActivitySeq\":\"1\",\"frontierSpace\":\"storage\"}"
        )
        #expect(done.status == .ok)
        #expect(fixture.accounts.threadUnfollowSuppressedForTesting(
            serverId: fixture.serverId,
            userId: fixture.ownerId,
            threadChannelId: fixture.threadId
        ))
        #expect(fixture.accounts.inboxDoneFrontierForTesting(userId: fixture.ownerId, scopeId: fixture.threadId) == 1)
        #expect(facetThreadRow(try await facetInboxItems(client, ownerHeaders), fixture.threadId) == nil)

        let doneList = try await facetGet(client, ownerHeaders, "/api/channels/inbox/done?limit=30")
        let doneItems = facetObject(doneList)["items"] as? [[String: Any]] ?? []
        let doneRow = try #require(doneItems.first { $0["threadChannelId"] as? String == fixture.threadId })
        #expect(doneRow["isFollowing"] as? Bool == false)

        // Restore returns the row to All without silently re-following.
        #expect(try await facetPost(
            client,
            ownerHeaders,
            "/api/channels/threads/undone",
            "{\"threadChannelId\":\"\(fixture.threadId)\"}"
        ).status == .ok)
        let restored = try #require(facetThreadRow(try await facetInboxItems(client, ownerHeaders), fixture.threadId))
        #expect(restored["isFollowing"] as? Bool == false)
        #expect(restored["unreadCount"] as? Int == 0)
        #expect(fixture.accounts.threadUnfollowSuppressedForTesting(
            serverId: fixture.serverId,
            userId: fixture.ownerId,
            threadChannelId: fixture.threadId
        ))
    }
}

@Test func activityDoneRemovesUnfollowedRowThroughOmittedFrontier() async throws {
    let fixture = makeChannelFacetFixture(5103)
    fixture.accounts.addThreadFollowForTesting(
        serverId: fixture.serverId,
        userId: fixture.ownerId,
        threadChannelId: fixture.threadId,
        parentMessageId: fixture.parentMessageId
    )
    let latestMessageId = seedThreadActivity(fixture, content: "activity before unfollow")
    let latestSeq = try #require(fixture.accounts.messageSeqForTesting(messageId: latestMessageId))

    try await withFacetApp(fixture) { client, _, ownerHeaders, memberHeaders in
        #expect(try await facetPost(
            client,
            ownerHeaders,
            "/api/channels/threads/unfollow",
            "{\"threadChannelId\":\"\(fixture.threadId)\"}"
        ).status == .ok)
        let replyResponse = try await facetPost(
            client,
            memberHeaders,
            "/api/messages",
            "{\"channelId\":\"\(fixture.threadId)\",\"content\":\"reply after unfollow\"}"
        )
        #expect(replyResponse.status == .ok)
        let replyMessageId = try #require(facetObject(replyResponse)["id"] as? String)
        let expectedLatestSeq = try #require(fixture.accounts.messageSeqForTesting(messageId: replyMessageId))
        #expect(facetThreadRow(try await facetInboxItems(client, ownerHeaders), fixture.threadId) != nil)

        // The legacy pre-frontier payload: no authoritative Done frontier, so the
        // server snapshots its canonical latest and still persists Done.
        let done = try await facetPost(
            client,
            ownerHeaders,
            "/api/channels/threads/done",
            "{\"threadChannelId\":\"\(fixture.threadId)\"}"
        )
        #expect(done.status == .ok)
        #expect(facetObject(done)["ok"] as? Bool == true)
        #expect(fixture.accounts.inboxDoneFrontierForTesting(userId: fixture.ownerId, scopeId: fixture.threadId) == expectedLatestSeq)
        #expect(facetThreadRow(try await facetInboxItems(client, ownerHeaders), fixture.threadId) == nil)
        #expect(fixture.accounts.threadUnfollowSuppressedForTesting(
            serverId: fixture.serverId,
            userId: fixture.ownerId,
            threadChannelId: fixture.threadId
        ))
    }
}

@Test func doneUnfollowRestorePreserveCompletionIndependently() async throws {
    let fixture = makeChannelFacetFixture(5104)
    fixture.accounts.addThreadFollowForTesting(
        serverId: fixture.serverId,
        userId: fixture.ownerId,
        threadChannelId: fixture.threadId,
        parentMessageId: fixture.parentMessageId
    )
    seedThreadActivity(fixture, content: "activity before done")

    try await withFacetApp(fixture) { client, _, ownerHeaders, _ in
        #expect(try await facetPost(
            client,
            ownerHeaders,
            "/api/channels/threads/done",
            "{\"threadChannelId\":\"\(fixture.threadId)\",\"throughActivitySeq\":\"1\",\"frontierSpace\":\"storage\"}"
        ).status == .ok)
        #expect(try await facetPost(
            client,
            ownerHeaders,
            "/api/channels/threads/unfollow",
            "{\"threadChannelId\":\"\(fixture.threadId)\"}"
        ).status == .ok)

        // Unfollow preserves the existing Done marker, so the row stays out of All.
        #expect(fixture.accounts.threadUnfollowSuppressedForTesting(
            serverId: fixture.serverId,
            userId: fixture.ownerId,
            threadChannelId: fixture.threadId
        ))
        #expect(fixture.accounts.inboxDoneFrontierForTesting(userId: fixture.ownerId, scopeId: fixture.threadId) == 1)
        #expect(facetThreadRow(try await facetInboxItems(client, ownerHeaders), fixture.threadId) == nil)

        let doneList = try await facetGet(client, ownerHeaders, "/api/channels/inbox/done?limit=30")
        let doneItems = facetObject(doneList)["items"] as? [[String: Any]] ?? []
        #expect(doneItems.contains {
            $0["threadChannelId"] as? String == fixture.threadId && ($0["isFollowing"] as? Bool) == false
        })

        #expect(try await facetPost(
            client,
            ownerHeaders,
            "/api/channels/threads/undone",
            "{\"threadChannelId\":\"\(fixture.threadId)\"}"
        ).status == .ok)
        let restored = try #require(facetThreadRow(try await facetInboxItems(client, ownerHeaders), fixture.threadId))
        #expect(restored["isFollowing"] as? Bool == false)
        #expect(restored["unreadCount"] as? Int == 0)

        let afterRestore = try await facetGet(client, ownerHeaders, "/api/channels/inbox/done?limit=30")
        let afterItems = facetObject(afterRestore)["items"] as? [[String: Any]] ?? []
        #expect(!afterItems.contains { $0["threadChannelId"] as? String == fixture.threadId })
    }
}

// MARK: - Activity pagination over 100 mixed-follow rows (upstream 2023)

@Test func activityAllPaginatesMoreThanOneHundredMixedFollowRows() async throws {
    let fixture = makeChannelFacetFixture(5105)
    let rowCount = 115
    let unfollowed: (Int) -> Bool = { $0 % 11 != 10 }
    let base = Date(timeIntervalSince1970: 1_786_320_000) // 2026-08-10T00:00:00Z
    var expected: [(threadId: String, activityAt: Date, isFollowing: Bool)] = []

    for index in 0..<rowCount {
        let parentMessageId = fixture.accounts.addChannelMessageForTesting(
            channelId: fixture.channelId,
            content: "pagination parent \(index)",
            senderId: fixture.ownerId
        )
        let threadId = fixture.accounts.oauth.createThreadChannel(
            parentChannelId: fixture.channelId,
            parentMessageId: parentMessageId
        )
        fixture.accounts.addPostableChannel(
            serverId: fixture.serverId,
            channelId: threadId,
            memberId: fixture.ownerId,
            kind: "thread",
            parentChannelId: fixture.channelId,
            parentMessageId: parentMessageId,
            name: "pagination-thread-\(index)"
        )
        let activityAt = base.addingTimeInterval(Double(index / 2))
        let messageId = fixture.accounts.addHumanMessageForTesting(
            channelId: threadId,
            senderId: fixture.memberId,
            content: "pagination reply \(index)"
        )
        fixture.accounts.setMessageCreatedAtForTesting(messageId: messageId, at: activityAt)
        fixture.accounts.addInboxFactForTesting(
            receiverId: fixture.ownerId,
            serverId: fixture.serverId,
            channelId: threadId,
            messageId: messageId
        )
        if unfollowed(index) {
            fixture.accounts.unfollowThreadForTesting(
                serverId: fixture.serverId,
                userId: fixture.ownerId,
                threadChannelId: threadId,
                parentMessageId: parentMessageId,
                latestMessageId: messageId
            )
        } else {
            fixture.accounts.addThreadFollowForTesting(
                serverId: fixture.serverId,
                userId: fixture.ownerId,
                threadChannelId: threadId,
                parentMessageId: parentMessageId
            )
        }
        expected.append((threadId, activityAt, !unfollowed(index)))
    }
    let generated = Set(expected.map(\.threadId))
    let expectedOrder = expected.sorted { left, right in
        if left.activityAt != right.activityAt { return left.activityAt > right.activityAt }
        return left.threadId > right.threadId
    }.map(\.threadId)

    try await withFacetApp(fixture) { client, _, ownerHeaders, _ in
        let firstBody = try await facetInboxBody(client, ownerHeaders, "?filter=all&limit=100&offset=0")
        let firstItems = firstBody["items"] as? [[String: Any]] ?? []
        #expect(firstItems.count == 100)
        #expect(firstBody["hasMore"] as? Bool == true)
        let secondBody = try await facetInboxBody(client, ownerHeaders, "?filter=all&limit=100&offset=100")
        let secondItems = secondBody["items"] as? [[String: Any]] ?? []
        #expect(secondItems.count == 15)
        #expect(secondBody["hasMore"] as? Bool == false)

        let paged = (firstItems + secondItems).filter {
            ($0["kind"] as? String == "thread") && generated.contains($0["threadChannelId"] as? String ?? "")
        }
        #expect(paged.count == rowCount)
        #expect(Set(paged.compactMap { $0["threadChannelId"] as? String }).count == rowCount)
        #expect(paged.compactMap { $0["threadChannelId"] as? String } == expectedOrder)

        for row in paged {
            let threadId = try #require(row["threadChannelId"] as? String)
            let expectation = try #require(expected.first { $0.threadId == threadId })
            #expect(row["isFollowing"] as? Bool == expectation.isFollowing)
            if !expectation.isFollowing {
                #expect(row["unreadCount"] as? Int == 0)
                #expect(row["hasMention"] as? Bool == false)
                #expect(row["firstUnreadMessageId"] is NSNull)
            }
        }
        #expect(expected.filter { !$0.isFollowing }.count > 100)
    }
}

// MARK: - V1 write shapes and canonical refetch (upstream 2176)

@Test func activityV1WritesExposeDeployedShapesAndCanonicalRefetch() async throws {
    let fixture = makeChannelFacetFixture(5106)
    fixture.accounts.addThreadFollowForTesting(
        serverId: fixture.serverId,
        userId: fixture.ownerId,
        threadChannelId: fixture.threadId,
        parentMessageId: fixture.parentMessageId
    )
    seedThreadActivity(fixture, content: "v1 thread fact")
    let channelActivityId = fixture.accounts.addChannelMessageForTesting(
        channelId: fixture.channelId,
        content: "v1 channel fact",
        senderId: fixture.memberId
    )
    fixture.accounts.addInboxFactForTesting(
        receiverId: fixture.ownerId,
        serverId: fixture.serverId,
        channelId: fixture.channelId,
        messageId: channelActivityId
    )
    let channelSeq = try #require(fixture.accounts.messageSeqForTesting(messageId: channelActivityId))

    try await withFacetApp(fixture) { client, _, ownerHeaders, _ in
        // Both scopes refetch canonically before any read/done write.
        let beforeReadAll = try await facetInboxItems(client, ownerHeaders)
        #expect(beforeReadAll.contains { $0["kind"] as? String == "channel" && $0["channelId"] as? String == fixture.channelId })
        #expect(facetThreadRow(beforeReadAll, fixture.threadId) != nil)

        let inboxReadAll = try await facetPost(client, ownerHeaders, "/api/channels/inbox/read-all", "{}")
        #expect(inboxReadAll.status == .ok)
        let inboxReadAllBody = facetObject(inboxReadAll)
        #expect(Set(inboxReadAllBody.keys) == ["ok", "markedCount", "scopes"])
        #expect(inboxReadAllBody["ok"] as? Bool == true)
        #expect((inboxReadAllBody["markedCount"] as? Int ?? 0) >= 2)
        let scopes = inboxReadAllBody["scopes"] as? [[String: Any]] ?? []
        #expect(scopes.contains { $0["scopeId"] as? String == fixture.channelId })
        #expect(scopes.contains { $0["scopeId"] as? String == fixture.threadId })
        #expect(scopes.allSatisfy { Set($0.keys) == ["maxReadSeq", "readStateVersion", "scopeId"] })

        let channelReadAll = try await facetPost(
            client,
            ownerHeaders,
            "/api/channels/\(fixture.channelId)/read-all",
            "{}"
        )
        #expect(channelReadAll.status == .ok)
        let channelReadAllBody = facetObject(channelReadAll)
        #expect(Set(channelReadAllBody.keys) == ["ok", "readStateVersion", "seq"])
        #expect(channelReadAllBody["ok"] as? Bool == true)
        #expect(channelReadAllBody["seq"] as? Int == channelSeq)

        let inboxDone = try await facetPost(
            client,
            ownerHeaders,
            "/api/channels/inbox/done",
            "{\"channelId\":\"\(fixture.channelId)\"}"
        )
        #expect(inboxDone.status == .ok)
        #expect(facetObject(inboxDone) as NSDictionary == ["ok": true] as NSDictionary)

        let threadDone = try await facetPost(
            client,
            ownerHeaders,
            "/api/channels/threads/done",
            "{\"threadChannelId\":\"\(fixture.threadId)\"}"
        )
        #expect(threadDone.status == .ok)
        #expect(facetObject(threadDone) as NSDictionary == ["ok": true] as NSDictionary)

        let afterDone = try await facetInboxItems(client, ownerHeaders)
        #expect(!afterDone.contains { $0["kind"] as? String == "channel" && $0["channelId"] as? String == fixture.channelId })
        #expect(facetThreadRow(afterDone, fixture.threadId) == nil)

        let followed = try await facetGet(client, ownerHeaders, "/api/channels/threads/followed")
        let followedThreads = facetObject(followed)["threads"] as? [[String: Any]] ?? []
        #expect(!followedThreads.contains { $0["threadChannelId"] as? String == fixture.threadId })

        // Wrong scope kinds are rejected without a suppression row.
        let wrongInboxScope = try await facetPost(
            client,
            ownerHeaders,
            "/api/channels/inbox/done",
            "{\"channelId\":\"\(fixture.threadId)\"}"
        )
        #expect(wrongInboxScope.status == .notFound)
        #expect(fixture.accounts.inboxDoneFrontierForTesting(userId: fixture.ownerId, scopeId: fixture.threadId) != nil)
        let wrongThreadScope = try await facetPost(
            client,
            ownerHeaders,
            "/api/channels/threads/done",
            "{\"threadChannelId\":\"\(fixture.channelId)\",\"throughActivitySeq\":\"1\"}"
        )
        #expect(wrongThreadScope.status == .badRequest)
        #expect(facetObject(wrongThreadScope)["code"] as? String == "NOT_A_THREAD")
        #expect(fixture.accounts.inboxDoneFrontierForTesting(userId: fixture.ownerId, scopeId: fixture.channelId) != nil)
    }
}

// MARK: - Done frontier rejection rules (upstream 2367, 2447)

@Test func doneRejectsMalformedBeyondLatestAndAboveInt4FrontiersBeforeWriting() async throws {
    let fixture = makeChannelFacetFixture(5107)
    fixture.accounts.addThreadFollowForTesting(
        serverId: fixture.serverId,
        userId: fixture.ownerId,
        threadChannelId: fixture.threadId,
        parentMessageId: fixture.parentMessageId
    )
    let threadMessageId = seedThreadActivity(fixture, content: "frontier thread fact")

    try await withFacetApp(fixture) { client, _, ownerHeaders, _ in
        for invalid in [NSNull(), 1, "0", "01"] as [Any] {
            let encoded: String
            if invalid is NSNull { encoded = "null" }
            else if let text = invalid as? String { encoded = "\"\(text)\"" }
            else { encoded = "1" }
            for (path, scopeField, scope) in [
                ("/api/channels/inbox/done", "channelId", fixture.channelId),
                ("/api/channels/threads/done", "threadChannelId", fixture.threadId),
            ] {
                let response = try await facetPost(
                    client,
                    ownerHeaders,
                    path,
                    "{\"\(scopeField)\":\"\(scope)\",\"throughActivitySeq\":\(encoded),\"frontierSpace\":\"storage\"}"
                )
                #expect(response.status == .badRequest)
                #expect(facetObject(response)["code"] as? String == "DONE_FRONTIER_REQUIRED")
                #expect(fixture.accounts.inboxDoneFrontierForTesting(userId: fixture.ownerId, scopeId: scope) == nil)
            }
        }

        let unmappable = try await facetPost(
            client,
            ownerHeaders,
            "/api/channels/threads/done",
            "{\"threadChannelId\":\"\(fixture.threadId)\",\"throughActivitySeq\":\"1\",\"frontierSpace\":\"display\"}"
        )
        #expect(unmappable.status == .badRequest)
        #expect(facetObject(unmappable)["code"] as? String == "DONE_FRONTIER_UNMAPPABLE")

        // Beyond the latest activity is rejected before any write.
        let latestSeq = try #require(fixture.accounts.messageSeqForTesting(messageId: threadMessageId))
        let beyondLatest = try await facetPost(
            client,
            ownerHeaders,
            "/api/channels/inbox/done",
            "{\"channelId\":\"\(fixture.channelId)\",\"throughActivitySeq\":\"\(latestSeq + 1)\",\"frontierSpace\":\"storage\"}"
        )
        #expect(beyondLatest.status == .conflict)
        #expect(facetObject(beyondLatest)["code"] as? String == "DONE_FRONTIER_BEYOND_LATEST")
        #expect(fixture.accounts.inboxDoneFrontierForTesting(userId: fixture.ownerId, scopeId: fixture.channelId) == nil)

        // An actual latest above the int4 authority rejects even an omitted frontier.
        let highChannel = fixture.accounts.oauth.createChannel(
            serverId: fixture.serverId,
            name: "done-int4-cap-target",
            creatorUserId: fixture.ownerId
        )
        fixture.accounts.addPostableChannel(
            serverId: fixture.serverId,
            channelId: highChannel,
            memberId: fixture.ownerId,
            name: "done-int4-cap-target"
        )
        fixture.accounts.oauth.addChannelHuman(channelId: highChannel, userId: fixture.ownerId)
        fixture.accounts.addHumanMessageWithSeqForTesting(
            channelId: highChannel,
            senderId: fixture.memberId,
            content: "first actual value above int4 authority",
            seq: 2_147_483_648
        )
        let omittedHigh = try await facetPost(
            client,
            ownerHeaders,
            "/api/channels/inbox/done",
            "{\"channelId\":\"\(highChannel)\",\"frontierSpace\":\"storage\"}"
        )
        #expect(omittedHigh.status == .conflict)
        #expect(facetObject(omittedHigh)["code"] as? String == "DONE_FRONTIER_ABOVE_INT4_AUTHORITY")
        #expect(fixture.accounts.inboxDoneFrontierForTesting(userId: fixture.ownerId, scopeId: highChannel) == nil)
        let explicitHigh = try await facetPost(
            client,
            ownerHeaders,
            "/api/channels/inbox/done",
            "{\"channelId\":\"\(highChannel)\",\"throughActivitySeq\":\"2147483648\",\"frontierSpace\":\"storage\"}"
        )
        #expect(explicitHigh.status == .conflict)
        #expect(facetObject(explicitHigh)["code"] as? String == "DONE_FRONTIER_ABOVE_INT4_AUTHORITY")

        // A rejected Done leaves the follow active and the row visible.
        #expect(fixture.accounts.threadFollowerIdsForTesting(threadChannelId: fixture.threadId).contains(fixture.ownerId))
        #expect(facetThreadRow(try await facetInboxItems(client, ownerHeaders), fixture.threadId) != nil)
    }
}

// MARK: - resume-all-agents skipped start (upstream 3135)

@Test func resumeAllAgentsReportsSkippedStartInsteadOfCountingItResumed() async throws {
    let fixture = makeChannelFacetFixture(5108)
    let startedAgent = fixture.accounts.oauth.createAgent(
        serverId: fixture.serverId,
        name: "resume-ok-\(5108)",
        creatorUserId: fixture.ownerId,
        runtime: "claude"
    )
    let skippedAgent = fixture.accounts.oauth.createAgent(
        serverId: fixture.serverId,
        name: "resume-busy-\(5108)",
        creatorUserId: fixture.ownerId,
        runtime: "claude"
    )
    fixture.accounts.addChannelAgent(channelId: fixture.channelId, agentId: startedAgent)
    fixture.accounts.addChannelAgent(channelId: fixture.channelId, agentId: skippedAgent)

    final class DispatchRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [(agentId: String, prompt: String?)] = []
        func append(_ agentId: String, _ prompt: String?) {
            lock.lock()
            storage.append((agentId, prompt))
            lock.unlock()
        }
        var values: [(agentId: String, prompt: String?)] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        func reset() {
            lock.lock()
            storage.removeAll()
            lock.unlock()
        }
    }
    let recorder = DispatchRecorder()
    fixture.accounts.installAgentStartDispatchForTesting { agentId, prompt in
        recorder.append(agentId, prompt)
        return agentId == skippedAgent ? .skipped("wake_lock_held") : .dispatched
    }

    try await withFacetApp(fixture) { client, _, ownerHeaders, _ in
        let first = try await facetPost(
            client,
            ownerHeaders,
            "/api/channels/\(fixture.channelId)/resume-all-agents",
            "{\"prompt\":\"new guidance\"}"
        )
        #expect(first.status == .ok)
        let body = facetObject(first)
        #expect(body["ok"] as? Bool == false)
        #expect(body["started"] as? Int == 1)
        #expect(body["total"] as? Int == 2)
        let results = body["results"] as? [[String: Any]] ?? []
        #expect(results.first { $0["agentId"] as? String == startedAgent }?["ok"] as? Bool == true)
        let skippedRow = try #require(results.first { $0["agentId"] as? String == skippedAgent })
        #expect(skippedRow["ok"] as? Bool == false)
        #expect(skippedRow["reason"] as? String == "start_in_flight")
        #expect(recorder.values.count == 2)
        #expect(recorder.values.allSatisfy { $0.prompt == "new guidance" })

        // A retry names only the agent that missed the guidance; ids from outside
        // the channel are ignored.
        recorder.reset()
        let retry = try await facetPost(
            client,
            ownerHeaders,
            "/api/channels/\(fixture.channelId)/resume-all-agents",
            "{\"prompt\":\"new guidance\",\"agentIds\":[\"\(skippedAgent)\",\"99999999-9999-4999-8999-999999999999\"]}"
        )
        #expect(retry.status == .ok)
        #expect(facetObject(retry)["total"] as? Int == 1)
        #expect(recorder.values.map(\.agentId) == [skippedAgent])

        let invalid = try await facetPost(
            client,
            ownerHeaders,
            "/api/channels/\(fixture.channelId)/resume-all-agents",
            "{\"prompt\":\"new guidance\",\"agentIds\":\"everyone\"}"
        )
        #expect(invalid.status == .badRequest)
    }
}

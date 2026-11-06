import Foundation
import Testing
import TestSupport
@testable import RaftHTTP

/// The thread service owns the six published thread replies. The HTTP tests
/// lock status codes and parsed JSON; these tests lock the exact published
/// bytes, the wire-level refusals, and the one store critical section that
/// follow/unfollow depends on.

private let parentACreatedAt = Date(timeIntervalSince1970: 1_767_225_600.123)
private let parentBCreatedAt = Date(timeIntervalSince1970: 1_767_225_601.123)
private let replyACreatedAt = Date(timeIntervalSince1970: 1_767_225_605.5)
private let replyBCreatedAt = Date(timeIntervalSince1970: 1_767_225_606.5)
private let followStart = Date(timeIntervalSince1970: 1_767_225_610)
private let unfollowAt = Date(timeIntervalSince1970: 1_767_225_620)

private struct ThreadsFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let memberId: String
    let outsiderId: String
    let ownerToken: String
    let memberToken: String
    let outsiderToken: String
    let channelId: String
    let parentA: String
    let parentB: String
    let threadA: String
    let threadB: String
    let replyA: String
    let replyB: String
    let agentId: String

    var ownerAuthorization: String { "Bearer \(ownerToken)" }
    var memberAuthorization: String { "Bearer \(memberToken)" }
    var outsiderAuthorization: String { "Bearer \(outsiderToken)" }

    func key(_ threadId: String, userId: String) -> String {
        "\(serverId)\n\(userId)\n\(threadId)"
    }
}

private func makeThreadsFixture() -> ThreadsFixture {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000000996001"
    let ownerId = "11111111-1111-4111-8111-000000996001"
    let memberId = "11111111-1111-4111-8111-000000996002"
    let outsiderId = "11111111-1111-4111-8111-000000996003"
    for (id, email) in [
        (ownerId, "threads-owner@slock.test"),
        (memberId, "threads-member@slock.test"),
        (outsiderId, "threads-outsider@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "threads-service", name: "Threads Service", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    accounts.oauth.addMember(serverId: serverId, userId: outsiderId, role: "member")
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "threads-service", creatorUserId: ownerId)
    for id in [ownerId, memberId, outsiderId] {
        accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: id, name: "threads-service")
        accounts.oauth.addChannelHuman(channelId: channel, userId: id)
    }
    let parentA = accounts.addChannelMessageForTesting(
        channelId: channel,
        content: "parent a",
        senderId: ownerId,
        createdAt: parentACreatedAt
    )
    let parentB = accounts.addChannelMessageForTesting(
        channelId: channel,
        content: "parent b",
        senderId: memberId,
        createdAt: parentBCreatedAt
    )
    let threadA = accounts.oauth.createThreadChannel(parentChannelId: channel, parentMessageId: parentA)
    let threadB = accounts.oauth.createThreadChannel(parentChannelId: channel, parentMessageId: parentB)
    for (thread, parent) in [(threadA, parentA), (threadB, parentB)] {
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
            accounts.oauth.addChannelHuman(channelId: thread, userId: id)
        }
    }
    // Production writes creation order when a thread is opened; the fixture
    // records the same order so the summary map is deterministic.
    accounts.threadOrder = [threadA, threadB]
    let replyA = accounts.addChannelMessageForTesting(
        channelId: threadA,
        content: "reply a",
        senderId: memberId,
        createdAt: replyACreatedAt
    )
    let replyB = accounts.addChannelMessageForTesting(
        channelId: threadB,
        content: "reply b",
        senderId: memberId,
        createdAt: replyBCreatedAt
    )
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "Roster Agent", runtime: "codex")
    accounts.oauth.addChannelAgent(channelId: threadA, agentId: agentId)
    return ThreadsFixture(
        accounts: accounts,
        serverId: serverId,
        ownerId: ownerId,
        memberId: memberId,
        outsiderId: outsiderId,
        ownerToken: accounts.mintAccessTokenForTesting(userId: ownerId),
        memberToken: accounts.mintAccessTokenForTesting(userId: memberId),
        outsiderToken: accounts.mintAccessTokenForTesting(userId: outsiderId),
        channelId: channel,
        parentA: parentA,
        parentB: parentB,
        threadA: threadA,
        threadB: threadB,
        replyA: replyA,
        replyB: replyB,
        agentId: agentId
    )
}

private func makeService(
    _ accounts: EmailLoginDirectory,
    now: Date = followStart,
    publish: @escaping @Sendable (ThreadFollowersUpdatedPayload) -> Void = { _ in }
) -> ThreadsService {
    var dependencies = ThreadsDependencies.live(directory: accounts)
    dependencies.now = { now }
    return ThreadsService(
        store: accounts.messagesAndThreadsStore,
        dependencies: dependencies,
        publishFollowersUpdated: publish
    )
}

private final class FollowerPublishCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ThreadFollowersUpdatedPayload] = []

    func append(_ payload: ThreadFollowersUpdatedPayload) {
        lock.lock()
        storage.append(payload)
        lock.unlock()
    }

    var payloads: [ThreadFollowersUpdatedPayload] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

// MARK: - Follower roster

@Test func threadFollowerRosterRendersThePublishedBytes() throws {
    let fixture = makeThreadsFixture()
    let service = makeService(fixture.accounts)

    let owner = try service.threadFollowerRoster(
        authorization: fixture.ownerAuthorization,
        serverId: fixture.serverId,
        threadChannelIds: "\(fixture.threadA),\(fixture.threadB),not-a-thread"
    )
    #expect(owner.jsonBody.render() == """
    {"threads":[{"threadChannelId":"\(fixture.threadA)","canManage":true,"agents":[{"id":"\(fixture.agentId)","name":"Roster Agent"}]},{"threadChannelId":"\(fixture.threadB)","canManage":true,"agents":[]}]}
    """)

    let member = try service.threadFollowerRoster(
        authorization: fixture.memberAuthorization,
        serverId: fixture.serverId,
        threadChannelIds: "\(fixture.threadA),\(fixture.threadB)"
    )
    #expect(member.jsonBody.render() == """
    {"threads":[{"threadChannelId":"\(fixture.threadA)","canManage":false,"agents":[{"id":"\(fixture.agentId)","name":"Roster Agent"}]},{"threadChannelId":"\(fixture.threadB)","canManage":true,"agents":[]}]}
    """)
}

@Test func threadFollowerRosterRefusalsCarryTheirPublishedBodies() {
    let fixture = makeThreadsFixture()
    let service = makeService(fixture.accounts)

    do {
        _ = try service.threadFollowerRoster(
            authorization: nil,
            serverId: fixture.serverId,
            threadChannelIds: fixture.threadA
        )
        Issue.record("a missing session must be refused")
    } catch let error as ThreadsError {
        #expect(error == .unauthorized)
        #expect(error.status == 401)
        #expect(error.publishedErrorBody.render() == "{\"error\":\"Unauthorized\"}")
    } catch {
        Issue.record("unexpected error: \(error)")
    }

    let stranger = EmailLoginDirectory()
    stranger.addAccount(
        id: "11111111-1111-4111-8111-000000996099",
        email: "threads-stranger@slock.test",
        password: "password123"
    )
    let strangerToken = stranger.mintAccessTokenForTesting(userId: "11111111-1111-4111-8111-000000996099")
    do {
        _ = try makeService(stranger).threadFollowerRoster(
            authorization: "Bearer \(strangerToken)",
            serverId: fixture.serverId,
            threadChannelIds: fixture.threadA
        )
        Issue.record("a non-member must be refused")
    } catch let error as ThreadsError {
        #expect(error == .notServerMember)
        #expect(error.status == 403)
        #expect(error.publishedErrorBody.render() == "{\"error\":\"Not a member of this server\"}")
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

// MARK: - Follow and unfollow

@Test func threadFollowMutationRendersThePublishedBytes() throws {
    let fixture = makeThreadsFixture()
    let service = makeService(fixture.accounts)

    let followed = try service.setThreadFollow(
        ThreadFollowMutationDTO(threadChannelId: fixture.threadA),
        authorization: fixture.ownerAuthorization,
        serverId: fixture.serverId,
        follow: true
    )
    #expect(followed.jsonBody.render() == "{\"ok\":true,\"following\":true}")
    #expect(fixture.accounts.threadFollows[fixture.key(fixture.threadA, userId: fixture.ownerId)] != nil)

    let unfollowed = try service.setThreadFollow(
        ThreadFollowMutationDTO(threadChannelId: fixture.threadA),
        authorization: fixture.ownerAuthorization,
        serverId: fixture.serverId,
        follow: false
    )
    #expect(unfollowed.jsonBody.render() == "{\"ok\":true,\"following\":false}")
    #expect(fixture.accounts.threadFollows[fixture.key(fixture.threadA, userId: fixture.ownerId)] == nil)
    #expect(fixture.accounts.threadUnfollows[fixture.key(fixture.threadA, userId: fixture.ownerId)] != nil)
}

@Test func threadFollowResolvesTheParentMessageAndPublishesOnlyTheNamedThread() throws {
    let fixture = makeThreadsFixture()
    let collector = FollowerPublishCollector()
    let service = makeService(fixture.accounts, publish: { collector.append($0) })

    let byParent = try service.setThreadFollow(
        ThreadFollowMutationDTO(parentMessageId: fixture.parentA),
        authorization: fixture.ownerAuthorization,
        serverId: fixture.serverId,
        follow: true
    )
    #expect(byParent.jsonBody.render() == "{\"ok\":true,\"following\":true}")
    #expect(fixture.accounts.threadFollows[fixture.key(fixture.threadA, userId: fixture.ownerId)] != nil)
    // The legacy frame guard decoded `threadChannelId` from the request body, so
    // a parent-only request wrote the row but emitted no event.
    #expect(collector.payloads.isEmpty)

    _ = try service.setThreadFollow(
        ThreadFollowMutationDTO(threadChannelId: fixture.threadB),
        authorization: fixture.ownerAuthorization,
        serverId: fixture.serverId,
        follow: true
    )
    #expect(collector.payloads == [ThreadFollowersUpdatedPayload(threadChannelId: fixture.threadB)])

    do {
        _ = try service.setThreadFollow(
            nil,
            authorization: fixture.ownerAuthorization,
            serverId: fixture.serverId,
            follow: true
        )
        Issue.record("a body that is not a JSON object must stay thread-not-found")
    } catch let error as ThreadsError {
        #expect(error == .threadNotFound)
        #expect(error.status == 404)
        #expect(error.publishedErrorBody.render() == "{\"error\":\"Thread not found\"}")
    } catch {
        Issue.record("unexpected error: \(error)")
    }
    #expect(collector.payloads.count == 1)
}

// MARK: - Unfollowed inbox

@Test func unfollowedInboxRendersTheFrozenWindowBytes() throws {
    let fixture = makeThreadsFixture()
    let followService = makeService(fixture.accounts, now: followStart)
    _ = try followService.setThreadFollow(
        ThreadFollowMutationDTO(threadChannelId: fixture.threadA),
        authorization: fixture.ownerAuthorization,
        serverId: fixture.serverId,
        follow: true
    )
    // Only replies inside the follow window are frozen; the pre-follow reply
    // and the parent message stay out.
    let lateReply = fixture.accounts.addChannelMessageForTesting(
        channelId: fixture.threadA,
        content: "late reply",
        senderId: fixture.memberId,
        createdAt: Date(timeIntervalSince1970: 1_767_225_615)
    )
    let unfollowService = makeService(fixture.accounts, now: unfollowAt)
    _ = try unfollowService.setThreadFollow(
        ThreadFollowMutationDTO(threadChannelId: fixture.threadA),
        authorization: fixture.ownerAuthorization,
        serverId: fixture.serverId,
        follow: false
    )

    let inbox = try unfollowService.unfollowedInbox(
        authorization: fixture.ownerAuthorization,
        serverId: fixture.serverId,
        limit: nil,
        query: nil
    )
    #expect(inbox.jsonBody.render() == """
    {"items":[{"kind":"thread","threadChannelId":"\(fixture.threadA)","latestActivityMessageId":"\(lateReply)","replyCount":1,"unreadCount":0,"hasMention":false,"isFollowing":false,"unfollowedAt":"2026-01-01T00:00:20Z"}],"hasMore":false,"totalCount":null}
    """)

    let matching = try unfollowService.unfollowedInbox(
        authorization: fixture.ownerAuthorization,
        serverId: fixture.serverId,
        limit: "1",
        query: "  LATE  "
    )
    #expect(matching.jsonBody.render().contains("\"threadChannelId\":\"\(fixture.threadA)\""))

    let missing = try unfollowService.unfollowedInbox(
        authorization: fixture.ownerAuthorization,
        serverId: fixture.serverId,
        limit: nil,
        query: "no such reply"
    )
    #expect(missing.jsonBody.render() == "{\"items\":[],\"hasMore\":false,\"totalCount\":null}")
}

@Test func unfollowedInboxPagesNewestFirst() throws {
    let fixture = makeThreadsFixture()
    let service = makeService(fixture.accounts, now: unfollowAt)
    for threadId in [fixture.threadA, fixture.threadB] {
        _ = try service.setThreadFollow(
            ThreadFollowMutationDTO(threadChannelId: threadId),
            authorization: fixture.ownerAuthorization,
            serverId: fixture.serverId,
            follow: true
        )
    }
    let later = makeService(fixture.accounts, now: Date(timeIntervalSince1970: 1_767_225_630))
    for threadId in [fixture.threadA, fixture.threadB] {
        _ = try later.setThreadFollow(
            ThreadFollowMutationDTO(threadChannelId: threadId),
            authorization: fixture.ownerAuthorization,
            serverId: fixture.serverId,
            follow: false
        )
    }
    let firstPage = try service.unfollowedInbox(
        authorization: fixture.ownerAuthorization,
        serverId: fixture.serverId,
        limit: "1",
        query: nil
    )
    #expect(firstPage.hasMore)
    #expect(firstPage.jsonBody.render().hasSuffix("\"hasMore\":true,\"totalCount\":null}"))
}

// MARK: - Followed threads

@Test func followedThreadsRendersThePublishedBytes() throws {
    let fixture = makeThreadsFixture()
    let service = makeService(fixture.accounts, now: followStart)
    for threadId in [fixture.threadA, fixture.threadB] {
        _ = try service.setThreadFollow(
            ThreadFollowMutationDTO(threadChannelId: threadId),
            authorization: fixture.ownerAuthorization,
            serverId: fixture.serverId,
            follow: true
        )
    }

    let all = try service.followedThreads(
        authorization: fixture.ownerAuthorization,
        serverId: fixture.serverId
    )
    #expect(all.jsonBody.render() == """
    {"threads":[{"threadChannelId":"\(fixture.threadB)","parentChannelId":"\(fixture.channelId)","parentMessageCreatedAt":"2026-01-01T00:00:01.123Z","unreadCount":1,"firstUnreadMessageId":"\(fixture.replyB)","hasMention":false,"taskId":null,"taskClaimedByType":null,"taskClaimedById":null,"taskClaimedByName":null},{"threadChannelId":"\(fixture.threadA)","parentChannelId":"\(fixture.channelId)","parentMessageCreatedAt":"2026-01-01T00:00:00.123Z","unreadCount":1,"firstUnreadMessageId":"\(fixture.replyA)","hasMention":false,"taskId":null,"taskClaimedByType":null,"taskClaimedById":null,"taskClaimedByName":null}]}
    """)
    // Without a limit the legacy body has no `next` member at all.
    #expect(!all.jsonBody.render().contains("\"next\":"))
}

@Test func followedThreadsPagesWithCursorAndRendersNext() throws {
    let fixture = makeThreadsFixture()
    let service = makeService(fixture.accounts, now: followStart)
    for threadId in [fixture.threadA, fixture.threadB] {
        _ = try service.setThreadFollow(
            ThreadFollowMutationDTO(threadChannelId: threadId),
            authorization: fixture.ownerAuthorization,
            serverId: fixture.serverId,
            follow: true
        )
    }
    let firstPage = try service.followedThreads(
        authorization: fixture.ownerAuthorization,
        serverId: fixture.serverId,
        limit: "1"
    )
    #expect(firstPage.jsonBody.render().hasPrefix("{\"threads\":[{\"threadChannelId\":\"\(fixture.threadB)\""))
    #expect(firstPage.jsonBody.render().hasSuffix("],\"next\":\"v1:1\"}"))

    let secondPage = try service.followedThreads(
        authorization: fixture.ownerAuthorization,
        serverId: fixture.serverId,
        limit: "1",
        cursor: "v1:1"
    )
    #expect(secondPage.jsonBody.render().hasPrefix("{\"threads\":[{\"threadChannelId\":\"\(fixture.threadA)\""))
    #expect(secondPage.jsonBody.render().hasSuffix("],\"next\":null}"))
}

@Test func followedThreadsRefusalsCarryTheirPublishedBodies() {
    let fixture = makeThreadsFixture()
    let service = makeService(fixture.accounts)
    do {
        _ = try service.followedThreads(
            authorization: fixture.ownerAuthorization,
            serverId: fixture.serverId,
            limit: "0"
        )
        Issue.record("limit 0 must be refused")
    } catch let error as ThreadsError {
        #expect(error == .limitOutOfRange)
        #expect(error.status == 400)
        #expect(error.publishedErrorBody.render() == "{\"error\":\"limit must be an integer between 1 and 200\"}")
    } catch {
        Issue.record("unexpected error: \(error)")
    }

    do {
        _ = try service.followedThreads(
            authorization: fixture.ownerAuthorization,
            serverId: fixture.serverId,
            cursor: "v1:1"
        )
        Issue.record("a cursor without a limit must be refused")
    } catch let error as ThreadsError {
        #expect(error == .cursorRequiresLimit)
        #expect(error.publishedErrorBody.render() == "{\"error\":\"cursor requires limit\"}")
    } catch {
        Issue.record("unexpected error: \(error)")
    }

    do {
        _ = try service.followedThreads(
            authorization: fixture.ownerAuthorization,
            serverId: fixture.serverId,
            limit: "1",
            cursor: "v2:1"
        )
        Issue.record("a foreign cursor must be refused")
    } catch let error as ThreadsError {
        #expect(error == .invalidCursor)
        #expect(error.publishedErrorBody.render() == "{\"error\":\"invalid cursor\"}")
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

// MARK: - Thread info

@Test func threadInfoRendersThePublishedBytes() throws {
    let fixture = makeThreadsFixture()
    let service = makeService(fixture.accounts)

    let info = try service.threadInfo(
        authorization: fixture.ownerAuthorization,
        serverId: fixture.serverId,
        channelId: fixture.channelId,
        messageId: fixture.parentA
    )
    #expect(info.jsonBody.render() == """
    {"threadChannelId":"\(fixture.threadA)","replyCount":1,"lastReplyAt":"2026-01-01T00:00:05Z","participantIds":["\(fixture.ownerId)","\(fixture.memberId)"]}
    """)
}

@Test func threadInfoRefusalsCarryTheirPublishedBodies() throws {
    let fixture = makeThreadsFixture()
    let service = makeService(fixture.accounts)
    let bareParent = fixture.accounts.addChannelMessageForTesting(
        channelId: fixture.channelId,
        content: "no thread",
        senderId: fixture.ownerId,
        createdAt: parentACreatedAt
    )

    do {
        _ = try service.threadInfo(
            authorization: fixture.ownerAuthorization,
            serverId: fixture.serverId,
            channelId: fixture.channelId,
            messageId: bareParent
        )
        Issue.record("a parent without a thread must be refused")
    } catch let error as ThreadsError {
        #expect(error == .threadNotFoundForMessage)
        #expect(error.status == 404)
        #expect(error.publishedErrorBody.render() == "{\"code\":\"THREAD_NOT_FOUND\",\"error\":\"No thread found for this message\"}")
    } catch {
        Issue.record("unexpected error: \(error)")
    }

    do {
        _ = try service.threadInfo(
            authorization: fixture.outsiderAuthorization,
            serverId: fixture.serverId,
            channelId: fixture.threadA,
            messageId: fixture.parentA
        )
        Issue.record("an unreadable thread must be refused")
    } catch let error as ThreadsError {
        #expect(error == .channelNotVisible)
        #expect(error.publishedErrorBody.render() == "{\"error\":\"Channel not found or not visible\"}")
    } catch {
        Issue.record("unexpected error: \(error)")
    }

    fixture.accounts.markInboxResidueForTesting(userId: fixture.outsiderId, channelId: fixture.threadA)
    do {
        _ = try service.threadInfo(
            authorization: fixture.outsiderAuthorization,
            serverId: fixture.serverId,
            channelId: fixture.threadA,
            messageId: fixture.parentA
        )
        Issue.record("probe residue must be refused")
    } catch let error as ThreadsError {
        #expect(error == .forbidden)
        #expect(error.publishedErrorBody.render() == "{\"error\":\"Forbidden\"}")
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

// MARK: - Channel thread summaries

@Test func channelThreadSummariesRenderThePublishedBytes() throws {
    let fixture = makeThreadsFixture()
    let service = makeService(fixture.accounts, now: followStart)
    _ = try service.setThreadFollow(
        ThreadFollowMutationDTO(threadChannelId: fixture.threadB),
        authorization: fixture.ownerAuthorization,
        serverId: fixture.serverId,
        follow: true
    )

    let summaries = try service.channelThreadSummaries(
        authorization: fixture.ownerAuthorization,
        serverId: fixture.serverId,
        channelId: fixture.channelId
    )
    #expect(summaries.jsonBody.render() == """
    {"\(fixture.parentA)":{"threadChannelId":"\(fixture.threadA)","replyCount":1,"latestReplies":[{"preview":"reply a","senderType":"user","senderId":"\(fixture.memberId)","senderName":"threads-member","senderDisplayName":"threads-member"}],"unreadCount":0,"firstUnreadMessageId":null,"participantIds":["\(fixture.ownerId)","\(fixture.memberId)"],"followed":false},"\(fixture.parentB)":{"threadChannelId":"\(fixture.threadB)","replyCount":1,"latestReplies":[{"preview":"reply b","senderType":"user","senderId":"\(fixture.memberId)","senderName":"threads-member","senderDisplayName":"threads-member"}],"unreadCount":1,"firstUnreadMessageId":"\(fixture.replyB)","participantIds":["\(fixture.memberId)"],"followed":true}}
    """)

    let filtered = try service.channelThreadSummaries(
        authorization: fixture.ownerAuthorization,
        serverId: fixture.serverId,
        channelId: fixture.channelId,
        parentMessageIds: " \(fixture.parentA) "
    )
    #expect(filtered.jsonBody.render().hasPrefix("{\"\(fixture.parentA)\":"))
    #expect(!filtered.jsonBody.render().contains(fixture.parentB))
}

@Test func channelThreadSummariesRefusalKeepsTheNoStoreHeader() {
    let fixture = makeThreadsFixture()
    let service = makeService(fixture.accounts)

    do {
        _ = try service.channelThreadSummaries(
            authorization: nil,
            serverId: fixture.serverId,
            channelId: fixture.channelId
        )
        Issue.record("a missing header must be refused")
    } catch let error as ThreadsError {
        #expect(error == .missingAuthorization)
        #expect(error.status == 401)
        #expect(error.responseHeaders == ["Cache-Control": "no-store"])
        #expect(error.publishedErrorBody.render() == "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
    } catch {
        Issue.record("unexpected error: \(error)")
    }

    do {
        _ = try service.channelThreadSummaries(
            authorization: "Bearer not-a-token",
            serverId: fixture.serverId,
            channelId: fixture.channelId
        )
        Issue.record("a dead token must be refused")
    } catch let error as ThreadsError {
        #expect(error == .invalidAccessToken)
        #expect(error.responseHeaders == ["Cache-Control": "no-store"])
        #expect(error.publishedErrorBody.render() == "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

// MARK: - Atomic follow/unfollow

@Test func followAndUnfollowAreOneStoreCriticalSection() async {
    let fixture = makeThreadsFixture()
    let service = makeService(fixture.accounts)
    let body = ThreadFollowMutationDTO(threadChannelId: fixture.threadA)
    let authorization = fixture.ownerAuthorization
    let serverId = fixture.serverId
    let key = fixture.key(fixture.threadA, userId: fixture.ownerId)

    for _ in 0..<200 {
        async let followed: Void = {
            _ = try? service.setThreadFollow(body, authorization: authorization, serverId: serverId, follow: true)
        }()
        async let unfollowed: Void = {
            _ = try? service.setThreadFollow(body, authorization: authorization, serverId: serverId, follow: false)
        }()
        _ = await (followed, unfollowed)
        let isFollowing = fixture.accounts.threadFollows[key] != nil
        let suppressed = fixture.accounts.threadUnfollows[key] != nil
        #expect(isFollowing != suppressed, "a follow row and its unfollow suppression row must never coexist")
    }
}

@Test func unfollowFreezesOnlyRepliesInsideTheFollowWindow() throws {
    let fixture = makeThreadsFixture()
    let followService = makeService(fixture.accounts, now: followStart)
    _ = try followService.setThreadFollow(
        ThreadFollowMutationDTO(threadChannelId: fixture.threadA),
        authorization: fixture.ownerAuthorization,
        serverId: fixture.serverId,
        follow: true
    )
    let lateReply = fixture.accounts.addChannelMessageForTesting(
        channelId: fixture.threadA,
        content: "inside the window",
        senderId: fixture.memberId,
        createdAt: Date(timeIntervalSince1970: 1_767_225_615)
    )
    let unfollowService = makeService(fixture.accounts, now: unfollowAt)
    _ = try unfollowService.setThreadFollow(
        ThreadFollowMutationDTO(threadChannelId: fixture.threadA),
        authorization: fixture.ownerAuthorization,
        serverId: fixture.serverId,
        follow: false
    )

    let key = fixture.key(fixture.threadA, userId: fixture.ownerId)
    let record = try #require(fixture.accounts.threadUnfollows[key])
    #expect(record.replyCount == 1)
    #expect(record.latestMessageId == lateReply)
    #expect(record.frozenMessages.map(\.id) == [lateReply])
    #expect(fixture.accounts.threadFollowStarts[key] == nil)
}

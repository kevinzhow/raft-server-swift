import Foundation
import Synchronization
import Testing
import TestSupport
@testable import RaftHTTP

/// The message-send service owns three published replies: the attachment
/// download URL, the thread-follower removal/restore undo pair and the
/// migration receipt DM. The HTTP tests lock statuses and parsed JSON; these
/// tests lock the exact published bytes and the store critical sections the
/// undo ledger depends on.

/// 2026-01-01T00:00:00Z, so a five-minute URL expires at a fixed literal.
private let fixedNow = Date(timeIntervalSince1970: 1_767_225_600)

private struct MessageSendFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let memberId: String
    let outsiderId: String
    let strangerId: String
    let agentId: String
    let channelId: String
    let parentMessageId: String
    let threadId: String
    let attachmentId: String
    let privateChannelId: String
    let privateAttachmentId: String
    let ownerAuthorization: String
    let memberAuthorization: String
    let outsiderAuthorization: String
    let strangerAuthorization: String
}

private func makeMessageSendFixture() -> MessageSendFixture {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001108001"
    let ownerId = "11111111-1111-4111-8111-000001108001"
    let memberId = "11111111-1111-4111-8111-000001108002"
    let outsiderId = "11111111-1111-4111-8111-000001108003"
    // Verified, but not a member of this server: the attachment URL answers
    // 403 before the attachment lookup.
    let strangerId = "11111111-1111-4111-8111-000001108005"
    for (id, email) in [
        (ownerId, "message-send-owner@slock.test"),
        (memberId, "message-send-member@slock.test"),
        (outsiderId, "message-send-outsider@slock.test"),
        (strangerId, "message-send-stranger@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "message-send", name: "Message Send", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    accounts.oauth.addMember(serverId: serverId, userId: outsiderId, role: "member")
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "message-send-room", creatorUserId: ownerId)
    for id in [ownerId, memberId, outsiderId] {
        accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: id, name: "message-send-room")
        accounts.oauth.addChannelHuman(channelId: channel, userId: id)
    }
    let parentMessageId = accounts.addChannelMessageForTesting(
        channelId: channel,
        content: "thread parent",
        senderId: memberId
    )
    let threadId = accounts.oauth.createThreadChannel(parentChannelId: channel, parentMessageId: parentMessageId)
    accounts.addPostableChannel(
        serverId: serverId,
        channelId: threadId,
        memberId: memberId,
        kind: "thread",
        parentChannelId: channel,
        parentMessageId: parentMessageId,
        name: "thread"
    )
    accounts.oauth.addChannelHuman(channelId: threadId, userId: memberId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "Receipt Agent", runtime: "codex")
    accounts.oauth.addChannelAgent(channelId: threadId, agentId: agentId)
    let attachmentId = accounts.addChannelAttachment(
        channelId: channel,
        uploaderId: ownerId,
        filename: "report.txt",
        mimeType: "text/plain",
        sizeBytes: 12
    )
    // A private channel the outsider cannot read: its unlinked attachment is
    // invisible, so the download URL answers 404.
    let privateChannel = accounts.oauth.createChannel(
        serverId: serverId,
        name: "message-send-private",
        creatorUserId: ownerId
    )
    accounts.addPostableChannel(
        serverId: serverId,
        channelId: privateChannel,
        memberId: ownerId,
        kind: "private",
        name: "message-send-private"
    )
    accounts.oauth.addChannelHuman(channelId: privateChannel, userId: ownerId)
    let privateAttachmentId = accounts.addChannelAttachment(
        channelId: privateChannel,
        uploaderId: ownerId,
        filename: "secret.txt",
        mimeType: "text/plain",
        sizeBytes: 12
    )
    return MessageSendFixture(
        accounts: accounts,
        serverId: serverId,
        ownerId: ownerId,
        memberId: memberId,
        outsiderId: outsiderId,
        strangerId: strangerId,
        agentId: agentId,
        channelId: channel,
        parentMessageId: parentMessageId,
        threadId: threadId,
        attachmentId: attachmentId,
        privateChannelId: privateChannel,
        privateAttachmentId: privateAttachmentId,
        ownerAuthorization: "Bearer \(accounts.mintAccessTokenForTesting(userId: ownerId))",
        memberAuthorization: "Bearer \(accounts.mintAccessTokenForTesting(userId: memberId))",
        outsiderAuthorization: "Bearer \(accounts.mintAccessTokenForTesting(userId: outsiderId))",
        strangerAuthorization: "Bearer \(accounts.mintAccessTokenForTesting(userId: strangerId))"
    )
}

private func makeService(
    _ accounts: EmailLoginDirectory,
    now: Date = fixedNow,
    makeToken: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
) -> MessageSendService {
    MessageSendService(
        messages: accounts.messagesAndThreadsStore,
        channels: accounts.serversAndChannelsStore,
        profiles: accounts.authProfileStore,
        oauth: accounts.oauth,
        visibleAttachment: { userId, serverId, attachment in
            accounts.visibleAttachment(userId: userId, serverId: serverId, attachment: attachment)
        },
        emitRealtime: { room, event, payload in
            accounts.realtimeRelay.emit(room, event, payload)
        },
        registerPostableChannel: { serverId, channelId, memberId, kind, name in
            accounts.addPostableChannel(
                serverId: serverId,
                channelId: channelId,
                memberId: memberId,
                kind: kind,
                name: name
            )
        },
        appendHumanMessage: { message in
            accounts.messagesAndThreadsStore.appendMessage(message, ledger: .init(oauth: accounts.oauth))
        },
        now: { now },
        makeToken: makeToken
    )
}

// MARK: - GET /api/attachments/:id/url

@Test func attachmentDownloadURLPublishesTheLegacyBodyOrder() throws {
    let fixture = makeMessageSendFixture()
    fixture.accounts.messagesAndThreadsStore.attachmentPresign = { id, _, _ in "https://cdn.test/\(id)" }
    let service = makeService(fixture.accounts)

    let response = try service.attachmentDownloadURL(
        attachmentId: fixture.attachmentId,
        authorization: fixture.ownerAuthorization,
        serverId: fixture.serverId
    )

    #expect(response.jsonBody.render() == """
    {"url":"https://cdn.test/\(fixture.attachmentId)","expiresAt":"2026-01-01T00:05:00.000Z"}
    """)
}

@Test func attachmentDownloadURLKeepsTheInlineMediaTTLAndTheDownloadOverride() throws {
    let fixture = makeMessageSendFixture()
    let video = fixture.accounts.addChannelAttachment(
        channelId: fixture.channelId,
        uploaderId: fixture.ownerId,
        filename: "clip.mp4",
        mimeType: "video/mp4",
        sizeBytes: 42
    )
    let service = makeService(fixture.accounts)

    let inlineVideo = try service.attachmentDownloadURL(
        attachmentId: video,
        authorization: fixture.ownerAuthorization,
        serverId: fixture.serverId,
        disposition: "inline"
    )
    #expect(inlineVideo.jsonBody.render() == """
    {"url":"/api/attachments/\(video)","expiresAt":"2026-01-01T01:00:00.000Z"}
    """)

    let forcedDownload = try service.attachmentDownloadURL(
        attachmentId: video,
        authorization: fixture.ownerAuthorization,
        serverId: fixture.serverId,
        disposition: "inline",
        download: "1"
    )
    #expect(forcedDownload.jsonBody.render() == """
    {"url":"/api/attachments/\(video)","expiresAt":"2026-01-01T00:05:00.000Z"}
    """)

    let inlinePdf = try service.attachmentDownloadURL(
        attachmentId: fixture.attachmentId,
        authorization: fixture.ownerAuthorization,
        serverId: fixture.serverId,
        disposition: "inline"
    )
    #expect(inlinePdf.jsonBody.render() == """
    {"url":"/api/attachments/\(fixture.attachmentId)","expiresAt":"2026-01-01T00:05:00.000Z"}
    """)
}

@Test func attachmentDownloadURLPropagatesTheQueryTokenAndPublishesNullExpiry() throws {
    let fixture = makeMessageSendFixture()
    fixture.accounts.messagesAndThreadsStore.attachmentPresign = { id, _, _ in "https://cdn.test/\(id)?sig=1" }
    let service = makeService(fixture.accounts)

    let response = try service.attachmentDownloadURL(
        attachmentId: fixture.attachmentId,
        authorization: fixture.ownerAuthorization,
        serverId: fixture.serverId,
        propagateQueryToken: "abc123"
    )

    #expect(response.jsonBody.render() == """
    {"url":"https://cdn.test/\(fixture.attachmentId)?sig=1&token=abc123&serverId=\(fixture.serverId)","expiresAt":null}
    """)
}

@Test func attachmentDownloadURLKeepsTheLegacyRefusalOrder() throws {
    let fixture = makeMessageSendFixture()
    let service = makeService(fixture.accounts)

    func refusal(
        _ call: () throws -> AttachmentDownloadURLResponse
    ) -> MessageSendError? {
        do {
            _ = try call()
            return nil
        } catch let error as MessageSendError {
            return error
        } catch {
            return nil
        }
    }

    #expect(refusal {
        try service.attachmentDownloadURL(
            attachmentId: fixture.attachmentId,
            authorization: nil,
            serverId: fixture.serverId
        )
    } == .missingAuthorization)
    #expect(refusal {
        try service.attachmentDownloadURL(
            attachmentId: fixture.attachmentId,
            authorization: "Bearer unknown-token",
            serverId: fixture.serverId
        )
    } == .invalidToken)
    #expect(refusal {
        try service.attachmentDownloadURL(
            attachmentId: fixture.attachmentId,
            authorization: fixture.ownerAuthorization,
            serverId: nil
        )
    } == .missingServerId)
    #expect(refusal {
        try service.attachmentDownloadURL(
            attachmentId: "not-a-uuid",
            authorization: fixture.ownerAuthorization,
            serverId: fixture.serverId
        )
    } == .invalidAttachmentId)
    #expect(refusal {
        try service.attachmentDownloadURL(
            attachmentId: fixture.attachmentId,
            authorization: fixture.strangerAuthorization,
            serverId: fixture.serverId
        )
    } == .notServerMember)
    #expect(refusal {
        try service.attachmentDownloadURL(
            attachmentId: fixture.privateAttachmentId,
            authorization: fixture.outsiderAuthorization,
            serverId: fixture.serverId
        )
    } == .attachmentNotFound)

    // Retired accounts are refused after verification, before the header check.
    let retiredId = "11111111-1111-4111-8111-000001108004"
    fixture.accounts.addAccount(id: retiredId, email: "message-send-retired@slock.test", password: "password123")
    fixture.accounts.markEmailVerified(userId: retiredId)
    let retiredAuthorization = "Bearer \(fixture.accounts.mintAccessTokenForTesting(userId: retiredId))"
    fixture.accounts.retireUserForTesting(userId: retiredId)
    #expect(refusal {
        try service.attachmentDownloadURL(
            attachmentId: fixture.attachmentId,
            authorization: retiredAuthorization,
            serverId: fixture.serverId
        )
    } == .unauthorized)

    // The published bodies.
    #expect(MessageSendError.missingAuthorization.publishedErrorBody.render() == """
    {"error":"Missing or invalid Authorization header","code":"auth_required"}
    """)
    #expect(MessageSendError.invalidAttachmentId.publishedErrorBody.render() == """
    {"code":"invalid_attachment_id","error":"Invalid attachment id"}
    """)
    #expect(MessageSendError.unauthorized.publishedErrorBody.render() == """
    {"error":"Unauthorized"}
    """)
    #expect(MessageSendError.attachmentNotFound.status == 404)
    #expect(MessageSendError.notServerMember.status == 403)
}

// MARK: - Thread-follower undo ledger

@Test func threadFollowerRemovalPublishesTheLegacyBodiesAndOneUndoToken() throws {
    let fixture = makeMessageSendFixture()
    let tokens = Mutex(0)
    let service = makeService(fixture.accounts) {
        let next = tokens.withLock { value -> Int in
            value += 1
            return value
        }
        return "undo-\(next)"
    }

    let first = try service.removeThreadFollower(
        authorization: fixture.memberAuthorization,
        serverId: fixture.serverId,
        threadId: fixture.threadId,
        agentId: fixture.agentId
    )
    #expect(first.jsonBody.render() == """
    {"removed":true,"undoToken":"undo-1"}
    """)
    #expect(fixture.accounts.oauth.channelAgentIds(channelId: fixture.threadId).contains(fixture.agentId) == false)

    let replay = try service.removeThreadFollower(
        authorization: fixture.memberAuthorization,
        serverId: fixture.serverId,
        threadId: fixture.threadId,
        agentId: fixture.agentId
    )
    #expect(replay.jsonBody.render() == """
    {"ok":true,"removed":true,"undoToken":"undo-1"}
    """)
    #expect(fixture.accounts.messagesAndThreadsStore.threadFollowerRemovals.count == 1)
}

@Test func concurrentThreadFollowerRemovalsIssueExactlyOneToken() async throws {
    let fixture = makeMessageSendFixture()
    let service = makeService(fixture.accounts)

    async let first = service.removeThreadFollower(
        authorization: fixture.memberAuthorization,
        serverId: fixture.serverId,
        threadId: fixture.threadId,
        agentId: fixture.agentId
    )
    async let second = service.removeThreadFollower(
        authorization: fixture.memberAuthorization,
        serverId: fixture.serverId,
        threadId: fixture.threadId,
        agentId: fixture.agentId
    )
    let removals = try await [first, second]

    #expect(Set(removals.map(\.undoToken)).count == 1)
    #expect(removals.filter { $0.ok == nil }.count == 1)
    #expect(fixture.accounts.messagesAndThreadsStore.threadFollowerRemovals.count == 1)
}

@Test func threadFollowerRestoreConsumesEachTokenOnce() throws {
    let fixture = makeMessageSendFixture()
    let tokens = Mutex(0)
    let service = makeService(fixture.accounts) {
        let next = tokens.withLock { value -> Int in
            value += 1
            return value
        }
        return "undo-\(next)"
    }
    let removal = try service.removeThreadFollower(
        authorization: fixture.memberAuthorization,
        serverId: fixture.serverId,
        threadId: fixture.threadId,
        agentId: fixture.agentId
    )

    let restored = try service.restoreThreadFollower(
        authorization: fixture.memberAuthorization,
        serverId: fixture.serverId,
        threadId: fixture.threadId,
        agentId: fixture.agentId,
        undoToken: removal.undoToken
    )
    #expect(restored.jsonBody.render() == """
    {"ok":true,"restored":true}
    """)
    #expect(fixture.accounts.oauth.channelAgentIds(channelId: fixture.threadId).contains(fixture.agentId))

    let again = try service.restoreThreadFollower(
        authorization: fixture.memberAuthorization,
        serverId: fixture.serverId,
        threadId: fixture.threadId,
        agentId: fixture.agentId,
        undoToken: removal.undoToken
    )
    #expect(again.jsonBody.render() == """
    {"ok":true,"restored":false}
    """)

    // A live token issued for another agent never restores this one.
    let otherRemoval = try service.removeThreadFollower(
        authorization: fixture.memberAuthorization,
        serverId: fixture.serverId,
        threadId: fixture.threadId,
        agentId: "22222222-2222-4222-8222-000001108001"
    )
    let foreign = try service.restoreThreadFollower(
        authorization: fixture.memberAuthorization,
        serverId: fixture.serverId,
        threadId: fixture.threadId,
        agentId: fixture.agentId,
        undoToken: otherRemoval.undoToken
    )
    #expect(foreign.restored == false)
}

@Test func concurrentThreadFollowerRestoresConsumeTheTokenOnce() async throws {
    let fixture = makeMessageSendFixture()
    let service = makeService(fixture.accounts)
    let removal = try service.removeThreadFollower(
        authorization: fixture.memberAuthorization,
        serverId: fixture.serverId,
        threadId: fixture.threadId,
        agentId: fixture.agentId
    )

    async let first = service.restoreThreadFollower(
        authorization: fixture.memberAuthorization,
        serverId: fixture.serverId,
        threadId: fixture.threadId,
        agentId: fixture.agentId,
        undoToken: removal.undoToken
    )
    async let second = service.restoreThreadFollower(
        authorization: fixture.memberAuthorization,
        serverId: fixture.serverId,
        threadId: fixture.threadId,
        agentId: fixture.agentId,
        undoToken: removal.undoToken
    )
    let restores = try await [first, second]

    #expect(restores.filter(\.restored).count == 1)
    #expect(fixture.accounts.messagesAndThreadsStore.threadFollowerRemovals.isEmpty)
    #expect(fixture.accounts.messagesAndThreadsStore.staleThreadFollowerUndoTokens == Set([removal.undoToken]))
}

@Test func threadFollowerRoutesKeepTheLegacyRefusalOrder() throws {
    let fixture = makeMessageSendFixture()
    let service = makeService(fixture.accounts)

    func refusal(
        _ call: () throws -> ThreadFollowerRemovalResponse
    ) -> MessageSendError? {
        do {
            _ = try call()
            return nil
        } catch let error as MessageSendError {
            return error
        } catch {
            return nil
        }
    }

    #expect(refusal {
        try service.removeThreadFollower(
            authorization: nil,
            serverId: fixture.serverId,
            threadId: fixture.threadId,
            agentId: fixture.agentId
        )
    } == .unauthorized)
    #expect(refusal {
        try service.removeThreadFollower(
            authorization: fixture.ownerAuthorization,
            serverId: "33333333-3333-4333-8333-000001199999",
            threadId: fixture.threadId,
            agentId: fixture.agentId
        )
    } == .notServerMember)
    #expect(refusal {
        try service.removeThreadFollower(
            authorization: fixture.memberAuthorization,
            serverId: fixture.serverId,
            threadId: "44444444-4444-4444-8444-000001108001",
            agentId: fixture.agentId
        )
    } == .threadNotFound)
    // The viewer is a plain member and did not send the parent message.
    #expect(refusal {
        try service.removeThreadFollower(
            authorization: fixture.outsiderAuthorization,
            serverId: fixture.serverId,
            threadId: fixture.threadId,
            agentId: fixture.agentId
        )
    } == .forbidden)
    #expect(MessageSendError.forbidden.publishedErrorBody.render() == """
    {"error":"Forbidden"}
    """)
    #expect(MessageSendError.threadNotFound.publishedErrorBody.render() == """
    {"error":"Thread not found"}
    """)
}

// MARK: - Migration receipt DM

@Test func migrationReceiptDmIsIdempotentAndWritesOneSystemNotice() throws {
    let fixture = makeMessageSendFixture()
    let service = makeService(fixture.accounts)
    let before = fixture.accounts.messagesAndThreadsStore.humanMessageRows.count

    let first = service.createMigrationReceiptDm(
        agentId: fixture.agentId,
        serverId: fixture.serverId,
        supportRef: "REF-1"
    )
    let second = service.createMigrationReceiptDm(
        agentId: fixture.agentId,
        serverId: fixture.serverId,
        supportRef: "REF-1"
    )

    #expect(first != nil)
    #expect(first == second)
    let channel = try #require(first.flatMap { fixture.accounts.serversAndChannelsStore.postableChannel(id: $0) })
    #expect(channel.kind == "dm")
    #expect(channel.name == "migration-receipt-REF-1")
    #expect(channel.memberIds == [fixture.agentId])
    #expect(fixture.accounts.oauth.channelAgentIds(channelId: first ?? "").contains(fixture.agentId))
    let rows = fixture.accounts.messagesAndThreadsStore.humanMessageRows.filter { $0.channelId == first }
    #expect(rows.count == 1)
    #expect(rows.first?.senderId == "system")
    #expect(rows.first?.messageType == "system")
    #expect(rows.first?.content.contains("migration REF-1") == true)
    #expect(fixture.accounts.messagesAndThreadsStore.humanMessageRows.count == before + 1)
}


@Test func threadFollowerUndoTransitionsTheRealFollowAndRejectsSupersededTokens() throws {
    let fixture = makeMessageSendFixture()
    let tokens = Mutex(0)
    let service = makeService(fixture.accounts) {
        let next = tokens.withLock { value -> Int in value += 1; return value }
        return "canonical-undo-\(next)"
    }
    let messages = fixture.accounts.messagesAndThreadsStore
    let key = "\(fixture.serverId)\n\(fixture.agentId)\n\(fixture.threadId)"
    messages.applyThreadFollow(serverId: fixture.serverId, userId: fixture.agentId,
        threadChannelId: fixture.threadId, parentMessageId: fixture.parentMessageId, follow: true, now: fixedNow)
    func remove() throws -> ThreadFollowerRemovalResponse {
        try service.removeThreadFollower(authorization: fixture.memberAuthorization, serverId: fixture.serverId,
            threadId: fixture.threadId, agentId: fixture.agentId)
    }
    func restore(_ token: String) throws -> ThreadFollowerRestoreResponse {
        try service.restoreThreadFollower(authorization: fixture.memberAuthorization, serverId: fixture.serverId,
            threadId: fixture.threadId, agentId: fixture.agentId, undoToken: token)
    }
    let first = try remove()
    #expect(!messages.threadFollowSnapshot().follows.contains(key))
    #expect(messages.threadFollowSnapshot().unfollows.contains(key))
    #expect(try remove().undoToken == first.undoToken)
    #expect(try restore(first.undoToken).restored == true)
    #expect(messages.threadFollowSnapshot().follows.contains(key))
    #expect(!messages.threadFollowSnapshot().unfollows.contains(key))
    #expect(try restore(first.undoToken).restored == false)
    let second = try remove()
    #expect(second.undoToken != first.undoToken)
    messages.applyThreadReplyFollows(serverId: fixture.serverId, threadChannelId: fixture.threadId,
        parentMessageId: fixture.parentMessageId, senderId: fixture.memberId,
        mentioned: [ThreadMentionFollowTarget(userId: fixture.agentId, isParentMember: true)])
    #expect(messages.threadFollowSnapshot().follows.contains(key))
    #expect(!messages.threadFollowSnapshot().unfollows.contains(key))
    #expect(try restore(second.undoToken).restored == false)
    let third = try remove()
    #expect(third.undoToken != second.undoToken)
    #expect(try restore(second.undoToken).restored == false)
    #expect(!messages.threadFollowSnapshot().follows.contains(key))
    #expect(messages.threadFollowSnapshot().unfollows.contains(key))
    #expect(try restore(third.undoToken).restored == true)
    #expect(messages.threadFollowSnapshot().follows.contains(key))
}

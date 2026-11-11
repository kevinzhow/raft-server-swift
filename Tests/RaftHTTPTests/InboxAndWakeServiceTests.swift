import Foundation
import Testing
import TestSupport
@testable import RaftHTTP

/// The inbox service owns its four published replies and takes every
/// cross-domain decision through `InboxAndWakeDependencies`. The HTTP tests lock
/// the routes; these tests lock the service boundary: the exact bytes it renders
/// without an `Application`, and the typed refusals it throws.

private let serviceOwnerId = "11111111-1111-4111-8111-111111180001"
private let servicePeerId = "11111111-1111-4111-8111-111111180002"
private let serviceServerId = "33333333-3333-4333-8333-333333180001"
private let serviceChannelId = "44444444-4444-4444-8444-444444180001"
private let serviceMessageId = "66666666-6666-4666-8666-666666180001"
private let servicePrivateChannelId = "44444444-4444-4444-8444-444444180002"

private func makeInboxFixture() -> EmailLoginDirectory {
    let accounts = EmailLoginDirectory()
    accounts.addAccount(id: serviceOwnerId, email: "inbox-service@slock.test", password: "password123")
    accounts.markEmailVerified(userId: serviceOwnerId)
    accounts.addAccount(id: servicePeerId, email: "inbox-service-peer@slock.test", password: "password123")
    accounts.markEmailVerified(userId: servicePeerId)
    accounts.oauth.addOwnedServer(id: serviceServerId, slug: "inbox-service", name: "Inbox Service", ownerId: serviceOwnerId)
    accounts.addPostableChannel(
        serverId: serviceServerId,
        channelId: serviceChannelId,
        memberId: serviceOwnerId,
        name: "inbox-service"
    )
    accounts.addPostableChannel(
        serverId: serviceServerId,
        channelId: servicePrivateChannelId,
        memberId: serviceOwnerId,
        kind: "private",
        name: "inbox-service-private"
    )
    accounts.insertHumanMessage(
        id: serviceMessageId,
        channelId: serviceChannelId,
        senderId: serviceOwnerId,
        content: "unit page"
    )
    accounts.setMessageAttachmentIdsForTesting(messageId: serviceMessageId, attachmentIds: ["att-9"])
    accounts.addMessageMention(messageId: serviceMessageId, targetType: "user", targetId: servicePeerId)
    return accounts
}

private func makeInboxService(
    _ accounts: EmailLoginDirectory,
    authorize: @escaping @Sendable (String?) -> InboxAuthorization = { _ in .user(serviceOwnerId) },
    isEmailVerified: @escaping @Sendable (String) -> Bool = { _ in true },
    attachmentCommentsEnabled: @escaping @Sendable (String, String?) -> Bool = { _, _ in false },
    forwardMetadata: @escaping @Sendable (String, String, String?) -> OrderedJSON? = { _, _, _ in nil }
) -> InboxAndWakeService {
    var dependencies = InboxAndWakeDependencies(
        auth: accounts.authCore,
        profiles: accounts.authProfileStore,
        channelProbeAccess: accounts.agentsLifecycle.channelProbeAccess,
        guestCanSeeScope: accounts.agentsLifecycle.guestCanSeeScope,
        search: accounts.searchMentions,
        projection: accounts.messageReadProjection,
        cards: accounts.actionCardMetadata
    )
    dependencies.authorize = authorize
    dependencies.isEmailVerified = isEmailVerified
    dependencies.attachmentCommentsEnabled = attachmentCommentsEnabled
    dependencies.forwardMetadata = forwardMetadata
    dependencies.actionCardMetadata = { _ in nil }
    return InboxAndWakeService(
        messages: accounts.messagesAndThreadsStore,
        channels: accounts.serversAndChannelsStore,
        oauth: accounts.oauth,
        flags: accounts.agentsRuntimeStore,
        dependencies: dependencies
    )
}

@Test func inboxChannelPageRendersItsPublishedBytesWithoutAnApplication() throws {
    let accounts = makeInboxFixture()
    let service = makeInboxService(accounts)

    let page = try service.listChannelMessages(
        channelId: serviceChannelId,
        authorization: "Bearer any",
        serverId: serviceServerId
    )

    let persisted = try #require(accounts.messagesAndThreadsStore.humanMessageRows.first { $0.id == serviceMessageId })
    let createdAt = DateText.isoString(persisted.createdAt)
    #expect(page.jsonBody.render() == """
    {"messages":[{"id":"\(serviceMessageId)","seq":1,"senderId":"\(serviceOwnerId)","senderType":"user","senderMembershipStatus":"active","messageType":"chat","content":"unit page","createdAt":"\(createdAt)","attachments":[{"id":"att-9","commentCount":0}],"reactions":[],"mentions":[{"type":"user","id":"\(servicePeerId)","name":""}],"channelId":"\(serviceChannelId)","senderAvatarUrl":null,"randomId":null,"threadId":null,"senderName":"inbox-service","senderHandle":"inbox-service","senderDisplayName":"inbox-service","conversationContext":{"channelType":"channel"},"taskStatus":null,"taskNumber":null,"taskAssigneeType":null,"taskAssigneeId":null,"taskClaimedAt":null,"taskCompletedAt":null}],"historyLimited":false,"messageWindow":{"schemaVersion":1,"domain":"receiver_visible_messages_v1","serverId":"\(serviceServerId)","receiverKind":"user","receiverId":"\(serviceOwnerId)","scopeId":"\(serviceChannelId)","coveredFromSeq":1,"coveredAfterSeq":0,"coveredThroughSeq":1,"remoteHighWaterSeq":1,"hasGap":false,"hasNewer":false,"completeThroughLatest":true},"threadSummariesByParentMessageId":{}}
    """)

    let sync = try service.syncChannelMessages(
        channelId: serviceChannelId,
        sinceSeq: "0",
        authorization: "Bearer any",
        serverId: serviceServerId
    )
    #expect(sync.jsonBody.render() == """
    [{"id":"\(serviceMessageId)","channelId":"\(serviceChannelId)","seq":1,"content":"unit page","attachments":[{"id":"att-9","commentCount":0}],"senderId":"\(serviceOwnerId)","senderType":"user","senderAvatarUrl":null,"senderMembershipStatus":"active","messageType":"chat","createdAt":"\(createdAt)","randomId":null,"threadId":null,"reactions":[],"mentions":[{"type":"user","id":"\(servicePeerId)","name":""}],"senderName":"inbox-service","senderHandle":"inbox-service","senderDisplayName":"inbox-service","conversationContext":{"channelType":"channel"},"taskStatus":null,"taskNumber":null,"taskAssigneeType":null,"taskAssigneeId":null,"taskClaimedAt":null,"taskCompletedAt":null}]
    """)
}

@Test func inboxServiceThrowsItsTypedRefusals() throws {
    let accounts = makeInboxFixture()

    // The leaf refusals require a real active actor/server membership first.
    accounts.oauth.addMember(serverId: serviceServerId, userId: servicePeerId, role: "member")
    let admitted = makeInboxService(accounts)
    #expect(throws: InboxAndWakeError.invalidChannelId) {
        try admitted.syncChannelMessages(
            channelId: "not-a-uuid",
            sinceSeq: "0",
            authorization: "Bearer any",
            serverId: serviceServerId
        )
    }
    #expect(throws: InboxAndWakeError.invalidSyncCursor) {
        try admitted.syncChannelMessages(
            channelId: serviceChannelId,
            sinceSeq: "soon",
            authorization: "Bearer any",
            serverId: serviceServerId
        )
    }
    // Shared admission precedes malformed channel/cursor leaf validation.
    let anonymous = makeInboxService(accounts, authorize: { _ in .missingAuthorization })
    for (channelId, cursor) in [("not-a-uuid", "0"), (serviceChannelId, "soon")] {
        #expect(throws: InboxAndWakeError.missingAuthorization) {
            try anonymous.syncChannelMessages(channelId: channelId, sinceSeq: cursor,
                authorization: nil, serverId: serviceServerId)
        }
    }
    #expect(throws: InboxAndWakeError.missingAuthorization) {
        try anonymous.syncChannelMessages(
            channelId: serviceChannelId,
            sinceSeq: "0",
            authorization: nil,
            serverId: serviceServerId
        )
    }

    let revoked = makeInboxService(accounts, authorize: { _ in .invalidAccessToken })
    #expect(throws: InboxAndWakeError.invalidAccessToken) {
        try revoked.syncChannelMessages(
            channelId: serviceChannelId,
            sinceSeq: "0",
            authorization: "Bearer revoked",
            serverId: serviceServerId
        )
    }

    #expect(throws: InboxAndWakeError.invalidAccessToken) {
        try revoked.syncChannelMessages(channelId: "not-a-uuid", sinceSeq: "soon",
            authorization: "Bearer missing", serverId: serviceServerId)
    }

    let unverified = makeInboxService(accounts, isEmailVerified: { _ in false })
    #expect(throws: InboxAndWakeError.emailVerificationRequired) {
        try unverified.syncChannelMessages(
            channelId: serviceChannelId,
            sinceSeq: "0",
            authorization: "Bearer any",
            serverId: serviceServerId
        )
    }

    // Current membership is not a denial witness. A retained cursor at zero is.
    let residueChannelId = UUID().uuidString.lowercased()
    accounts.addPostableChannel(serverId: serviceServerId, channelId: residueChannelId,
        memberId: serviceOwnerId, kind: "private", name: "prior-read-private")
    accounts.oauth.addChannelHuman(channelId: residueChannelId, userId: serviceOwnerId)
    accounts.oauth.setChannelReadCursor(channelId: residueChannelId, userId: servicePeerId, seq: 0)
    let residue = makeInboxService(accounts, authorize: { _ in .user(servicePeerId) })
    #expect(throws: InboxAndWakeError.channelSyncForbidden) {
        try residue.syncChannelMessages(
            channelId: residueChannelId,
            sinceSeq: "0",
            authorization: "Bearer peer",
            serverId: serviceServerId
        )
    }

    // The author-only diagnostics cloak a message the caller did not write.
    let peer = makeInboxService(accounts, authorize: { _ in .user(servicePeerId) })
    #expect(throws: InboxAndWakeError.notJoinable) {
        try peer.mentionDeliveries(
            messageId: serviceMessageId,
            authorization: "Bearer peer",
            serverId: serviceServerId
        )
    }

    // doneInbox now shares the same typed authentication admission.
    #expect(throws: InboxAndWakeError.missingAuthorization) {
        try makeInboxService(accounts, authorize: { _ in .missingAuthorization })
            .doneInbox(authorization: nil, serverId: serviceServerId)
    }

    #expect(throws: InboxAndWakeError.channelNotVisible) {
        try makeInboxService(accounts, authorize: { _ in .user(servicePeerId) })
            .syncChannelMessages(
                channelId: servicePrivateChannelId,
                sinceSeq: "0",
                authorization: "Bearer peer",
                serverId: serviceServerId
            )
    }
}

@Test func inboxRefusalBodiesKeepThePublishedOrder() {
    #expect(InboxAndWakeError.invalidMessagePageCursor.status == 400)
    #expect(InboxAndWakeError.invalidMessagePageCursor.publishedErrorBody.render()
        == #"{"error":"Invalid message page cursor","code":"invalid_message_page_cursor"}"#)
    #expect(InboxAndWakeError.missingAuthorization.publishedErrorBody.render()
        == #"{"error":"Missing or invalid Authorization header","code":"auth_required"}"#)
    #expect(InboxAndWakeError.invalidAccessToken.publishedErrorBody.render()
        == #"{"error":"Invalid or expired token","code":"auth_required"}"#)
    #expect(InboxAndWakeError.notJoinable.status == 404)
    #expect(InboxAndWakeError.notJoinable.publishedErrorBody.render() == #"{"status":"NOT_JOINABLE"}"#)
    #expect(InboxAndWakeError.unauthorized.publishedErrorBody.render() == #"{"error":"Unauthorized"}"#)
}

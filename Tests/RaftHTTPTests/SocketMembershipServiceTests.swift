import Foundation
import TestSupport
import Testing

@testable import RaftHTTP

/// Locks the typed `SocketMembershipService` surface: the `sync:resume` body
/// must keep the upstream member order and `jsonString` escaping even though
/// the service now returns a `Codable` DTO, and membership revocation must
/// cascade over both channel and thread-follow rows.
@Test func syncResumeBodyKeepsUpstreamMemberOrderAndEscaping() throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111130001"
    let serverId = "33333333-3333-4333-8333-333333350001"
    accounts.addAccount(id: ownerId, email: "socketmem-unit@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "socketmem-unit", name: "Socket Membership Unit", ownerId: ownerId)
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "general", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: "general")
    _ = accounts.addHumanMessageForTesting(
        channelId: channelId,
        senderId: ownerId,
        content: "before"
    )
    let messageId = accounts.addHumanMessageForTesting(
        channelId: channelId,
        senderId: ownerId,
        content: "a/b \"q\""
    )

    let body = try #require(accounts.socketMembership.syncMessages(
        serverId: serverId,
        userId: ownerId,
        lastSeq: 1,
        limit: 50
    )?.jsonBody())

    #expect(body == #"{"messages":[{"id":"\#(messageId)","channelId":"\#(channelId)","seq":2,"content":"a/b \"q\"","attachments":[]}],"currentSeq":2,"hasMore":false}"#)
}

@Test func revokeServerMembershipDropsChannelMembershipAndPrivateParentFollows() throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111130002"
    let memberId = "11111111-1111-4111-8111-111111130003"
    let serverId = "33333333-3333-4333-8333-333333350002"
    for (id, email) in [
        (ownerId, "socketmem-revoke-owner@slock.test"),
        (memberId, "socketmem-revoke-member@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "socketmem-revoke", name: "Socket Membership Revoke", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "private", creatorUserId: ownerId, type: "private")
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, kind: "private", name: "private")
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: memberId, kind: "private")
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
    accounts.oauth.addChannelHuman(channelId: channelId, userId: memberId)
    let parent = accounts.addHumanMessageForTesting(channelId: channelId, senderId: ownerId, content: "thread parent")
    let threadId = UUID().uuidString.lowercased()
    accounts.addThreadChannel(
        serverId: serverId,
        threadChannelId: threadId,
        parentChannelId: channelId,
        parentMessageId: parent,
        memberId: memberId
    )
    accounts.followThreadForTesting(
        serverId: serverId,
        userId: memberId,
        threadChannelId: threadId,
        parentMessageId: parent
    )

    accounts.socketMembership.revokeServerMembershipResources(serverId: serverId, userId: memberId)

    #expect(accounts.postableChannels[channelId]?.memberIds.contains(memberId) == false)
    #expect(accounts.postableChannels[threadId]?.memberIds.contains(memberId) == false)
    #expect(accounts.threadFollows["\(serverId)\n\(memberId)\n\(threadId)"] == nil)
    #expect(accounts.oauth.channelHumanIds(channelId: channelId).contains(memberId) == false)
}

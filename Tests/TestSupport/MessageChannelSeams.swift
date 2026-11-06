import Foundation
@testable import RaftHTTP

extension EmailLoginDirectory {
    /// Records a channel the owner can post in. Resource-reference checks run
    /// only after this membership is visible.
    public func addPostableChannel(
        serverId: String,
        channelId: String,
        memberId: String,
        kind: String = "channel",
        parentChannelId: String? = nil,
        parentMessageId: String? = nil,
        name: String? = nil
    ) {
        serversAndChannelsStore.addPostableChannel(
            serverId: serverId,
            channelId: channelId,
            memberId: memberId,
            kind: kind,
            parentChannelId: parentChannelId,
            parentMessageId: parentMessageId,
            name: name
        )
    }

    /// Server role used by the hidden human directory. Only `member` is hidden
    /// on #all.
    public func setServerMemberRole(serverId: String, userId: String, role: String) {
        serversAndChannelsStore.setServerMemberRole(serverId: serverId, userId: userId, role: role)
    }

    public func setHideHumansFromMembers(serverId: String, hidden: Bool) {
        serversAndChannelsStore.setHideHumansFromMembers(serverId: serverId, hidden: hidden)
    }

    /// Links a server's local joint channel to the canonical channel that
    /// stores the messages.
    public func addJointChannelProjection(localChannelId: String, canonicalChannelId: String, serverId: String) {
        serversAndChannelsStore.addJointChannelProjection(
            localChannelId: localChannelId,
            canonicalChannelId: canonicalChannelId,
            serverId: serverId
        )
    }

    /// A thread whose messages hang off one parent message. Context short links
    /// on the parent channel can land here.
    public func addThreadChannel(
        serverId: String,
        threadChannelId: String,
        parentChannelId: String,
        parentMessageId: String,
        memberId: String
    ) {
        serversAndChannelsStore.addThreadChannel(
            serverId: serverId,
            threadChannelId: threadChannelId,
            parentChannelId: parentChannelId,
            parentMessageId: parentMessageId,
            memberId: memberId
        )
    }

    /// A user-to-user DM. Only the two participants may be notified by a
    /// mention.
    public func addDirectMessage(serverId: String, channelId: String, participantIds: [String], agentId: String? = nil) {
        serversAndChannelsStore.addDirectMessage(
            serverId: serverId,
            channelId: channelId,
            participantIds: participantIds,
            agentId: agentId
        )
    }
}

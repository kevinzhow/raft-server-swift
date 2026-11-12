import Foundation

/// Full regular-channel create envelope from channels.ts:1033-1067. A fresh
/// public/private channel has no archive actors or joint projection; those
/// absent birth facts remain explicit nulls rather than omitted fields.
public struct RegularChannelCreatedResponse: JSONBodyConvertible, Sendable, Equatable {
    let channel: ChannelDetailResponse
    let guestVisible: Bool
    let guestJoinable: Bool
    let parentMessageId: String?
    let parentChannelId: String?
    let archivedAt: String?
    let deletedAt: String?
    let activityMuted: Bool
    let muteFromSeq: Int?
    let prefsVersion: Int

    public var jsonBody: OrderedJSON {
        var fields = [
            OrderedJSONField("id", channel.id),
            OrderedJSONField("serverId", channel.serverId),
            OrderedJSONField("name", channel.name),
            OrderedJSONField("description", optional: channel.description),
            OrderedJSONField("type", channel.type),
            OrderedJSONField("guestVisible", guestVisible),
            OrderedJSONField("guestJoinable", guestJoinable),
            OrderedJSONField("parentMessageId", optional: parentMessageId),
            OrderedJSONField("parentChannelId", optional: parentChannelId),
            OrderedJSONField("createdAt", optional: channel.createdAt),
            OrderedJSONField("archivedAt", optional: archivedAt),
            OrderedJSONField("archivedByUserId", .null),
            OrderedJSONField("archivedByAgentId", .null),
            OrderedJSONField("deletedAt", optional: deletedAt),
            OrderedJSONField("joined", channel.joined),
            OrderedJSONField("jointChannelId", .null),
            OrderedJSONField("jointRole", .null),
            OrderedJSONField("jointPeerServerId", .null),
            OrderedJSONField("jointPeerServerName", .null),
            OrderedJSONField("jointPeerServerSlug", .null),
            OrderedJSONField("jointPeerStatus", .null),
            OrderedJSONField("jointServers", .array([])),
            OrderedJSONField("jointPendingInvites", .array([])),
            OrderedJSONField("jointBillingLocked", .null),
            OrderedJSONField("channelRole", channel.channelRole),
            OrderedJSONField("channelAdminBasis", optional: channel.channelAdminBasis),
            OrderedJSONField("channelCapabilities", channel.capabilities.managementJSON),
            OrderedJSONField("channelAuthorityRevision", channel.channelAuthorityRevision),
            OrderedJSONField("activityMuted", activityMuted),
            OrderedJSONField("muteFromSeq", optional: muteFromSeq),
            OrderedJSONField("prefsVersion", prefsVersion),
            OrderedJSONField("maxReadSeq", channel.maxReadSeq),
            OrderedJSONField("readStateVersion", channel.readStateVersion),
            OrderedJSONField("readState", channel.readState.json),
        ]
        fields += channel.peerReadState?.jsonFields ?? []
        fields += [
            OrderedJSONField("activityMuteSupported", channel.activityMuteSupported),
            OrderedJSONField("jointInvites", .array([])),
            OrderedJSONField("jointInvite", .null),
        ]
        return .object(fields)
    }
}

extension ChannelDetailResponse.PeerReadState {
    /// Shared peer hydrate envelope for detail and create responses.
    var jsonFields: [OrderedJSONField] {
        switch self {
        case .summary(let peerCount, let buckets):
            return [OrderedJSONField("peerReadSummary", .object([
                OrderedJSONField("peerCount", peerCount),
                OrderedJSONField("readCountAtSeq", .array(buckets.map {
                    .object([OrderedJSONField("seq", $0.seq), OrderedJSONField("count", $0.count)])
                })),
            ]))]
        case .states(let peers):
            return [OrderedJSONField("peerReadStates", .array(peers.map {
                .object([
                    OrderedJSONField("peerKind", "agent"),
                    OrderedJSONField("peerId", $0.peerId),
                    OrderedJSONField("maxReadSeq", $0.maxReadSeq),
                ])
            }))]
        }
    }
}

extension ChannelDetailResponse.Capabilities {
    /// CHANNEL_MANAGEMENT_CAPABILITIES order of the create operation.
    var managementJSON: OrderedJSON {
        .object([
            OrderedJSONField("editChannelMetadata", editChannelMetadata),
            OrderedJSONField("archiveChannels", archiveChannels),
            OrderedJSONField("deleteChannels", deleteChannels),
            OrderedJSONField("changeChannelVisibility", changeChannelVisibility),
            OrderedJSONField("manageGuestAccess", manageGuestAccess),
            OrderedJSONField("federateChannels", federateChannels),
            OrderedJSONField("addChannelMembers", addChannelMembers),
            OrderedJSONField("removeChannelMembers", removeChannelMembers),
            OrderedJSONField("changeChannelMemberRoles", changeChannelMemberRoles),
        ])
    }
}

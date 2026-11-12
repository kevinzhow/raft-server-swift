import Foundation

/// Object-aware human channel authority from channelActorPermissions.ts and
/// shared/channelPermissions.ts. Membership is typed; a posting UUID is not a
/// human membership when the canonical channel exists.
struct HumanChannelAuthorization: Sendable {
    let type: String
    let name: String
    let serverRole: String
    let joined: Bool
    let channelRole: String?
    let authorityRevision: Int?
    let archived: Bool
    let deleted: Bool

    private var inherited: Bool { serverRole == "owner" || serverRole == "admin" }
    private var supportsRoles: Bool { ["channel", "private", "joint"].contains(type) && name != "all" }
    private var localAdmin: Bool {
        joined && supportsRoles && channelRole == "admin" && ["owner", "admin", "member"].contains(serverRole)
    }
    var basis: String? {
        inherited && localAdmin ? "both" : inherited ? "server_role" : localAdmin ? "channel_role" : nil
    }

    func allows(_ capability: String) -> Bool {
        if capability == "addChannelMembers" {
            guard supportsRoles, !archived, !deleted else { return false }
            return inherited || (serverRole == "member" && joined)
        }
        // Channel management context is distinct from parent-derived thread/DM
        // read access. These objects do not acquire channel-management powers.
        let canAccess = type == "channel" || (["private", "joint"].contains(type) && joined)
        guard canAccess else { return false }
        if ServerRoleCapabilities.allows(capability, role: serverRole) { return true }
        let local: Set<String> = type == "joint"
            ? ["editChannelMetadata", "changeChannelMemberRoles"]
            : ["editChannelMetadata", "archiveChannels", "removeChannelMembers", "changeChannelMemberRoles", "manageGuestAccess"]
        return localAdmin && local.contains(capability)
    }

    var capabilities: ChannelDetailResponse.Capabilities {
        .init(
            editChannelMetadata: allows("editChannelMetadata"), archiveChannels: allows("archiveChannels"),
            addChannelMembers: allows("addChannelMembers"), removeChannelMembers: allows("removeChannelMembers"),
            changeChannelMemberRoles: allows("changeChannelMemberRoles"), manageGuestAccess: allows("manageGuestAccess"),
            deleteChannels: allows("deleteChannels"), changeChannelVisibility: allows("changeChannelVisibility"),
            federateChannels: allows("federateChannels")
        )
    }
}

struct HumanChannelAuthorizationQuery: Sendable {
    let oauth: OAuthLedger

    func resolve(channelId: String, serverId: String, userId: String,
                 snapshot: ServersAndChannelsStore.State) -> HumanChannelAuthorization? {
        guard let channel = oauth.channelInfo(id: channelId), channel.serverId == serverId,
              let role = oauth.memberRole(serverId: serverId, userId: userId) else { return nil }
        let joined = oauth.isChannelParticipant(channelId: channelId, userId: userId)
        return HumanChannelAuthorization(
            type: oauth.channelType(id: channelId) ?? "channel", name: channel.name, serverRole: role, joined: joined,
            channelRole: joined ? snapshot.channelHumanRoles["\(channelId)\n\(userId)"] ?? "member" : nil,
            authorityRevision: joined ? snapshot.channelAuthorityRevisions[channelId] ?? 1 : nil,
            archived: oauth.channelArchivedAt(id: channelId) != nil || snapshot.postableChannels[channelId]?.archived == true,
            deleted: snapshot.postableChannels[channelId]?.deletedAt != nil
        )
    }
}

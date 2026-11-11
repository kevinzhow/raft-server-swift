import Foundation

/// Domain failure for announcements, avatars, channel unread and notification
/// settings, the channel create/patch routes, the agent user lookups and the
/// app-installation reminder write.
///
/// Every case is one published refusal. Most use the default
/// `{"error": …[, "code": …]}` body; the agent capability refusals publish a
/// third key and the channel-name collision publishes a flag, so those supply
/// `errorBody`. The two external-avatar refusals are plain text.
public enum ManagedMCPOAuthError: DomainError, Equatable {
    case unauthorized
    case notAMember
    case forbidden
    case channelNotFound
    case channelArchived
    // Announcements.
    case invalidAnnouncementCursor
    case announcementServerIdRepeated
    case announcementServerIdInvalid
    case announcementNotFound
    case announcementImageNotFound
    case announcementImageStorageUnavailable
    // External avatars (plain text bodies).
    case avatarNotFound
    case avatarStorageUnavailable
    // Notification settings.
    case threadsUseFollow
    case activityMutedNotBoolean
    // Channel create/patch.
    case invalidChannelUpdate
    case invalidChannelVisibility
    case allChannelVisibilityManaged
    case channelMembershipRequired
    case jointChannelAdminLimited
    case invalidChannelName
    case invalidChannel
    case targetServerSlugRequired
    case invitedPersonMustBelong
    case channelNameExists(name: String, canUnarchive: Bool)
    // Agent user lookups.
    case agentAuthRequired
    case capabilityNotAuthorized
    case missingScope(String)
    case invalidPageWindow([AuthRequestIssue])
    case userNotFound
    case userNotFoundBadRequest
    // App-installation reminders.
    case invalidInstallationCredential
    case reminderWriteNotAuthorized
    case invalidAgentReminderRequest
    case agentNotFound
    case reminderSurfaceUnavailable

    public var status: UInt {
        switch self {
        case .unauthorized, .agentAuthRequired, .invalidInstallationCredential:
            401
        case .notAMember, .forbidden, .allChannelVisibilityManaged, .channelMembershipRequired,
             .jointChannelAdminLimited, .capabilityNotAuthorized, .missingScope,
             .reminderWriteNotAuthorized:
            403
        case .channelNotFound, .announcementNotFound, .announcementImageNotFound,
             .avatarNotFound, .userNotFound, .agentNotFound:
            404
        case .channelArchived:
            ChannelMembershipError.channelArchived.status
        case .channelNameExists:
            409
        case .reminderSurfaceUnavailable:
            500
        case .announcementImageStorageUnavailable, .avatarStorageUnavailable:
            503
        case .invalidAnnouncementCursor, .announcementServerIdRepeated, .announcementServerIdInvalid,
             .threadsUseFollow, .activityMutedNotBoolean, .invalidChannelUpdate,
             .invalidChannelVisibility, .invalidChannelName, .invalidChannel,
             .targetServerSlugRequired, .invitedPersonMustBelong, .invalidPageWindow,
             .userNotFoundBadRequest, .invalidAgentReminderRequest:
            400
        }
    }

    public var errorMessage: String {
        switch self {
        case .unauthorized: "Unauthorized"
        case .notAMember: "Not a member of this server"
        case .forbidden: "Forbidden"
        case .channelNotFound: "Channel not found"
        case .channelArchived: ChannelMembershipError.channelArchived.errorMessage
        case .invalidAnnouncementCursor: "Invalid announcement cursor"
        case .announcementServerIdRepeated: "server_id must be provided at most once"
        case .announcementServerIdInvalid: "server_id must be a valid UUID"
        case .announcementNotFound: "Announcement not found"
        case .announcementImageNotFound: "Announcement image not found"
        case .announcementImageStorageUnavailable: "Announcement image storage unavailable"
        case .avatarNotFound: "Not found"
        case .avatarStorageUnavailable: "Avatar storage is unavailable"
        case .threadsUseFollow: "Threads use follow/unfollow instead of activity mute"
        case .activityMutedNotBoolean: "activityMuted must be a boolean"
        case .invalidChannelUpdate: "Invalid channel update"
        case .invalidChannelVisibility: "Invalid channel visibility"
        case .allChannelVisibilityManaged: "Only a human can do it, from channel settings or server settings"
        case .channelMembershipRequired: "You must be a channel member"
        case .jointChannelAdminLimited: "Only a server admin can change joint visibility or archive"
        case .invalidChannelName: "Invalid channel name"
        case .invalidChannel: "Invalid channel"
        case .targetServerSlugRequired: "targetServerSlug is required"
        case .invitedPersonMustBelong: "invited person must belong to the target server"
        case .channelNameExists(let name, _): "A channel named #\(name) already exists"
        case .agentAuthRequired: "Missing or invalid Authorization header"
        case .capabilityNotAuthorized: "Agent credential is not authorized for this capability"
        case .missingScope: "missing required scope"
        case .invalidPageWindow: "Invalid agent-api userChannels query"
        case .userNotFound, .userNotFoundBadRequest: "User not found or not visible"
        case .invalidInstallationCredential: "Invalid installation credential"
        case .reminderWriteNotAuthorized: "Agent reminder write is not authorized for this app"
        case .invalidAgentReminderRequest: "Invalid agent reminder request"
        case .agentNotFound: "Agent not found"
        case .reminderSurfaceUnavailable: "reminder surface unavailable"
        }
    }

    public var errorCode: String? {
        switch self {
        case .channelArchived: ChannelMembershipError.channelArchived.errorCode
        case .allChannelVisibilityManaged: "all_channel_visibility_managed_separately"
        case .channelMembershipRequired: "channel_membership_required"
        case .jointChannelAdminLimited: "joint_channel_admin_limited"
        case .agentAuthRequired: "auth_required"
        case .capabilityNotAuthorized: "capability_not_authorized"
        case .invalidPageWindow: "agent_api_contract_invalid"
        case .userNotFound, .userNotFoundBadRequest: "user_not_found"
        default: nil
        }
    }

    public var errorBody: OrderedJSON? {
        switch self {
        case .avatarNotFound, .avatarStorageUnavailable:
            return .raw(errorMessage)
        case .invalidPageWindow(let issues):
            // Pinned `routes/internalAgentApi.ts:418-426` publishes `error`,
            // `code`, then the zod query issues.
            return .object([
                OrderedJSONField("error", errorMessage),
                OrderedJSONField("code", "agent_api_contract_invalid"),
                OrderedJSONField("issues", .array(issues.map(\.json))),
            ])
        case .channelNameExists(_, let canUnarchive):
            return .object([
                OrderedJSONField("error", errorMessage),
                OrderedJSONField("canUnarchiveArchivedChannel", canUnarchive),
            ])
        case .capabilityNotAuthorized:
            return .object([
                OrderedJSONField("error", errorMessage),
                OrderedJSONField("code", "capability_not_authorized"),
                OrderedJSONField("requiredCapability", "read"),
            ])
        case .missingScope(let scope):
            return .object([
                OrderedJSONField("error", errorMessage),
                OrderedJSONField("requiredScope", scope),
                OrderedJSONField("reason", "missing_scope"),
            ])
        case .channelArchived:
            return ChannelMembershipError.channelArchived.publishedErrorBody
        default:
            return nil
        }
    }

    public var errorHeaders: ResponseHeaders {
        switch self {
        case .avatarNotFound, .avatarStorageUnavailable:
            .exact(["Content-Type": "text/plain; charset=utf-8"])
        default:
            .standard(extra: responseHeaders)
        }
    }
}

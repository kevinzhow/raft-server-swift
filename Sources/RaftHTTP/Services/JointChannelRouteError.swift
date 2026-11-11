import Foundation

/// Refusals for the joint-channel list, resend, disconnect and invite-server
/// routes. The messages, statuses and `code` values are the ones the pinned
/// `routes/channels.ts` handlers answer; validation refusals keep the upstream
/// extra keys (`targetServerSlug`, `invitee`, `inviteeIndex`).
public enum JointChannelRouteError: DomainError, Equatable {
    case unauthorized
    case notAMember
    case channelNotFound
    case onlyJointDisconnect
    case onlyJointResend
    case onlyJointInvite
    case adminDisconnect
    case adminResend
    case adminInvite
    case noPendingInvites
    case slugRequired
    case invitedPeopleRequired
    case invitedPeopleLimit(Int)
    case targetServerInvalid(message: String, slug: String)
    case inviteeNotFound(String, String, Int)
    case inviteeNotAdmin(String, String, Int)

    public var status: UInt {
        switch self {
        case .unauthorized:
            401
        case .notAMember:
            403
        case .channelNotFound:
            404
        case .onlyJointDisconnect, .onlyJointResend, .onlyJointInvite,
             .slugRequired, .invitedPeopleRequired, .invitedPeopleLimit,
             .targetServerInvalid, .inviteeNotFound, .inviteeNotAdmin:
            400
        case .adminDisconnect, .adminResend, .adminInvite:
            403
        case .noPendingInvites:
            409
        }
    }

    public var errorMessage: String {
        switch self {
        case .unauthorized: "Unauthorized"
        case .notAMember: "Not a member of this server"
        case .channelNotFound: "Channel not found"
        case .onlyJointDisconnect: "Only joint channels can be disconnected"
        case .onlyJointResend: "Only joint channels can resend joint invites"
        case .onlyJointInvite: "Only joint channels can invite servers"
        case .adminDisconnect: "Only admins can disconnect joint channels"
        case .adminResend: "Only admins can resend joint channel invites"
        case .adminInvite: "Only admins can invite servers to joint channels"
        case .noPendingInvites: "No pending joint channel invite found"
        case .slugRequired: "Invite server slug is required"
        case .invitedPeopleRequired: "At least one invited person is required"
        case .invitedPeopleLimit(let limit):
            "A joint channel invite can include a maximum of \(limit) invited people per target server"
        case .targetServerInvalid(let message, _):
            message
        case .inviteeNotFound(let person, _, _):
            "Invited person not found in target server: \(person)"
        case .inviteeNotAdmin(let person, _, _):
            "Invited person must be a target server admin: \(person)"
        }
    }

    public var errorCode: String? {
        switch self {
        case .invitedPeopleLimit:
            "joint_invite_limit_exceeded"
        case .targetServerInvalid:
            "joint_target_server_invalid"
        case .inviteeNotFound:
            "joint_invitee_not_found"
        case .inviteeNotAdmin:
            "joint_invitee_not_admin"
        default:
            nil
        }
    }

    public var errorBody: OrderedJSON? {
        switch self {
        case .targetServerInvalid(_, let slug):
            return .object([
                OrderedJSONField("error", errorMessage),
                OrderedJSONField("code", errorCode ?? ""),
                OrderedJSONField("targetServerSlug", slug),
            ])
        case .inviteeNotFound(let person, let slug, let index),
             .inviteeNotAdmin(let person, let slug, let index):
            return .object([
                OrderedJSONField("error", errorMessage),
                OrderedJSONField("code", errorCode ?? ""),
                OrderedJSONField("targetServerSlug", slug),
                OrderedJSONField("invitee", person),
                OrderedJSONField("inviteeIndex", index),
            ])
        default:
            return nil
        }
    }
}

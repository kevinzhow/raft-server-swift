import Foundation

/// Domain failure for server membership, server deletion, sidebar order, server
/// labs and the task aggregate metrics.
///
/// Every case is one published refusal. The retired handlers built the bodies by
/// hand; `Respond.swift` now renders them from `errorMessage`, `errorCode` and
/// `errorBody`, so the bytes are unchanged. Two unrelated retirements share a
/// status and differ only in the published text (`Not a member of this server`
/// vs `Forbidden`), which is why they stay separate cases.
public enum ServerMembersAndSidebarError: DomainError, Equatable {
    /// The member routes' `PublicVisits.authRequired` refusal.
    case authRequired(bearerPresent: Bool)
    /// The sidebar/labs/metrics plain missing-session refusal.
    case unauthorized
    case notAMember
    /// The member-role refusal that names the owner even though an admin also
    /// passes the check, as the published text did.
    case onlyOwnerCanChangeRoles
    case onlyOwnerCanDeleteServer
    case forbidden
    case memberNotFound
    case invalidMemberRole
    case selfRoleChange
    case guestRoleDisabled
    case seatLimit(String)
    case lastOwner
    case serverNotFound
    case invalidSidebarOrder
    case invalidSidebarSortMode
    case invalidSidebarPanelOrder
    case sidebarSectionsConflict
    case invalidCustomSections
    case invalidSectionOrder
    case invalidSectionPlacements
    case invalidPinnedReferences
    case serverScopeForbidden
    case invalidLabsAccessRequest
    case serverLabsVersionConflict(currentVersion: Int)
    case serverLabsAccessDisabled
    case labNotFound
    case labNotOpen
    case invalidLabEnrollmentRequest
    case invalidMetricsWindow
    case invalidChannelId
    case channelNotFound

    public var status: UInt {
        switch self {
        case .authRequired, .unauthorized:
            401
        case .notAMember, .onlyOwnerCanChangeRoles, .onlyOwnerCanDeleteServer, .forbidden, .guestRoleDisabled,
             .serverScopeForbidden:
            403
        case .memberNotFound, .serverNotFound, .labNotFound, .channelNotFound:
            404
        case .invalidMemberRole, .selfRoleChange, .lastOwner, .invalidSidebarOrder,
             .invalidSidebarSortMode, .invalidSidebarPanelOrder, .invalidCustomSections,
             .invalidSectionOrder, .invalidSectionPlacements, .invalidPinnedReferences,
             .invalidLabsAccessRequest, .invalidLabEnrollmentRequest, .invalidMetricsWindow,
             .invalidChannelId:
            400
        case .seatLimit, .sidebarSectionsConflict, .serverLabsVersionConflict,
             .serverLabsAccessDisabled, .labNotOpen:
            409
        }
    }

    public var errorMessage: String {
        switch self {
        case .authRequired(let bearerPresent):
            bearerPresent
                ? "Invalid or expired token"
                : "Missing or invalid Authorization header"
        case .unauthorized:
            "Unauthorized"
        case .notAMember:
            "Not a member of this server"
        case .onlyOwnerCanChangeRoles:
            "Only the owner can change member roles"
        case .onlyOwnerCanDeleteServer:
            "Only the server owner can delete a server"
        case .forbidden:
            "Forbidden"
        case .memberNotFound:
            "Member not found"
        case .invalidMemberRole:
            "Invalid member role"
        case .selfRoleChange:
            "You cannot change your own role"
        case .guestRoleDisabled:
            "Guest role transitions are not enabled"
        case .seatLimit(let message):
            message
        case .lastOwner:
            "The last owner cannot be removed"
        case .serverNotFound:
            "Server not found"
        case .invalidSidebarOrder:
            "Invalid sidebar order"
        case .invalidSidebarSortMode:
            "Invalid sidebar sort mode"
        case .invalidSidebarPanelOrder:
            "Invalid sidebar panel order"
        case .sidebarSectionsConflict:
            "Sidebar sections changed"
        case .invalidCustomSections:
            "Invalid custom sections"
        case .invalidSectionOrder:
            "Invalid section order"
        case .invalidSectionPlacements:
            "Invalid section placements"
        case .invalidPinnedReferences:
            "Invalid sidebar pinned references"
        case .serverScopeForbidden:
            "Server scope forbidden"
        case .invalidLabsAccessRequest:
            "Invalid labs access request"
        case .serverLabsVersionConflict:
            "Server Labs version changed"
        case .serverLabsAccessDisabled:
            "Server Labs access is disabled"
        case .labNotFound:
            "Lab not found"
        case .labNotOpen:
            "Lab is not open"
        case .invalidLabEnrollmentRequest:
            "Invalid lab enrollment request"
        case .invalidMetricsWindow:
            "Invalid metrics window"
        case .invalidChannelId:
            "Invalid channelId"
        case .channelNotFound:
            "Channel not found"
        }
    }

    public var errorCode: String? {
        switch self {
        case .authRequired:
            "auth_required"
        case .seatLimit:
            "human_seat_limit_reached"
        case .sidebarSectionsConflict:
            "SIDEBAR_SECTIONS_VERSION_CONFLICT"
        case .serverScopeForbidden:
            "server_scope_forbidden"
        case .serverLabsVersionConflict:
            "server_labs_version_conflict"
        case .serverLabsAccessDisabled:
            "server_labs_access_disabled"
        case .labNotOpen:
            "lab_not_open"
        case .unauthorized, .notAMember, .onlyOwnerCanChangeRoles, .onlyOwnerCanDeleteServer, .forbidden,
             .memberNotFound, .invalidMemberRole, .selfRoleChange, .guestRoleDisabled,
             .lastOwner, .serverNotFound, .invalidSidebarOrder, .invalidSidebarSortMode,
             .invalidSidebarPanelOrder, .invalidCustomSections, .invalidSectionOrder,
             .invalidSectionPlacements, .invalidPinnedReferences, .invalidLabsAccessRequest,
             .labNotFound, .invalidLabEnrollmentRequest, .invalidMetricsWindow, .invalidChannelId,
             .channelNotFound:
            nil
        }
    }

    /// The Labs version conflict publishes `currentVersion` after `error` and
    /// `code`; the default envelope cannot add it.
    public var errorBody: OrderedJSON? {
        switch self {
        case .serverLabsVersionConflict(let currentVersion):
            .object([
                OrderedJSONField("error", errorMessage),
                OrderedJSONField("code", "server_labs_version_conflict"),
                OrderedJSONField("currentVersion", currentVersion),
            ])
        case .authRequired, .unauthorized, .notAMember, .onlyOwnerCanChangeRoles, .onlyOwnerCanDeleteServer, .forbidden,
             .memberNotFound, .invalidMemberRole, .selfRoleChange, .guestRoleDisabled,
             .lastOwner, .serverNotFound, .invalidSidebarOrder, .invalidSidebarSortMode,
             .invalidSidebarPanelOrder, .sidebarSectionsConflict, .invalidCustomSections,
             .invalidSectionOrder, .invalidSectionPlacements, .invalidPinnedReferences,
             .serverScopeForbidden, .invalidLabsAccessRequest, .serverLabsAccessDisabled,
             .labNotFound, .labNotOpen, .invalidLabEnrollmentRequest, .invalidMetricsWindow,
             .invalidChannelId, .channelNotFound, .seatLimit:
            nil
        }
    }

    /// The member routes' auth refusal kept `Cache-Control: no-store`; every
    /// other refusal uses the plain set.
    public var responseHeaders: [String: String] {
        switch self {
        case .authRequired:
            ["Cache-Control": "no-store"]
        default:
            [:]
        }
    }
}

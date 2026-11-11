import Foundation

/// The actor admitted by the pinned `requireServerMatchesParam` funnel.
public struct ServerRequestScopeActor: Sendable, Equatable {
    public var userId: String
    public var role: String
}

/// One published refusal from the router-wide server-scope funnel.
///
/// The bodies come from `middleware/auth.ts:416-470` and the guest-hidden
/// surface middleware at `routes/servers.ts:1010-1019`. They are plain
/// `{"error": …}` objects, so the default `DomainError` projection owns the
/// bytes; only the guest refusal is emitted by the second middleware.
public enum ServerRequestScopeError: DomainError, Equatable {
    /// Fail-closed branch for a route mounted without an `:id` parameter.
    case serverIdRequired
    /// A non-UUID path id names no server, before any header check.
    case serverNotFound
    case unauthorized
    case missingHeader
    case headerMismatch
    case notAMember
    case guestsCannotAccessServerManagementData

    public var status: UInt {
        switch self {
        case .serverIdRequired, .missingHeader, .headerMismatch:
            400
        case .unauthorized:
            401
        case .notAMember, .guestsCannotAccessServerManagementData:
            403
        case .serverNotFound:
            404
        }
    }

    public var errorMessage: String {
        switch self {
        case .serverIdRequired:
            "Server id is required"
        case .serverNotFound:
            "Server not found"
        case .unauthorized:
            "Unauthorized"
        case .missingHeader:
            "Missing X-Server-Id header"
        case .headerMismatch:
            "X-Server-Id must match server id in URL"
        case .notAMember:
            "Not a member of this server"
        case .guestsCannotAccessServerManagementData:
            "Guests cannot access server management data"
        }
    }
}

struct ServerRequestScopeDependencies: Sendable {
    var sessionUserId: @Sendable (String?) -> String?
    var oauth: OAuthLedger
}

/// The pre-handler `/api/servers/:id` funnel shared by every route registered
/// after `routes/servers.ts:994`.
///
/// Pinned order: `app.ts:483` mounts `/api/servers` behind `requireAuth` +
/// `requireVerified`, so authentication is already 401 before this runs. This
/// service then reproduces `requireServerMatchesParam` exactly:
///
/// 1. missing path id -> 400 `Server id is required`;
/// 2. non-UUID path id -> 404 `Server not found` before the header is read;
/// 3. missing `X-Server-Id` -> 400 `Missing X-Server-Id header`;
/// 4. mismatching header -> 400 `X-Server-Id must match server id in URL`;
/// 5. no live membership -> 403 `Not a member of this server`.
///
/// The membership read joins the live server row, so an unknown or soft-deleted
/// server refuses like a non-member. The sole exemption is a `DELETE` retry on
/// the server root by an owner of an already soft-deleted server: the deletion
/// service must be able to finish legacy partial residue. The labs sub-router
/// is mounted at `routes/servers.ts:993`, before this funnel, and keeps its own
/// scope contract.
///
/// The guest-hidden surface middleware (`routes/servers.ts:1010-1019`) runs
/// immediately after this funnel for the eight path families in that list; it
/// refuses a live guest with 403 `Guests cannot access server management data`.
public struct ServerRequestScopeService: Sendable {
    private let dependencies: ServerRequestScopeDependencies

    init(dependencies: ServerRequestScopeDependencies) {
        self.dependencies = dependencies
    }

    /// Runs the funnel and returns the admitted live member.
    ///
    /// - Parameters:
    ///   - isDeleteServerRoot: exactly `DELETE /api/servers/:id`, the only
    ///     route shape the soft-deleted-owner retry exemption covers.
    ///   - hidesGuests: the route is one of the guest-hidden surfaces, so a
    ///     live guest is refused after the membership check.
    public func enforce(
        authorization: String?,
        serverId: String,
        headerServerId: String?,
        isDeleteServerRoot: Bool,
        hidesGuests: Bool
    ) throws -> ServerRequestScopeActor {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw ServerRequestScopeError.unauthorized
        }
        switch ServerScope.validate(serverId: serverId, headerServerId: headerServerId) {
        case nil:
            break
        case .serverIdRequired:
            throw ServerRequestScopeError.serverIdRequired
        case .serverNotFound:
            throw ServerRequestScopeError.serverNotFound
        case .missingHeader:
            throw ServerRequestScopeError.missingHeader
        case .headerMismatch:
            throw ServerRequestScopeError.headerMismatch
        }
        guard let role = dependencies.oauth.memberRole(serverId: serverId, userId: userId) else {
            throw ServerRequestScopeError.notAMember
        }
        guard dependencies.oauth.serverProfile(id: serverId) != nil else {
            // The pinned query joins the live `servers` row. A soft-deleted
            // server's stale membership is only usable for an owner's DELETE
            // retry; every other shape is the same 403 as a non-member.
            if isDeleteServerRoot, role == "owner" {
                return ServerRequestScopeActor(userId: userId, role: role)
            }
            throw ServerRequestScopeError.notAMember
        }
        if hidesGuests, role == "guest" {
            throw ServerRequestScopeError.guestsCannotAccessServerManagementData
        }
        return ServerRequestScopeActor(userId: userId, role: role)
    }
}

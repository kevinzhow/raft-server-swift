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
        case .notAMember, .onlyOwnerCanChangeRoles, .forbidden, .guestRoleDisabled,
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
        case .unauthorized, .notAMember, .onlyOwnerCanChangeRoles, .forbidden,
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
        case .authRequired, .unauthorized, .notAMember, .onlyOwnerCanChangeRoles, .forbidden,
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

// MARK: - Injected dependencies

/// Every cross-domain decision the server-member surface needs.
///
/// The server/channel and task ledgers belong to their stores; the human session
/// lookup and the realtime emitter belong to the auth and realtime domains and
/// stay behind closures. `live(directory:)` wires them to the existing directory
/// entry points at the composition root.
struct ServerMembersAndSidebarDependencies: Sendable {
    var sessionUserId: @Sendable (String?) -> String?
    var emitRealtime: @Sendable (String, String, String?) -> Void
    var humanExists: @Sendable (String) -> Bool
    var oauth: OAuthLedger
    var channels: ServersAndChannelsStore
    var tasks: TasksAndRemindersStore
    var now: @Sendable () -> Date

    static func live(directory source: EmailLoginDirectory) -> ServerMembersAndSidebarDependencies {
        ServerMembersAndSidebarDependencies(
            sessionUserId: { source.sessionUserId(authorization: $0) },
            emitRealtime: { room, event, payload in
                source.emitRealtime(room, event, payload)
            },
            humanExists: { userId in
                source.authProfileStore.accounts.values.contains { $0.id == userId }
            },
            oauth: source.oauth,
            channels: source.serversAndChannelsStore,
            tasks: source.tasksAndRemindersStore,
            now: { Date() }
        )
    }
}

// MARK: - Service

/// Server member roles/removal, server deletion, the sidebar order ledger,
/// server labs and the task snapshot/period aggregates.
///
/// The service owns the orchestration and returns the published `Codable` /
/// `JSONBodyConvertible` DTOs; every refusal is a `ServerMembersAndSidebarError`.
/// It builds no HTTP reply, header set or response body. The sidebar write and
/// both labs version checks are one store critical section, so two concurrent
/// requests cannot both accept the same expected version.
public struct ServerMembersAndSidebarService: Sendable {
    private let dependencies: ServerMembersAndSidebarDependencies

    /// Production wiring.
    public init(directory: EmailLoginDirectory) {
        self.init(dependencies: .live(directory: directory))
    }

    init(dependencies: ServerMembersAndSidebarDependencies) {
        self.dependencies = dependencies
    }

    // MARK: - PATCH /api/servers/:id/members/:memberId

    /// Changes one member role.
    ///
    /// The authorization and self-demotion rules run before any write; the guest
    /// seat cap is one store decision. A changed role publishes
    /// `server:member-updated` and queues one `server.member_role_changed` event.
    public func patchServerMemberRole(
        authorization: String?,
        serverId: String,
        memberId: String,
        body: ServerMemberRolePatchRequest?
    ) throws -> ServerMemberRolePatchResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw ServerMembersAndSidebarError.authRequired(
                bearerPresent: authorization?.hasPrefix("Bearer ") == true
            )
        }
        guard let role = dependencies.oauth.memberRole(serverId: serverId, userId: userId) else {
            throw ServerMembersAndSidebarError.notAMember
        }
        guard role == "owner" || role == "admin" else {
            throw ServerMembersAndSidebarError.onlyOwnerCanChangeRoles
        }
        guard let targetRole = dependencies.oauth.memberRole(serverId: serverId, userId: memberId) else {
            throw ServerMembersAndSidebarError.memberNotFound
        }
        guard let newRole = body?.role,
              ["owner", "admin", "member", "guest"].contains(newRole)
        else {
            throw ServerMembersAndSidebarError.invalidMemberRole
        }
        if role == "admin", targetRole == "owner" || targetRole == "admin" || newRole == "owner" {
            throw ServerMembersAndSidebarError.forbidden
        }
        if memberId == userId {
            let canSelfDemoteToGuest = targetRole == "owner"
                && newRole == "guest"
                && dependencies.oauth.ownerCount(serverId: serverId) > 1
            guard canSelfDemoteToGuest else {
                throw ServerMembersAndSidebarError.selfRoleChange
            }
        }
        if newRole == "guest" {
            guard dependencies.channels.isGuestRoleEnabled(serverId: serverId) else {
                throw ServerMembersAndSidebarError.guestRoleDisabled
            }
        }
        if targetRole == "guest", newRole == "member" {
            // The seat cap and the holder count are one store critical section.
            let message = dependencies.channels.seatLimitMessage(
                serverId: serverId,
                usedSeats: { [oauth = dependencies.oauth] serverId in
                    oauth.memberIdsWithRoles(serverId: serverId).filter { $0.role != "guest" }.count
                }
            )
            if let message {
                throw ServerMembersAndSidebarError.seatLimit(message)
            }
        }
        dependencies.oauth.addMember(serverId: serverId, userId: memberId, role: newRole)
        if newRole == "guest", let allChannel = dependencies.oauth.allChannelId(serverId: serverId) {
            dependencies.oauth.removeChannelHuman(channelId: allChannel, userId: memberId)
        }
        if newRole != targetRole {
            let payload = "{\"serverId\":\(jsonString(serverId)),\"userId\":\(jsonString(memberId)),\"previousRole\":\(jsonString(targetRole)),\"role\":\(jsonString(newRole))}"
            dependencies.emitRealtime("server:\(serverId)", "server:member-updated", payload)
            dependencies.channels.appendServerMemberEvent(
                serverId: serverId,
                eventType: "server.member_role_changed",
                subjectType: "member",
                subjectId: memberId,
                provenanceJSON: "{\"actor_type\":\"human\",\"previous_role\":\(jsonString(targetRole)),\"principal_type\":\"human\",\"role\":\(jsonString(newRole)),\"source\":\"server_service\"}"
            )
        }
        return ServerMemberRolePatchResponse()
    }

    // MARK: - DELETE /api/servers/:id/members/:memberId

    /// Removes one member.
    ///
    /// The last owner cannot be removed. The member status, removed-marker and
    /// queued event are one store critical section; the channel/thread-follow
    /// cascade stays the route's existing follow-up on success.
    public func removeServerMember(
        authorization: String?,
        serverId: String,
        memberId: String
    ) throws -> OkResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw ServerMembersAndSidebarError.authRequired(
                bearerPresent: authorization?.hasPrefix("Bearer ") == true
            )
        }
        guard let role = dependencies.oauth.memberRole(serverId: serverId, userId: userId) else {
            throw ServerMembersAndSidebarError.notAMember
        }
        guard role == "owner" || role == "admin" else {
            throw ServerMembersAndSidebarError.forbidden
        }
        guard let targetRole = dependencies.oauth.memberRole(serverId: serverId, userId: memberId) else {
            throw ServerMembersAndSidebarError.memberNotFound
        }
        if targetRole == "owner" {
            guard role == "owner" else {
                throw ServerMembersAndSidebarError.forbidden
            }
            guard dependencies.oauth.ownerCount(serverId: serverId) > 1 else {
                throw ServerMembersAndSidebarError.lastOwner
            }
        }
        dependencies.oauth.removeMember(serverId: serverId, userId: memberId)
        dependencies.channels.markMemberRemoved(
            serverId: serverId,
            userId: memberId,
            provenanceJSON: "{\"actor_type\":\"human\",\"principal_type\":\"human\",\"reason\":\"removed\",\"role\":\(jsonString(targetRole)),\"source\":\"server_service\"}"
        )
        dependencies.emitRealtime(
            "server:\(serverId)",
            "server:member-removed",
            "{\"serverId\":\(jsonString(serverId)),\"userId\":\(jsonString(memberId))}"
        )
        dependencies.emitRealtime(
            "user:\(memberId)",
            "server:membership-removed",
            "{\"serverId\":\(jsonString(serverId))}"
        )
        return OkResponse()
    }

    // MARK: - DELETE /api/servers/:id

    /// Deletes a server. A second delete is the idempotent `{"ok":true}` before
    /// any authorization check, exactly as the retired handler answered.
    public func deleteServer(authorization: String?, serverId: String) throws -> OkResponse {
        guard !dependencies.channels.isServerDeleted(serverId) else {
            return OkResponse()
        }
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw ServerMembersAndSidebarError.authRequired(
                bearerPresent: authorization?.hasPrefix("Bearer ") == true
            )
        }
        guard let role = dependencies.oauth.memberRole(serverId: serverId, userId: userId) else {
            throw ServerMembersAndSidebarError.notAMember
        }
        guard role == "owner" else {
            throw ServerMembersAndSidebarError.forbidden
        }
        let memberIds = dependencies.oauth.memberIdsWithRoles(serverId: serverId).map(\.id)
        let agentIds = dependencies.oauth.serverAgents(serverId: serverId).map(\.id)
        var events: [ServerMemberEvent] = []
        for memberId in memberIds {
            events.append(ServerMemberEvent(
                serverId: serverId,
                eventType: "server.member_removed",
                subjectType: "member",
                subjectId: memberId,
                provenanceJSON: "{\"actor_type\":\"human\",\"principal_type\":\"human\",\"reason\":\"server_deleted\",\"role\":\"member\",\"source\":\"server_service\"}",
                deliveryQueued: true
            ))
        }
        for agentId in agentIds {
            events.append(ServerMemberEvent(
                serverId: serverId,
                eventType: "server.member_removed",
                subjectType: "agent",
                subjectId: agentId,
                provenanceJSON: "{\"actor_type\":\"human\",\"principal_type\":\"agent\",\"reason\":\"server_deleted\",\"role\":\"member\",\"source\":\"server_service\"}",
                deliveryQueued: true
            ))
        }
        dependencies.channels.appendServerMemberEvents(events)
        dependencies.oauth.deleteServer(id: serverId)
        dependencies.channels.markServerDeleted(serverId)
        dependencies.emitRealtime(
            "server:\(serverId)",
            "server:deleted",
            "{\"serverId\":\(jsonString(serverId))}"
        )
        for memberId in memberIds {
            dependencies.emitRealtime(
                "user:\(memberId)",
                "server:membership-removed",
                "{\"serverId\":\(jsonString(serverId))}"
            )
        }
        return OkResponse()
    }

    // MARK: - PATCH /api/servers/:id/sidebar-order

    /// Writes the caller's sidebar order, sections and pinned references.
    ///
    /// The body is optional (`{}` by default). An absent member keeps the stored
    /// value; a wrong one publishes its member-specific 400. The sections
    /// version check and every row write are one store critical section, so two
    /// concurrent patches cannot both accept the same version.
    public func patchSidebarOrder(
        authorization: String?,
        serverId: String,
        body: SidebarOrderPatchRequest?
    ) throws -> SidebarOrderResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw ServerMembersAndSidebarError.unauthorized
        }
        guard dependencies.oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            throw ServerMembersAndSidebarError.serverNotFound
        }
        guard let body else {
            throw ServerMembersAndSidebarError.invalidSidebarOrder
        }
        let snapshot = dependencies.channels.sidebarSnapshot(serverId: serverId, userId: userId)
        let modes = try patchModes(body, current: snapshot.modes)
        var sections = snapshot.sections
        let hasSectionFields = body.hasSectionFields
        var expectedSectionsVersion: Int?
        if hasSectionFields {
            switch body.sectionsVersion {
            case .value(let version):
                guard version == sections.version else {
                    throw ServerMembersAndSidebarError.sidebarSectionsConflict
                }
                expectedSectionsVersion = version
            case .invalid:
                throw ServerMembersAndSidebarError.sidebarSectionsConflict
            case .absent:
                break
            }
            if case .value(let entries) = body.customSections {
                sections.sections = try parseSections(entries)
            } else if case .invalid = body.customSections {
                throw ServerMembersAndSidebarError.invalidCustomSections
            }
            if case .value(let requested) = body.sectionOrder {
                var order = requested
                for system in ServersAndChannelsStore.SidebarSectionsRow.defaults.order where !order.contains(system) {
                    order.append(system)
                }
                sections.order = order
            } else if case .invalid = body.sectionOrder {
                throw ServerMembersAndSidebarError.invalidSectionOrder
            }
            if case .value(let entries) = body.sectionPlacements {
                sections.placements = try parsePlacements(entries)
            } else if case .invalid = body.sectionPlacements {
                throw ServerMembersAndSidebarError.invalidSectionPlacements
            }
            sections.version += 1
        }
        var pinnedState = snapshot.pinned ?? ServersAndChannelsStore.SidebarPinnedRow(
            refs: [],
            channelIds: [],
            agentIds: [],
            version: 0
        )
        var pinnedChanged = false
        if body.pinned != .absent {
            guard body.pinnedChannelIds == .absent else {
                throw ServerMembersAndSidebarError.invalidPinnedReferences
            }
            guard case .value(let entries) = body.pinned else {
                throw ServerMembersAndSidebarError.invalidPinnedReferences
            }
            var refs: [ServersAndChannelsStore.SidebarPinRow] = []
            var channelIds: [String] = []
            var agentIds: [String] = []
            for entry in entries {
                guard let kind = entry.kind,
                      ["channel", "agent", "human"].contains(kind),
                      let id = entry.id,
                      !id.isEmpty
                else {
                    throw ServerMembersAndSidebarError.invalidPinnedReferences
                }
                if kind == "channel" {
                    switch sidebarPinnedChannel(id: id, serverId: serverId, userId: userId) {
                    case .missing:
                        continue
                    case .canonical(let canonical, let legacyId):
                        refs.append(canonical)
                        channelIds.append(legacyId)
                    }
                } else if kind == "agent" {
                    guard let agent = dependencies.oauth.agentRuntimeInfo(id: id),
                          agent.serverId == serverId
                    else { continue }
                    refs.append(ServersAndChannelsStore.SidebarPinRow(kind: "agent", id: id))
                    agentIds.append(id)
                } else {
                    guard dependencies.humanExists(id) else { continue }
                    refs.append(ServersAndChannelsStore.SidebarPinRow(kind: "human", id: id))
                    if let dm = sidebarHumanDMChannelId(peerId: id, userId: userId, serverId: serverId) {
                        channelIds.append(dm)
                    }
                }
            }
            var seen = Set<String>()
            refs = refs.filter { seen.insert("\($0.kind)\n\($0.id)").inserted }
            var channelSeen = Set<String>()
            channelIds = channelIds.filter { channelSeen.insert($0).inserted }
            var agentSeen = Set<String>()
            agentIds = agentIds.filter { agentSeen.insert($0).inserted }
            pinnedChanged = refs.map { "\($0.kind)\n\($0.id)" }
                != pinnedState.refs.map { "\($0.kind)\n\($0.id)" }
            if pinnedChanged {
                pinnedState = ServersAndChannelsStore.SidebarPinnedRow(
                    refs: refs,
                    channelIds: channelIds,
                    agentIds: agentIds,
                    version: pinnedState.version + 1
                )
            }
        } else if body.pinnedChannelIds != .absent
                    || body.pinnedAgentIds != .absent
                    || body.pinnedOrder != .absent {
            guard let requestedChannels = stringArray(body.pinnedChannelIds),
                  let requestedAgents = stringArray(body.pinnedAgentIds),
                  let requestedOrder = body.pinnedOrder == .absent
                      ? nil
                      : stringArray(body.pinnedOrder)
            else {
                throw ServerMembersAndSidebarError.invalidPinnedReferences
            }
            var refs = pinnedState.refs.filter { $0.kind == "human" }
            var channelIds: [String] = []
            var agentIds: [String] = []
            let channelSource = requestedChannels.isEmpty && body.pinnedChannelIds == .absent
                ? requestedOrder.filter { dependencies.oauth.channelInfo(id: $0) != nil }
                : requestedChannels
            for id in channelSource {
                switch sidebarPinnedChannel(id: id, serverId: serverId, userId: userId) {
                case .missing:
                    continue
                case .canonical(let canonical, let legacyId):
                    refs.append(canonical)
                    channelIds.append(legacyId)
                }
            }
            let agentSource = requestedAgents.isEmpty && body.pinnedAgentIds == .absent
                ? requestedOrder.filter {
                    dependencies.oauth.agentRuntimeInfo(id: $0)?.serverId == serverId
                }
                : requestedAgents
            for id in agentSource {
                guard let agent = dependencies.oauth.agentRuntimeInfo(id: id),
                      agent.serverId == serverId
                else { continue }
                refs.append(ServersAndChannelsStore.SidebarPinRow(kind: "agent", id: id))
                agentIds.append(id)
            }
            var seen = Set<String>()
            refs = refs.filter { seen.insert("\($0.kind)\n\($0.id)").inserted }
            var channelSeen = Set<String>()
            channelIds = channelIds.filter { channelSeen.insert($0).inserted }
            var agentSeen = Set<String>()
            agentIds = agentIds.filter { agentSeen.insert($0).inserted }
            pinnedChanged = refs.map { "\($0.kind)\n\($0.id)" }
                != pinnedState.refs.map { "\($0.kind)\n\($0.id)" }
            if pinnedChanged {
                pinnedState = ServersAndChannelsStore.SidebarPinnedRow(
                    refs: refs,
                    channelIds: channelIds,
                    agentIds: agentIds,
                    version: pinnedState.version + 1
                )
            }
        }
        let result = dependencies.channels.applySidebarOrder(
            serverId: serverId,
            userId: userId,
            modes: modes,
            sections: hasSectionFields ? sections : nil,
            pinned: pinnedChanged ? pinnedState : nil,
            expectedSectionsVersion: expectedSectionsVersion
        )
        if case .sectionsConflict = result {
            throw ServerMembersAndSidebarError.sidebarSectionsConflict
        }
        if pinnedChanged {
            let refsJSON = pinnedState.refs
                .map { "{\"kind\":\(jsonString($0.kind)),\"id\":\(jsonString($0.id))}" }
                .joined(separator: ",")
            dependencies.emitRealtime(
                "user:\(userId)",
                "pinned:updated",
                "{\"pinned\":[\(refsJSON)],\"pinnedVersion\":\(pinnedState.version)}"
            )
        }
        return try sidebarOrder(authorization: authorization, serverId: serverId)
    }

    // MARK: - GET /api/servers/:id/sidebar-order

    /// The caller's sidebar order with the stored modes, sections and pinned
    /// references. A pinned ledger that was never written is derived from the
    /// OAuth order's `pinnedOrder`, exactly as the retired handler did.
    public func sidebarOrder(authorization: String?, serverId: String) throws -> SidebarOrderResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw ServerMembersAndSidebarError.unauthorized
        }
        guard dependencies.oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            throw ServerMembersAndSidebarError.notAMember
        }
        let order = dependencies.oauth.sanitizedSidebarOrder(serverId: serverId, userId: userId)
        let visibleChannelOrder = dependencies.channels.liveChannelIds(order.channelOrder)
        let snapshot = dependencies.channels.sidebarSnapshot(serverId: serverId, userId: userId)
        let pinnedState: ServersAndChannelsStore.SidebarPinnedRow
        if let storedPinned = snapshot.pinned {
            pinnedState = storedPinned
        } else {
            var refs: [ServersAndChannelsStore.SidebarPinRow] = []
            var channelIds: [String] = []
            var agentIds: [String] = []
            for id in order.pinnedOrder {
                if dependencies.oauth.agentRuntimeInfo(id: id)?.serverId == serverId {
                    refs.append(ServersAndChannelsStore.SidebarPinRow(kind: "agent", id: id))
                    agentIds.append(id)
                } else if dependencies.oauth.channelInfo(id: id)?.serverId == serverId {
                    refs.append(ServersAndChannelsStore.SidebarPinRow(kind: "channel", id: id))
                    channelIds.append(id)
                } else {
                    refs.append(ServersAndChannelsStore.SidebarPinRow(kind: "human", id: id))
                }
            }
            pinnedState = ServersAndChannelsStore.SidebarPinnedRow(
                refs: refs,
                channelIds: channelIds,
                agentIds: agentIds,
                version: 0
            )
        }
        let legacyPinnedOrder = snapshot.pinned == nil
            ? order.pinnedOrder
            : (pinnedState.channelIds + pinnedState.agentIds)
        let sections = snapshot.sections
        return SidebarOrderResponse(
            channelOrder: visibleChannelOrder,
            agentOrder: order.agentOrder,
            dmOrder: order.dmOrder,
            pinned: pinnedState.refs.map { SidebarPinDTO(kind: $0.kind, id: $0.id) },
            pinnedChannelIds: pinnedState.channelIds,
            pinnedAgentIds: pinnedState.agentIds,
            pinnedOrder: legacyPinnedOrder,
            pinnedVersion: pinnedState.version,
            hiddenDmIds: order.hiddenDmIds,
            channelSortMode: snapshot.modes.channel,
            jointChannelSortMode: snapshot.modes.joint,
            dmSortMode: snapshot.modes.dm,
            pinnedSortMode: snapshot.modes.pinned,
            channelPanelTabOrder: snapshot.modes.channelTabs,
            agentPanelTabOrder: snapshot.modes.agentTabs,
            customSections: sections.sections.map {
                SidebarSectionDTO(id: $0.id, name: $0.name, emoji: $0.emoji, sortMode: $0.sortMode)
            },
            sectionOrder: sections.order.isEmpty ? ServersAndChannelsStore.SidebarSectionsRow.defaults.order : sections.order,
            sectionPlacements: sections.placements.map {
                SidebarPlacementDTO(kind: $0.kind, id: $0.id, sectionId: $0.sectionId, position: $0.position)
            },
            sectionsVersion: sections.version
        )
    }

    // MARK: - GET /api/servers/:id/labs

    /// The server lab catalog. Any member may read it; the manage flags are
    /// role-derived.
    public func getServerLabs(
        authorization: String?,
        serverId: String,
        headerServerId: String
    ) throws -> ServerLabsResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw ServerMembersAndSidebarError.unauthorized
        }
        guard headerServerId == serverId else {
            throw ServerMembersAndSidebarError.serverScopeForbidden
        }
        guard let role = dependencies.oauth.memberRole(serverId: serverId, userId: userId) else {
            throw ServerMembersAndSidebarError.forbidden
        }
        let state = dependencies.channels.serverLabs(serverId: serverId)
        return ServerLabsResponse(
            accessEnabled: state.accessEnabled,
            version: state.version,
            canManageAccess: role == "owner",
            canManageEnrollments: role == "owner" || role == "admin",
            labs: labDTOs(state: state)
        )
    }

    // MARK: - PATCH /api/servers/:id/labs/access

    /// Flips the server lab master switch. The expected-version check, the
    /// toggle and the version bump are one store critical section.
    public func patchServerLabsAccess(
        authorization: String?,
        serverId: String,
        headerServerId: String,
        body: ServerLabsToggleRequest?
    ) throws -> ServerLabsAccessPatchResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw ServerMembersAndSidebarError.unauthorized
        }
        guard headerServerId == serverId else {
            throw ServerMembersAndSidebarError.serverScopeForbidden
        }
        guard let role = dependencies.oauth.memberRole(serverId: serverId, userId: userId) else {
            throw ServerMembersAndSidebarError.forbidden
        }
        guard role == "owner" else {
            throw ServerMembersAndSidebarError.forbidden
        }
        guard let body, let enabled = body.enabled, let expectedVersion = body.expectedVersion else {
            throw ServerMembersAndSidebarError.invalidLabsAccessRequest
        }
        switch dependencies.channels.applyLabsAccess(
            serverId: serverId,
            enabled: enabled,
            expectedVersion: expectedVersion
        ) {
        case .versionConflict(let currentVersion):
            throw ServerMembersAndSidebarError.serverLabsVersionConflict(currentVersion: currentVersion)
        case .applied(let state, let changed):
            return ServerLabsAccessPatchResponse(
                applied: changed,
                accessEnabled: state.accessEnabled,
                version: state.version,
                labs: labDTOs(state: state)
            )
        }
    }

    // MARK: - PUT /api/servers/:id/labs/:labKey

    /// Enrolls or unenrolls the caller's server in one lab. The expected version,
    /// the master switch, the lab state and the enrollment write are one store
    /// critical section, in the published decision order.
    public func putServerLabEnrollment(
        authorization: String?,
        serverId: String,
        headerServerId: String,
        labKey: String,
        body: ServerLabsToggleRequest?
    ) throws -> ServerLabEnrollmentResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw ServerMembersAndSidebarError.unauthorized
        }
        guard headerServerId == serverId else {
            throw ServerMembersAndSidebarError.serverScopeForbidden
        }
        guard let role = dependencies.oauth.memberRole(serverId: serverId, userId: userId) else {
            throw ServerMembersAndSidebarError.forbidden
        }
        guard role == "owner" || role == "admin" else {
            throw ServerMembersAndSidebarError.forbidden
        }
        guard let definition = TaskCatalogPolicy.labDefinitions.first(where: { $0.key == labKey }),
              definition.state == "open" || definition.state == "paused"
        else {
            throw ServerMembersAndSidebarError.labNotFound
        }
        guard let body, let enabled = body.enabled, let expectedVersion = body.expectedVersion else {
            throw ServerMembersAndSidebarError.invalidLabEnrollmentRequest
        }
        switch dependencies.channels.applyLabEnrollment(
            serverId: serverId,
            labKey: labKey,
            enabled: enabled,
            expectedVersion: expectedVersion,
            labOpen: definition.state == "open",
            now: dependencies.now()
        ) {
        case .versionConflict(let currentVersion):
            throw ServerMembersAndSidebarError.serverLabsVersionConflict(currentVersion: currentVersion)
        case .accessDisabled:
            throw ServerMembersAndSidebarError.serverLabsAccessDisabled
        case .labNotOpen:
            throw ServerMembersAndSidebarError.labNotOpen
        case .applied(let state, let changed):
            return ServerLabEnrollmentResponse(
                applied: changed,
                version: state.version,
                labs: labDTOs(state: state)
            )
        }
    }

    // MARK: - GET /api/tasks/server/snapshot-metrics

    /// The task snapshot aggregate. Only visible channels count, and an
    /// explicit `channelId` must be a readable channel on this server.
    public func taskSnapshotMetrics(
        authorization: String?,
        serverId: String,
        rawQuery: String?
    ) throws -> TaskSnapshotMetricsResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw ServerMembersAndSidebarError.unauthorized
        }
        guard let role = dependencies.oauth.memberRole(serverId: serverId, userId: userId) else {
            throw ServerMembersAndSidebarError.notAMember
        }
        guard role == "owner" || role == "admin" else {
            throw ServerMembersAndSidebarError.forbidden
        }
        var channelFilter: String?
        for pair in (rawQuery ?? "").split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[0] == "channelId" {
                let rawChannel = parts[1].removingPercentEncoding ?? parts[1]
                guard UUID(uuidString: rawChannel) != nil,
                      let channel = dependencies.oauth.channelInfo(id: rawChannel),
                      channel.serverId == serverId
                else {
                    throw ServerMembersAndSidebarError.channelNotFound
                }
                if (dependencies.oauth.channelType(id: rawChannel) ?? "channel") != "channel",
                   !dependencies.oauth.isChannelParticipant(channelId: rawChannel, userId: userId) {
                    throw ServerMembersAndSidebarError.channelNotFound
                }
                channelFilter = rawChannel
            }
        }
        let visible = Set(
            dependencies.oauth.channelsForServer(serverId: serverId, userId: userId)
                .filter { $0.joined }
                .map { $0.id }
        )
        let rows = dependencies.tasks.taskRecords.filter { task in
            channelFilter.map({ $0 == task.channelId }) ?? visible.contains(task.channelId)
        }
        let inReview = rows.filter { $0.status == "in_review" }.count
        let done = rows.filter { $0.status == "done" }.count
        let durations = rows.compactMap { task -> Double? in
            guard let completedAt = task.completedAt else { return nil }
            return completedAt.timeIntervalSince(task.createdAt) / 3600
        }.sorted()
        func percentile(_ value: Double) -> Double {
            guard !durations.isEmpty else { return 0 }
            let index = max(0, min(durations.count - 1, Int(ceil(value * Double(durations.count))) - 1))
            return durations[index]
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let firstCreatedAt = rows.map(\.createdAt).min()
        let latestUpdatedAt = rows.compactMap { $0.updatedAt ?? $0.completedAt ?? $0.createdAt }.max()
        return TaskSnapshotMetricsResponse(
            total: rows.count,
            inReview: inReview,
            done: done,
            durationSamples: durations.count,
            medianHours: Self.number(percentile(0.5)),
            p90Hours: Self.number(percentile(0.9)),
            firstCreatedAt: firstCreatedAt.map { formatter.string(from: $0) },
            latestUpdatedAt: latestUpdatedAt.map { formatter.string(from: $0) }
        )
    }

    // MARK: - GET /api/tasks/server/period-metrics

    /// The two-week task aggregate: `from`→`midpoint` for the previous window
    /// and `midpoint`→`to` for the current one. Both windows must be exactly one
    /// week long.
    public func taskPeriodMetrics(
        authorization: String?,
        serverId: String,
        rawQuery: String?
    ) throws -> TaskPeriodMetricsResponse {
        guard let userId = dependencies.sessionUserId(authorization) else {
            throw ServerMembersAndSidebarError.unauthorized
        }
        guard let role = dependencies.oauth.memberRole(serverId: serverId, userId: userId) else {
            throw ServerMembersAndSidebarError.notAMember
        }
        guard role == "owner" || role == "admin" else {
            throw ServerMembersAndSidebarError.forbidden
        }
        var params: [String: String] = [:]
        for pair in (rawQuery ?? "").split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { params[parts[0]] = parts[1].removingPercentEncoding ?? parts[1] }
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallback = ISO8601DateFormatter()
        func parse(_ value: String?) -> Date? {
            guard let value else { return nil }
            return formatter.date(from: value) ?? fallback.date(from: value)
        }
        guard let from = parse(params["from"]),
              let midpoint = parse(params["midpoint"]),
              let to = parse(params["to"])
        else {
            throw ServerMembersAndSidebarError.invalidMetricsWindow
        }
        let week: TimeInterval = 7 * 24 * 60 * 60
        guard abs(midpoint.timeIntervalSince(from) - week) < 1,
              abs(to.timeIntervalSince(midpoint) - week) < 1
        else {
            throw ServerMembersAndSidebarError.invalidMetricsWindow
        }
        var channelFilter: String?
        if let rawChannel = params["channelId"] {
            guard UUID(uuidString: rawChannel) != nil else {
                throw ServerMembersAndSidebarError.invalidChannelId
            }
            guard let channel = dependencies.oauth.channelInfo(id: rawChannel),
                  channel.serverId == serverId
            else {
                throw ServerMembersAndSidebarError.channelNotFound
            }
            if (dependencies.oauth.channelType(id: rawChannel) ?? "channel") != "channel",
               !dependencies.oauth.isChannelParticipant(channelId: rawChannel, userId: userId) {
                throw ServerMembersAndSidebarError.channelNotFound
            }
            channelFilter = rawChannel
        }
        let visible = Set(
            dependencies.oauth.channelsForServer(serverId: serverId, userId: userId)
                .filter { $0.joined }
                .map { $0.id }
        )
        let rows = dependencies.tasks.taskRecords.filter { task in
            guard let completedAt = task.completedAt else { return false }
            guard channelFilter.map({ $0 == task.channelId }) ?? visible.contains(task.channelId) else {
                return false
            }
            return completedAt >= from && completedAt < to
        }
        func metrics(_ start: Date, _ end: Date) -> TaskPeriodMetricsWindowDTO {
            let window = rows.filter { task in
                guard let completedAt = task.completedAt else { return false }
                return completedAt >= start && completedAt < end
            }
            let durations = window.compactMap { task -> Double? in
                guard let completedAt = task.completedAt else { return nil }
                return completedAt.timeIntervalSince(task.createdAt) / 3600
            }.sorted()
            let mean = durations.isEmpty ? 0 : durations.reduce(0, +) / Double(durations.count)
            let median: Double
            if durations.isEmpty {
                median = 0
            } else if durations.count % 2 == 1 {
                median = durations[durations.count / 2]
            } else {
                median = (durations[durations.count / 2 - 1] + durations[durations.count / 2]) / 2
            }
            return TaskPeriodMetricsWindowDTO(
                completed: window.count,
                durationSamples: durations.count,
                meanHours: Self.number(mean),
                medianHours: Self.number(median)
            )
        }
        return TaskPeriodMetricsResponse(
            current: metrics(midpoint, to),
            previous: metrics(from, midpoint)
        )
    }

    // MARK: - Helpers

    private func patchModes(
        _ body: SidebarOrderPatchRequest,
        current: ServersAndChannelsStore.SidebarModesRow
    ) throws -> ServersAndChannelsStore.SidebarModesRow {
        func mode(_ field: SidebarField<String>, _ current: String) throws -> String {
            switch field {
            case .absent:
                return current
            case .value(let value) where ["manual", "recent", "az"].contains(value):
                return value
            case .value, .invalid:
                throw ServerMembersAndSidebarError.invalidSidebarSortMode
            }
        }
        func tabs(
            _ field: SidebarField<[String]>,
            _ current: [String],
            allowed: Set<String>
        ) throws -> [String] {
            switch field {
            case .absent:
                return current
            case .value(let values):
                return values.filter { allowed.contains($0) }
            case .invalid:
                throw ServerMembersAndSidebarError.invalidSidebarPanelOrder
            }
        }
        return ServersAndChannelsStore.SidebarModesRow(
            channel: try mode(body.channelSortMode, current.channel),
            joint: try mode(body.jointChannelSortMode, current.joint),
            dm: try mode(body.dmSortMode, current.dm),
            pinned: try mode(body.pinnedSortMode, current.pinned),
            channelTabs: try tabs(
                body.channelPanelTabOrder,
                current.channelTabs,
                allowed: ["files", "tasks", "chat"]
            ),
            agentTabs: try tabs(
                body.agentPanelTabOrder,
                current.agentTabs,
                allowed: ["activity", "integrations", "profile"]
            )
        )
    }

    private func parseSections(
        _ entries: [SidebarSectionPatchEntry]
    ) throws -> [ServersAndChannelsStore.SidebarSectionRow] {
        var parsed: [ServersAndChannelsStore.SidebarSectionRow] = []
        for entry in entries {
            guard let id = entry.id, !id.isEmpty, let name = entry.name, !entry.emojiInvalid else {
                throw ServerMembersAndSidebarError.invalidCustomSections
            }
            let sortMode = entry.sortMode ?? "manual"
            guard ["manual", "recent", "az"].contains(sortMode) else {
                throw ServerMembersAndSidebarError.invalidCustomSections
            }
            parsed.append(ServersAndChannelsStore.SidebarSectionRow(
                id: id,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                emoji: entry.emoji,
                sortMode: sortMode
            ))
        }
        return parsed
    }

    private func parsePlacements(
        _ entries: [SidebarPlacementPatchEntry]
    ) throws -> [ServersAndChannelsStore.SidebarPlacementRow] {
        var placements: [ServersAndChannelsStore.SidebarPlacementRow] = []
        for entry in entries {
            guard let kind = entry.kind,
                  ["channel", "agent"].contains(kind),
                  let id = entry.id,
                  let sectionId = entry.sectionId
            else {
                throw ServerMembersAndSidebarError.invalidSectionPlacements
            }
            if kind == "channel" {
                guard dependencies.channels.liveChannelExists(id) else { continue }
            }
            placements.append(ServersAndChannelsStore.SidebarPlacementRow(
                kind: kind,
                id: id,
                sectionId: sectionId,
                position: placements.count
            ))
        }
        return placements
    }

    private func stringArray(_ field: SidebarField<[String]>) -> [String]? {
        switch field {
        case .absent:
            return []
        case .value(let values):
            return values
        case .invalid:
            return nil
        }
    }

    private enum SidebarPinnedResolution {
        case missing
        case canonical(ServersAndChannelsStore.SidebarPinRow, legacyId: String)
    }

    private func sidebarPinnedChannel(
        id: String,
        serverId: String,
        userId: String
    ) -> SidebarPinnedResolution {
        guard let channel = dependencies.oauth.channelInfo(id: id), channel.serverId == serverId else {
            return .missing
        }
        let type = dependencies.oauth.channelType(id: id) ?? "channel"
        if type == "dm" {
            let agents = dependencies.oauth.channelAgentIds(channelId: id)
            if agents.count == 1 {
                return .canonical(
                    ServersAndChannelsStore.SidebarPinRow(kind: "agent", id: agents[0]),
                    legacyId: id
                )
            }
            let humans = dependencies.oauth.channelHumanIds(channelId: id).filter { $0 != userId }
            if let peer = humans.first {
                return .canonical(
                    ServersAndChannelsStore.SidebarPinRow(kind: "human", id: peer),
                    legacyId: id
                )
            }
            return .missing
        }
        if type == "private",
           !dependencies.oauth.channelHumanIds(channelId: id).contains(userId) {
            return .missing
        }
        return .canonical(
            ServersAndChannelsStore.SidebarPinRow(kind: "channel", id: id),
            legacyId: id
        )
    }

    private func sidebarHumanDMChannelId(peerId: String, userId: String, serverId: String) -> String? {
        dependencies.oauth.channelsForServer(serverId: serverId, userId: userId, includeArchived: true)
            .first {
                $0.type == "dm"
                    && dependencies.oauth.channelHumanIds(channelId: $0.id).contains(userId)
                    && dependencies.oauth.channelHumanIds(channelId: $0.id).contains(peerId)
                    && dependencies.oauth.channelAgentIds(channelId: $0.id).isEmpty
            }?.id
    }

    private func labDTOs(state: ServerLabsState) -> [ServerLabDTO] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return TaskCatalogPolicy.labDefinitions
            .filter { $0.state == "open" || $0.state == "paused" }
            .map { lab in
                let enrolled = state.enrolled.contains(lab.key)
                let effective = state.accessEnabled && lab.state == "open" && enrolled
                return ServerLabDTO(
                    labKey: lab.key,
                    name: lab.name,
                    description: lab.description,
                    state: lab.state,
                    enrolled: enrolled,
                    effective: effective,
                    updatedAt: state.updatedAt[lab.key].map { formatter.string(from: $0) }
                )
            }
    }

    /// The retired `number(_:)` text: integral values print without a fractional
    /// part, everything else with two decimals.
    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }
}

import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Join links, server invites, membership acceptance and the server setup
/// projections that gate them.
///
/// These handlers were lifted from
/// `EmailLogin+IntegrationsAndAccess.swift`.

public struct JoinLinksAndInvitesService: Sendable {
    public let directory: EmailLoginDirectory

    public init(directory: EmailLoginDirectory) {
        self.directory = directory
    }
}

extension EmailLoginDirectory {

    public func agentProfileShow(authorization: String?, target: String?) -> HTTPReply {
        guard let credential = agentCredentialAgent(authorization),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        func agentJSON(_ row: (id: String, name: String, displayName: String, description: String, avatarUrl: String?)) -> [String: Any] {
            [
                "agentId": row.id,
                "name": row.name,
                "displayName": row.displayName,
                "description": row.description,
                "avatarUrl": row.avatarUrl as Any,
            ]
        }
        guard let target, !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let json = "{\"agentId\":\(jsonString(agent.id)),\"name\":\(jsonString(agent.name)),\"displayName\":\(jsonString(agent.displayName)),\"description\":\(jsonString(agent.description ?? "")),\"avatarUrl\":\(agent.avatarUrl.map(jsonString) ?? "null")}"
            return Self.json(200, json)
        }
        guard credential.scopes.contains("read") else {
            return Self.json(403, "{\"error\":\"Agent credential is not authorized for this capability\",\"code\":\"capability_not_authorized\"}")
        }
        let handle = target.hasPrefix("@") ? String(target.dropFirst()) : target
        let lowered = handle.lowercased()
        lock.lock()
        let agentMatch = oauth.serverAgents(serverId: agent.serverId).first {
            !$0.deleted && ($0.name.lowercased() == lowered || $0.displayName.lowercased() == lowered)
        }
        let accountMatch = accounts.values.first {
            $0.name.lowercased() == lowered && oauth.memberRole(serverId: agent.serverId, userId: $0.id) != nil
        }
        let hiddenDirectory = hideHumansFromMembers[agent.serverId] == true
        lock.unlock()
        if let agentMatch {
            return Self.json(200, "{\"agentId\":\(jsonString(agentMatch.id)),\"name\":\(jsonString(agentMatch.name)),\"displayName\":\(jsonString(agentMatch.displayName)),\"description\":\(jsonString(agentMatch.description ?? "")),\"avatarUrl\":\(agentMatch.avatarUrl.map(jsonString) ?? "null")}")
        }
        guard let accountMatch else {
            return Self.json(404, "{\"error\":\"Profile not found\"}")
        }
        if hiddenDirectory {
            let shared = oauth.channelsForServer(serverId: agent.serverId, userId: accountMatch.id).contains { channel in
                oauth.channelAgentIds(channelId: channel.id).contains(agent.id)
            }
            guard shared else {
                return Self.json(404, "{\"error\":\"Profile not found\"}")
            }
        }
        let json = "{\"userId\":\(jsonString(accountMatch.id)),\"name\":\(jsonString(accountMatch.name)),\"displayName\":\(accountMatch.displayName.map(jsonString) ?? jsonString(accountMatch.name)),\"avatarUrl\":\(accountMatch.avatarUrl.map(jsonString) ?? "null")}"
        return Self.json(200, json)
    }

    public func updateAgentProfile(authorization: String?, body: String) -> HTTPReply {
        if let denial = agentCapabilityDenial(authorization, required: "send") { return denial }
        guard let authorization, authorization.hasPrefix("Bearer ") else {
            return Self.json(401, "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        lock.lock()
        let credential = agentCredentials[token]
        lock.unlock()
        guard let credential, let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return Self.json(400, "{\"error\":\"Invalid profile update\"}")
        }
        lock.lock()
        let hosted = hostedAgents.contains(agent.id)
        lock.unlock()
        if hosted, object["description"] != nil {
            return Self.json(403, "{\"error\":\"Hosted agents cannot change their own description\",\"code\":\"hosted_agent_description_human_only\",\"suggestedNextAction\":\"Ask a human owner or admin to edit it in your Profile tab in Raft. Nothing was changed.\"}")
        }
        if let description = object["description"] as? String {
            oauth.updateAgentDescription(id: agent.id, description: description)
        }
        if let displayName = object["displayName"] as? String,
           !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            oauth.updateAgentDisplayName(id: agent.id, displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let latest = oauth.agentRuntimeInfo(id: agent.id)
        let displayJSON = latest.map { jsonString($0.displayName) } ?? "null"
        let descriptionJSON = latest?.description.map(jsonString) ?? "null"
        emitRealtime("server:\(agent.serverId)", "agent:updated", "{\"agentId\":\(jsonString(agent.id)),\"displayName\":\(displayJSON)}")
        return Self.json(200, "{\"ok\":true,\"agentId\":\(jsonString(agent.id)),\"displayName\":\(displayJSON),\"description\":\(descriptionJSON)}")
    }

    public func setServerSeats(serverId: String, seats: Int) {
        lock.lock()
        proSeats[serverId] = seats
        lock.unlock()
    }

    func seatLimitMessageLocked(serverId: String) -> String? {
        guard let seats = proSeats[serverId] else { return nil }
        let used = oauth.memberIdsWithRoles(serverId: serverId).filter { $0.role != "guest" }.count
        guard used >= seats else { return nil }
        return "Seat limit reached (\(used)/\(seats) on Pro plan)"
    }

    public func createJoinLink(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Only server owners and admins can create join links\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Only server owners and admins can create join links\"}")
        }
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
        var expiresAt: Date?
        if let raw = object["expiresAt"] as? String, !raw.isEmpty {
            guard let parsed = Self.isoDate(raw) else {
                return Self.json(400, "{\"error\":\"expiresAt must be a valid date\"}")
            }
            expiresAt = parsed
        }
        var maxUses: Int?
        if let raw = object["maxUses"], !(raw is NSNull) {
            if let string = raw as? String, string.isEmpty {
                maxUses = nil
            } else if let number = raw as? NSNumber, number.doubleValue.rounded() == number.doubleValue,
                      number.intValue >= 1 {
                maxUses = number.intValue
            } else {
                return Self.json(400, "{\"error\":\"maxUses must be a positive integer\"}")
            }
        }
        let token = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let link = JoinLinkRecord(
            id: UUID().uuidString.lowercased(),
            token: token,
            serverId: serverId,
            role: "member",
            createdAt: Date(),
            expiresAt: expiresAt,
            maxUses: maxUses,
            useCount: 0,
            revokedAt: nil
        )
        lock.lock()
        joinLinks[token] = link
        lock.unlock()
        let expiresJSON = expiresAt.map { jsonString(Self.isoString($0)) } ?? "null"
        let maxUsesJSON = maxUses.map(String.init) ?? "null"
        return Self.json(200, "{\"token\":\(jsonString(token)),\"link\":\(joinLinkJSON(link)),\"maxUses\":\(maxUsesJSON),\"expiresAt\":\(expiresJSON)}")
    }

    public func listJoinLinks(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Only server owners and admins can view join links\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Only server owners and admins can view join links\"}")
        }
        lock.lock()
        let now = Date()
        let links = joinLinks.values
            .filter { $0.serverId == serverId && $0.revokedAt == nil }
            .filter { !Self.joinLinkExpired($0, now: now) && !Self.joinLinkExhausted($0) }
            .sorted { $0.createdAt > $1.createdAt }
            .map(joinLinkJSON)
            .joined(separator: ",")
        lock.unlock()
        return Self.json(200, "[\(links)]")
    }

    public func revokeJoinLink(authorization: String?, serverId: String, linkId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Only server owners and admins can revoke join links\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Only server owners and admins can revoke join links\"}")
        }
        lock.lock()
        if let key = joinLinks.first(where: { $0.value.id == linkId && $0.value.serverId == serverId })?.key {
            joinLinks[key]?.revokedAt = Date()
        }
        lock.unlock()
        return Self.json(200, "{\"ok\":true}")
    }

    public func inviteInfo(token: String?) -> HTTPReply {
        guard let token, !token.isEmpty else {
            return Self.json(404, "{\"error\":\"Invite not found\"}")
        }
        if let link = joinLinks[token.lowercased()] {
            guard link.revokedAt == nil, !Self.joinLinkExpired(link, now: Date()), !Self.joinLinkExhausted(link) else {
                return Self.json(404, "{\"error\":\"Invite not found\"}")
            }
            guard let profile = oauth.serverProfile(id: link.serverId) else {
                return Self.json(404, "{\"error\":\"Invite not found\"}")
            }
            lock.lock()
            let message = seatLimitMessageLocked(serverId: link.serverId)
            lock.unlock()
            return inviteInfoJSON(profile: profile, message: message)
        }
        let hash = Self.sha256(token)
        lock.lock()
        let invite = serverInvites.first { $0.tokenHash == hash }
        lock.unlock()
        guard let invite, let profile = oauth.serverProfile(id: invite.serverId) else {
            return Self.json(404, "{\"error\":\"Invite not found\"}")
        }
        lock.lock()
        let message = seatLimitMessageLocked(serverId: invite.serverId)
        lock.unlock()
        return inviteInfoJSON(profile: profile, message: message)
    }

    func inviteInfoJSON(profile: OAuthLedger.ServerProfile, message: String?) -> HTTPReply {
        let messageJSON = message.map(jsonString) ?? "null"
        let hidden = hideHumansFromMembers[profile.id] == true
        let memberCount = hidden ? 0 : oauth.memberRoles(serverId: profile.id).count
        let agentCount = hidden ? 0 : oauth.serverAgents(serverId: profile.id).count
        let agreementJSON = oauth.activeServerAgreement(serverId: profile.id).map { Self.agreementJSON($0) } ?? "null"
        return Self.json(200, "{\"serverId\":\(jsonString(profile.id)),\"serverName\":\(jsonString(profile.name)),\"serverSlug\":\(jsonString(profile.slug)),\"humanSeatLimitReached\":\(message != nil),\"humanSeatLimitMessage\":\(messageJSON),\"memberCount\":\(memberCount),\"agentCount\":\(agentCount),\"insideCountsHidden\":\(hidden ? "true" : "false"),\"agreement\":\(agreementJSON)}")
    }

    public func acceptInvite(authorization: String?, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let rawToken = object["token"] as? String
        else {
            return Self.json(400, "{\"error\":\"Invalid invite\"}")
        }
        if let existing = joinLinks[rawToken.lowercased()] {
            guard existing.revokedAt == nil,
                  !Self.joinLinkExpired(existing, now: Date()),
                  !Self.joinLinkExhausted(existing)
            else {
                return Self.json(400, "{\"error\":\"Invalid invite\"}")
            }
            lock.lock()
            let message = seatLimitMessageLocked(serverId: existing.serverId)
            if let message {
                lock.unlock()
                return Self.json(400, "{\"error\":\(jsonString(message))}")
            }
            let active = oauth.activeServerAgreement(serverId: existing.serverId)
            if let active {
                guard let requested = object["agreementId"] as? String else {
                    let agreementJSON = Self.agreementJSON(active)
                    lock.unlock()
                    return Self.json(409, "{\"error\":\"agreement_required\",\"agreement\":\(agreementJSON)}")
                }
                guard requested == active.id else {
                    let agreementJSON = Self.agreementJSON(active)
                    lock.unlock()
                    return Self.json(409, "{\"error\":\"agreement_changed\",\"agreement\":\(agreementJSON)}")
                }
                membershipAgreementAudits.append((
                    serverId: existing.serverId, subjectId: userId, actorUserId: userId,
                    source: "invite", agreementId: active.id, agreementVersion: active.version
                ))
            }
            let oldCount = joinLinks[rawToken.lowercased()]?.useCount ?? 0
            joinLinks[rawToken.lowercased()]?.useCount = oldCount + 1
            lock.unlock()
            oauth.addMember(serverId: existing.serverId, userId: userId, role: existing.role)
            lock.lock()
            recordServerMemberEvent(
                serverId: existing.serverId, eventType: "server.member_added", subjectType: "member", subjectId: userId,
                provenanceJSON: "{\"actor_type\":\"human\",\"principal_type\":\"human\",\"reason\":\"joined\",\"role\":\(jsonString(existing.role)),\"source\":\"server_service\"}"
            )
            lock.unlock()
            return Self.json(200, "{\"ok\":true,\"serverId\":\(jsonString(existing.serverId))}")
        }
        let hash = Self.sha256(rawToken)
        lock.lock()
        guard let index = serverInvites.firstIndex(where: { $0.tokenHash == hash }) else {
            lock.unlock()
            return Self.json(400, "{\"error\":\"Invalid invite\"}")
        }
        let invite = serverInvites[index]
        let email = accounts.values.first(where: { $0.id == userId })?.email.lowercased()
        guard email == invite.email.lowercased() else {
            lock.unlock()
            return Self.json(400, "{\"error\":\"Invalid invite\"}")
        }
        let message = seatLimitMessageLocked(serverId: invite.serverId)
        if let message {
            lock.unlock()
            return Self.json(400, "{\"error\":\(jsonString(message))}")
        }
        if let active = oauth.activeServerAgreement(serverId: invite.serverId) {
            guard let requested = object["agreementId"] as? String else {
                let agreementJSON = Self.agreementJSON(active)
                lock.unlock()
                return Self.json(409, "{\"error\":\"agreement_required\",\"agreement\":\(agreementJSON)}")
            }
            guard requested == active.id else {
                let agreementJSON = Self.agreementJSON(active)
                lock.unlock()
                return Self.json(409, "{\"error\":\"agreement_changed\",\"agreement\":\(agreementJSON)}")
            }
            membershipAgreementAudits.append((
                serverId: invite.serverId, subjectId: userId, actorUserId: userId,
                source: "invite", agreementId: active.id, agreementVersion: active.version
            ))
        }
        serverInvites.remove(at: index)
        lock.unlock()
        oauth.addMember(serverId: invite.serverId, userId: userId, role: invite.role)
        lock.lock()
        recordServerMemberEvent(
            serverId: invite.serverId, eventType: "server.member_added", subjectType: "member", subjectId: userId,
            provenanceJSON: "{\"actor_type\":\"human\",\"principal_type\":\"human\",\"reason\":\"joined\",\"role\":\(jsonString(invite.role)),\"source\":\"server_service\"}"
        )
        lock.unlock()
        return Self.json(200, "{\"ok\":true,\"serverId\":\(jsonString(invite.serverId))}")
    }

    func joinLinkJSON(_ link: JoinLinkRecord) -> String {
        let expiresAt = link.expiresAt.map { jsonString(Self.isoString($0)) } ?? "null"
        let revokedAt = link.revokedAt.map { jsonString(Self.isoString($0)) } ?? "null"
        let maxUses = link.maxUses.map(String.init) ?? "null"
        return "{\"id\":\(jsonString(link.id)),\"token\":\(jsonString(link.token)),\"createdAt\":\(jsonString(Self.isoString(link.createdAt))),\"expiresAt\":\(expiresAt),\"maxUses\":\(maxUses),\"useCount\":\(link.useCount),\"revokedAt\":\(revokedAt)}"
    }

    public func listServerInvites(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        lock.lock()
        let rows = serverInvites.filter { $0.serverId == serverId }.map { invite in
            "{\"id\":\(jsonString(invite.id)),\"invitedEmail\":\(jsonString(invite.email)),\"email\":\(jsonString(invite.email)),\"role\":\(jsonString(invite.role)),\"status\":\"pending\"}"
        }.joined(separator: ",")
        lock.unlock()
        return Self.json(200, "[\(rows)]")
    }

    public func revokeServerInvite(authorization: String?, serverId: String, inviteId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Only server owners and admins can revoke invites\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Only server owners and admins can revoke invites\"}")
        }
        lock.lock()
        serverInvites.removeAll { $0.id == inviteId && $0.serverId == serverId }
        lock.unlock()
        return Self.json(200, "{\"ok\":true}")
    }

    public func createServerInvite(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let rawEmail = object["email"] as? String
        else {
            return Self.json(400, "{\"error\":\"Enter a valid email address\"}")
        }
        let email = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.wholeMatch(of: /^[^\s@]+@[^\s@]+\.[^\s@]+$/) != nil else {
            return Self.json(400, "{\"error\":\"Enter a valid email address\"}")
        }
        let inviteRole = (object["role"] as? String) ?? "member"
        guard ["member", "guest"].contains(inviteRole) else {
            return Self.json(400, "{\"error\":\"role must be one of: member, guest\"}")
        }
        if inviteRole == "guest" {
            lock.lock()
            let enabled = guestRoleServers.contains(serverId)
            lock.unlock()
            guard enabled else {
                return Self.json(400, "{\"error\":\"Guest access is not enabled for this server\"}")
            }
        }
        if inviteRole == "member" {
            lock.lock()
            let message = seatLimitMessageLocked(serverId: serverId)
            lock.unlock()
            if let message {
                return Self.json(400, "{\"error\":\(jsonString(message))}")
            }
        }
        let id = UUID().uuidString.lowercased()
        lock.lock()
        serverInvites.append((id: id, serverId: serverId, email: email, role: inviteRole, tokenHash: nil))
        lock.unlock()
        return Self.json(200, "{\"id\":\(jsonString(id)),\"invitedEmail\":\(jsonString(email)),\"email\":\(jsonString(email)),\"role\":\(jsonString(inviteRole)),\"invite\":{\"id\":\(jsonString(id)),\"email\":\(jsonString(email)),\"role\":\(jsonString(inviteRole)),\"status\":\"pending\"}}")
    }

    public func leaveServer(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return PublicVisits.authRequired(authorization: authorization)
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        if role == "owner", oauth.ownerCount(serverId: serverId) <= 1 {
            return Self.json(400, "{\"error\":\"The owner cannot leave the server\"}")
        }
        oauth.removeMember(serverId: serverId, userId: userId)
        lock.lock()
        serverMemberStatuses["\(serverId)\n\(userId)"] = "left"
        lock.unlock()
        lock.lock()
        removedServerMembers.insert("\(serverId)\n\(userId)")
        recordServerMemberEvent(
            serverId: serverId, eventType: "server.member_removed", subjectType: "member", subjectId: userId,
            provenanceJSON: "{\"actor_type\":\"human\",\"principal_type\":\"human\",\"reason\":\"left\",\"role\":\(jsonString(role)),\"source\":\"server_service\"}"
        )
        lock.unlock()
        return Self.json(200, "{\"ok\":true}")
    }

    func setupProjectionJSON(serverId: String, userId: String, role: String) -> String {
        lock.lock()
        let phase = setupPhases["\(serverId)\n\(userId)"] ?? "not_started"
        lock.unlock()
        if role == "owner" || role == "admin" {
            let currentStep = phase == "in_progress" ? "computer_runtime" : "computer_runtime"
            return "{\"surface\":\"computer_runtime\",\"phase\":\(jsonString(phase)),\"currentStep\":\(jsonString(currentStep)),\"blocksChat\":true,\"allowedExits\":[\"reset\",\"return_to_server\"],\"sideEffectState\":{\"transitions\":\"enabled\",\"completion\":\"disabled\"},\"gateReason\":\"computer_offline\",\"computerStatus\":\"offline\",\"runtimeStatus\":\"unknown\",\"runtimeOptions\":[],\"hasConnectedComputer\":false,\"offlineComputers\":[],\"postSetup\":{\"surveyPending\":false,\"handoffPending\":false}}"
        }
        return "{\"surface\":\"none\",\"phase\":null,\"currentStep\":null,\"blocksChat\":false,\"allowedExits\":[\"return_to_server\"],\"sideEffectState\":{\"transitions\":\"disabled\",\"completion\":\"disabled\"},\"gateReason\":\"insufficient_permission\",\"computerStatus\":\"unknown\",\"runtimeStatus\":\"unknown\",\"runtimeOptions\":[],\"hasConnectedComputer\":false,\"offlineComputers\":[],\"postSetup\":{\"surveyPending\":false,\"handoffPending\":false}}"
    }

    public func slackBridgeUnavailable() -> HTTPReply {
        Self.json(503, "{\"ok\":false,\"code\":\"slack_bridge_provider_unavailable\"}")
    }

    public func serverSetupProjection(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        return Self.json(200, setupProjectionJSON(serverId: serverId, userId: userId, role: role))
    }

    public func serverSetupTransition(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard role == "owner" || role == "admin" else {
            return Self.json(403, "{\"error\":\"INSUFFICIENT_PERMISSION\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let action = object["action"] as? String,
              action == "start" || action == "reset" || action == "return_to_server"
        else {
            return Self.json(400, "{\"error\":\"INVALID_SETUP_ACTION\"}")
        }
        lock.lock()
        let key = "\(serverId)\n\(userId)"
        if action == "start" {
            setupPhases[key] = "in_progress"
        } else if action == "reset" {
            setupPhases[key] = "not_started"
        }
        lock.unlock()
        return Self.json(200, setupProjectionJSON(serverId: serverId, userId: userId, role: role))
    }

    public func serverSetupReset(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"INSUFFICIENT_PERMISSION\"}")
        }
        guard role == "owner" else {
            return Self.json(403, "{\"error\":\"INSUFFICIENT_PERMISSION\"}")
        }
        lock.lock()
        let hasAgent = serverAgents.values.contains { $0.serverId == serverId }
        if hasAgent {
            lock.unlock()
            return Self.json(409, "{\"error\":\"SERVER_ALREADY_SET_UP\"}")
        }
        var revokedComputers = 0
        for index in computers.indices where computers[index].serverId == serverId && computers[index].revokedAt == nil {
            computers[index].revokedAt = Date()
            if computers[index].machineId != nil { revokedComputers += 1 }
        }
        setupPhases = setupPhases.filter { !$0.key.hasPrefix("\(serverId)\n") }
        setupHandoffs.remove(serverId)
        lock.unlock()
        var projection = setupProjectionJSON(serverId: serverId, userId: userId, role: role)
        projection.removeLast()
        projection += ",\"revokedComputers\":\(revokedComputers)}"
        return Self.json(200, projection)
    }

    public func serverSetupHandoff(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.serverProfile(id: serverId) != nil else {
            return Self.json(404, "{\"error\":\"Server not found\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) == "owner" else {
            return Self.json(403, "{\"error\":\"INSUFFICIENT_PERMISSION\"}")
        }
        lock.lock()
        setupHandoffs.insert(serverId)
        lock.unlock()
        return Self.json(200, setupProjectionJSON(serverId: serverId, userId: userId, role: "owner"))
    }

    public func enableGuestRoleTransitions(serverId: String) {
        lock.lock()
        guestRoleServers.insert(serverId)
        lock.unlock()
    }

}

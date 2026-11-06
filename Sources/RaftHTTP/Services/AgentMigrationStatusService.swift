import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Migration status seam and lifecycle bookkeeping for one agent: the
/// published status projection, cancellation, provider position and the
/// external diagnostics view.
///
/// These handlers were lifted from `EmailLogin+Agents2.swift`.

public struct AgentMigrationStatusService: Sendable {
    public let directory: EmailLoginDirectory

    public init(directory: EmailLoginDirectory) {
        self.directory = directory
    }
}

extension EmailLoginDirectory {

    public func setAgentStatusProtocolAdoptedForTesting(agentId: String, at date: Date?) {
        lock.lock()
        agentStatusProtocolAdoptedAt[agentId] = date
        lock.unlock()
    }

    public func setAgentCursorPullStateForTesting(agentId: String, lastPulledAt: Date?, pendingAcks: Int) {
        lock.lock()
        if let lastPulledAt {
            agentCursorPullState[agentId] = (lastPulledAt, pendingAcks)
        } else {
            agentCursorPullState[agentId] = nil
        }
        lock.unlock()
    }

    public func setAgentProviderPositionForTesting(
        agentId: String,
        provider: String = "antiproton",
        state: String,
        providerAgentId: String?,
        syncPending: Bool = false,
        lastErrorCode: String? = nil,
        lastErrorAt: Date? = nil,
        activatedAt: Date?
    ) {
        lock.lock()
        agentProviderPositions[agentId] = (provider, state, providerAgentId, syncPending, lastErrorCode, lastErrorAt, activatedAt)
        lock.unlock()
    }

    public func externalAgentDiagnostics(authorization: String?, serverId: String, agentId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let info = oauth.agentManagementInfo(id: agentId), !info.deleted, info.serverId == serverId,
              let role = oauth.memberRole(serverId: serverId, userId: userId)
        else {
            return Self.json(404, "{\"code\":\"agent_missing\",\"error\":\"Agent not found\"}")
        }
        guard role == "owner" || role == "admin" || info.creatorUserId == userId else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        guard info.runtime == "external" else {
            return Self.json(400, "{\"code\":\"agent_not_external\",\"error\":\"External diagnostics require an external Agent\"}")
        }
        lock.lock()
        let lastSeen = agentLastSeenAt[agentId]
        let activity = agentActivities[agentId]?.activity ?? "idle"
        let adoptedAt = agentStatusProtocolAdoptedAt[agentId]
        let webhook = externalPushWebhooks[agentId]
        let cursor = agentCursorPullState[agentId]
        let position = agentProviderPositions[agentId]
        let hosted = hostedRuntimes[agentId]
        lock.unlock()

        let online = lastSeen.map { Date().timeIntervalSince($0) <= 120 } ?? false
        let presence = "{\"lastSeenAt\":\(Self.isoOrNull(lastSeen)),\"online\":\(online),\"onlineWindowMs\":120000}"
        let status = "{\"activity\":\(jsonString(activity)),\"statusProtocolAdoptedAt\":\(Self.isoOrNull(adoptedAt))}"

        let endpointHost = webhook.flatMap { URLComponents(string: $0.url)?.host }
        let push = "{\"registered\":\(webhook != nil),\"enabled\":\(webhook != nil),\"endpointHost\":\(endpointHost.map(jsonString) ?? "null"),\"disabledReason\":null,\"disabledAt\":null,\"consecutiveFailures\":0,\"lastAttemptAt\":null,\"lastDeliveryAt\":null,\"lastError\":null,\"nextAttemptAt\":null}"

        let events = "{\"lastCursorPullAt\":\(Self.isoOrNull(cursor?.lastPulledAt)),\"pendingCursorAckCount\":\(cursor?.pendingAcks ?? 0)}"

        let provider: String
        if let position {
            let errorCode = position.lastErrorCode.map(jsonString) ?? "null"
            provider = "{\"kind\":\(jsonString(position.provider)),\"state\":\(jsonString(position.state)),\"providerAgentId\":\(position.providerAgentId.map(jsonString) ?? "null"),\"syncPending\":\(position.syncPending),\"lastErrorCode\":\(errorCode),\"lastErrorAt\":\(Self.isoOrNull(position.lastErrorAt)),\"activatedAt\":\(Self.isoOrNull(position.activatedAt))}"
        } else if let hosted {
            provider = "{\"kind\":\"antiproton\",\"state\":\(jsonString(hosted.state)),\"providerAgentId\":null,\"syncPending\":false,\"lastErrorCode\":null,\"lastErrorAt\":null,\"activatedAt\":\(Self.isoOrNull(hosted.createdAt))}"
        } else {
            provider = "null"
        }

        let connections: String
        if hosted != nil {
            connections = "[{\"provider\":\"github\",\"state\":\"unavailable\",\"account\":null,\"reason\":\"Cloud connections are not enabled for this server\"}]"
        } else {
            connections = "[{\"provider\":\"github\",\"state\":\"not_applicable\",\"account\":null,\"reason\":null}]"
        }

        return Self.json(200, "{\"agentId\":\(jsonString(agentId)),\"runtime\":\"external\",\"provider\":\(provider),\"presence\":\(presence),\"status\":\(status),\"push\":\(push),\"events\":\(events),\"connections\":\(connections)}")
    }

    public func agentMigrationStatus(authorization: String?, serverId: String, agentId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let info = oauth.agentManagementInfo(id: agentId), !info.deleted, info.serverId == serverId,
              let role = oauth.memberRole(serverId: serverId, userId: userId)
        else {
            return Self.json(404, "{\"code\":\"agent_missing\",\"error\":\"Agent not found\"}")
        }
        guard role == "owner" || role == "admin" || info.creatorUserId == userId else {
            return Self.json(403, "{\"code\":\"not_supported\",\"error\":\"Agent migration status requires creator or server admin authority\"}")
        }
        lock.lock()
        let hosted = hostedMigrations[agentId]
        let machine = machineMigrations.values.first { $0.agentId == agentId && $0.serverId == serverId }
        lock.unlock()
        if let hosted {
            return Self.json(200, "{\"migration\":\(migrationStatusJSON(hosted))}")
        }
        if let machine {
            return Self.json(200, "{\"migration\":\(machineMigrationStatusJSON(machine))}")
        }
        return Self.json(200, "{\"migration\":null}")
    }

    func machineMigrationStatusJSON(_ migration: MachineMigrationRecord) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func timestamp(_ date: Date?) -> String {
            date.map { jsonString(formatter.string(from: $0)) } ?? "null"
        }
        let canceledAt = timestamp(migration.canceledAt)
        let cancelReason = migration.cancelReason.map(jsonString) ?? "null"
        let cancelLastDispatchAt = timestamp(migration.cancelLastDispatchAt)
        let cancelErrorCode = migration.cancelErrorCode.map(jsonString) ?? "null"
        let failureReason = migration.failureReason.map(jsonString) ?? "null"
        let transportErrorCode = migration.transportErrorCode.map(jsonString) ?? "null"
        let transportErrorMessage = migration.transportErrorMessage.map(jsonString) ?? "null"
        let transportLostAt = timestamp(migration.transportLostAt)
        let transportTeardownAt = timestamp(migration.transportTeardownAt)
        let autoStartFailureStage = migration.autoStartFailureStage.map(jsonString) ?? "null"
        let autoStartFailureCode = migration.autoStartFailureCode.map(jsonString) ?? "null"
        return "{\"migrationRef\":\(jsonString(migration.supportRef)),\"agentId\":\(jsonString(migration.agentId)),\"state\":\(jsonString(migration.state)),\"revision\":\(migration.revision),\"sourceMachineId\":\(jsonString(migration.sourceMachineId)),\"targetKind\":\"computer\",\"targetMachineId\":\(jsonString(migration.targetMachineId)),\"provider\":\(jsonString(migration.transportProvider)),\"failureReason\":\(failureReason),\"autoStartFailureStage\":\(autoStartFailureStage),\"autoStartFailureCode\":\(autoStartFailureCode),\"abortReason\":null,\"transportErrorCode\":\(transportErrorCode),\"transportErrorMessage\":\(transportErrorMessage),\"transportLostAt\":\(transportLostAt),\"transportTeardownAt\":\(transportTeardownAt),\"readyAt\":null,\"flippedAt\":\(timestamp(migration.flippedAt)),\"arrivedAt\":\(timestamp(migration.arrivedAt)),\"completedAt\":\(timestamp(migration.completedAt)),\"abortedAt\":null,\"canceledAt\":\(canceledAt),\"cancelReason\":\(cancelReason),\"cancelNeedsAttention\":false,\"cancelDispatchAttempts\":\(migration.cancelDispatchAttempts),\"cancelLastDispatchAt\":\(cancelLastDispatchAt),\"cancelErrorCode\":\(cancelErrorCode),\"cancelErrorMessage\":null}"
    }

    public func agentMigrationCancel(authorization: String?, serverId: String, agentId: String, body: String = "") -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let info = oauth.agentManagementInfo(id: agentId), !info.deleted, info.serverId == serverId,
              let role = oauth.memberRole(serverId: serverId, userId: userId)
        else {
            return Self.json(404, "{\"code\":\"agent_missing\",\"error\":\"Agent not found\"}")
        }
        guard role == "owner" || role == "admin" || info.creatorUserId == userId else {
            return Self.json(403, "{\"code\":\"not_supported\",\"error\":\"Agent migration cancel requires creator or server admin authority\"}")
        }
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
        if object["migrationId"] != nil {
            return Self.json(400, "{\"code\":\"MIGRATION_REF_INVALID\",\"error\":\"migrationRef is required\"}")
        }
        guard let migrationRef = object["migrationRef"] as? String,
              migrationRef.range(of: "^mig_[A-Za-z0-9_-]{22}$", options: .regularExpression) != nil
        else {
            return Self.json(400, "{\"code\":\"MIGRATION_REF_INVALID\",\"error\":\"migrationRef is required\"}")
        }
        guard let rawRevision = object["expectedRevision"] as? NSNumber,
              rawRevision.doubleValue.rounded() == rawRevision.doubleValue,
              rawRevision.intValue >= 1
        else {
            return Self.json(400, "{\"code\":\"MIGRATION_REVISION_INVALID\",\"error\":\"expectedRevision must be a positive integer\"}")
        }
        let expectedRevision = rawRevision.intValue
        lock.lock()
        let hosted = hostedMigrations[agentId].flatMap { candidate in
            candidate.supportRef == migrationRef && candidate.serverId == serverId ? candidate : nil
        }
        let machine = machineMigrations[migrationRef].flatMap { candidate in
            candidate.agentId == agentId && candidate.serverId == serverId ? candidate : nil
        }
        guard hosted != nil || machine != nil else {
            lock.unlock()
            return Self.json(404, "{\"code\":\"MIGRATION_NOT_FOUND\",\"error\":\"Migration not found\"}")
        }
        let revision = hosted?.revision ?? machine!.revision
        guard revision == expectedRevision else {
            lock.unlock()
            return Self.json(409, "{\"code\":\"MIGRATION_REVISION_STALE\",\"error\":\"The migration changed since this action was shown\"}")
        }
        let state = hosted?.state ?? machine!.state
        guard !["canceled_pre_flip", "arrived", "completed", "aborted", "failed"].contains(state) else {
            lock.unlock()
            return Self.json(409, "{\"code\":\"MIGRATION_NOT_CANCELABLE\",\"error\":\"This migration can no longer be canceled\"}")
        }
        let now = Date()
        let reason = (object["reason"] as? String) ?? "user_canceled"
        if var migration = hosted {
            migration.state = "canceled_pre_flip"
            migration.revision += 1
            migration.canceledAt = now
            migration.cancelReason = reason
            migration.cancelDispatchAttempts = 1
            migration.cancelLastDispatchAt = now
            migration.cancelErrorCode = nil
            hostedMigrations[agentId] = migration
            lock.unlock()
            for member in oauth.memberIdsWithRoles(serverId: serverId) where member.role == "owner" || member.role == "admin" {
                emitRealtime("user:\(member.id)", "agent:migration-updated", migrationUpdatedJSON(migration))
            }
            return Self.json(200, "{\"migration\":\(migrationStatusJSON(migration))}")
        }
        var migration = machine!
        // Once the flip committed the agent belongs to the target, so the
        // cancellation is target-authoritative even though the agent may still
        // be arriving/starting.
        let postFlip = migration.flippedAt != nil
            || ["arriving", "starting", "completed"].contains(migration.state)
        migration.state = postFlip ? "canceled_post_flip" : "canceled_pre_flip"
        migration.revision += 1
        migration.canceledAt = now
        migration.cancelReason = reason
        migration.cancelDispatchAttempts = 1
        migration.cancelLastDispatchAt = now
        migration.cancelErrorCode = nil
        migration.cancelGeneration = UUID().uuidString.lowercased()
        migration.cancelTransportGeneration = migration.transportGeneration
        migration.cancelDisposition = postFlip ? "post_flip_target_authoritative" : "pre_flip_source_authoritative"
        migration.cancelSourceAck = nil
        migration.cancelTargetAck = nil
        migration.cancelSourceAckAt = nil
        migration.cancelTargetAckAt = nil
        migration.transportTeardownAt = now
        migration.updatedAt = now
        machineMigrations[migrationRef] = migration
        lock.unlock()
        agentMigrationCancelDispatch?(migration.sourceMachineId, "source", migration.supportRef, migration.transportGeneration, false)
        agentMigrationCancelDispatch?(migration.targetMachineId, "target", migration.supportRef, migration.transportGeneration, false)
        for member in oauth.memberIdsWithRoles(serverId: serverId) where member.role == "owner" || member.role == "admin" {
            emitRealtime("user:\(member.id)", "agent:migration-updated", migrationUpdatedJSON(migration))
        }
        return Self.json(200, "{\"migration\":\(machineMigrationStatusJSON(migration))}")
    }

}

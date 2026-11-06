import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Server usage, system attention and agent-attestation read models:
/// share artifacts, transcripts and mention-delivery diagnostics.
///
/// These handlers were lifted from `EmailLogin+ComputersUsage1.swift`.

public struct RuntimeUsageAndAttestationsService: Sendable {
    public let directory: EmailLoginDirectory

    public init(directory: EmailLoginDirectory) {
        self.directory = directory
    }
}

extension EmailLoginDirectory {

    public func serverUsage(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(404, "{\"error\":\"Server not found\"}")
        }
        guard role != "guest" else {
            return Self.json(403, "{\"error\":\"Guests cannot access server management data\"}")
        }
        let agents = oauth.serverAgents(serverId: serverId).count
        lock.lock()
        let machinesCount = machines.filter { $0.serverId == serverId }.count
        lock.unlock()
        let channels = oauth.channelsForServer(serverId: serverId, userId: userId, includeArchived: true)
            .filter { ($0.type == "channel" || $0.type == "private") && oauth.channelArchivedAt(id: $0.id) == nil }
            .count
        return Self.json(200, "{\"agents\":\(agents),\"machines\":\(machinesCount),\"channels\":\(channels)}")
    }

    public func serverSystemNotifications(authorization: String?, serverId: String) -> HTTPReply {        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        let generatedAt = Date()
        if role == "guest" {
            return Self.json(200, serverSystemNotificationsBody(generatedAt: generatedAt, notifications: []))
        }
        lock.lock()
        let rows = machines.filter { $0.serverId == serverId }
        let online = machineOnline
        let computerMachineIds = Set(computers.compactMap { computer -> String? in
            guard computer.serverId == serverId, computer.revokedAt == nil else { return nil }
            return computer.machineId
        })
        var activeByMachine: [String: Int] = [:]
        for agent in serverAgents.values where agent.serverId == serverId && agent.status == "active" {
            if let machineId = agentMachineIds[agent.id] {
                activeByMachine[machineId, default: 0] += 1
            }
        }
        lock.unlock()

        let rawDaemons = rows
            .filter { !computerMachineIds.contains($0.id) }
            .sorted { $0.id < $1.id }
        let offline = rawDaemons.filter { online[$0.id] != true }
        var notifications: [String] = []
        if !offline.isEmpty {
            let activeCount = offline.reduce(0) { $0 + (activeByMachine[$1.id] ?? 0) }
            let names = offline.map(\.name).joined(separator: ", ")
            let singular = offline.count == 1
            let title = "\(names) \(singular ? "is" : "are") offline"
            let body = activeCount > 0
                ? "\(activeCount) \(activeCount == 1 ? "agent is" : "agents are") active on \(singular ? "this computer" : "these computers") and can't run until \(singular ? "it reconnects" : "they reconnect")."
                : "No agents are active on \(singular ? "this computer" : "these computers") right now — reconnect when you need \(singular ? "it" : "them") next."
            let ids = offline.map(\.id).joined(separator: ",")
            let machineRefs = offline.map {
                "{\"id\":\(jsonString($0.id)),\"name\":\(jsonString($0.name))}"
            }.joined(separator: ",")
            let copyTitle = singular ? "machine.offline.title.one" : "machine.offline.title.many"
            let copyBody = activeCount > 0
                ? (singular ? "machine.offline.body.active.one" : "machine.offline.body.active.many")
                : (singular ? "machine.offline.body.idle.one" : "machine.offline.body.idle.many")
            let evaluation = "{\"clock\":\"server\",\"evaluatedAt\":\(jsonString(Self.isoString(generatedAt))),\"offlineAfterMs\":0,\"statusAuthority\":\"canonical_machine_read_model\",\"runKind\":\"raw_daemon\",\"versionAuthority\":\"latest_daemon_release\"}"
            let notification = "{\"id\":\(jsonString("machine-offline:\(ids)")),\"type\":\"machine.offline\",\"schemaVersion\":1,\"state\":\"active\",\"kind\":\"\(activeCount > 0 ? "error" : "warning")\",\"title\":\(jsonString(title)),\"body\":\(jsonString(body)),\"copy\":{\"titleKey\":\(jsonString(copyTitle)),\"bodyKey\":\(jsonString(copyBody)),\"actionLabelKey\":\"common.view\",\"params\":{\"machineNames\":\(jsonString(names)),\"machineCount\":\(offline.count),\"activeAgentCount\":\(activeCount),\"targetDaemonVersion\":null}},\"action\":{\"label\":\"View\",\"targetType\":\"machine\",\"targetId\":\(jsonString(offline[0].id))},\"payload\":{\"machines\":[\(machineRefs)],\"activeAgentCount\":\(activeCount),\"targetDaemonVersion\":null,\"evaluation\":\(evaluation)}}"
            notifications.append(notification)
        }
        return Self.json(200, serverSystemNotificationsBody(generatedAt: generatedAt, notifications: notifications))
    }

    func serverSystemNotificationsBody(generatedAt: Date, notifications: [String]) -> String {
        "{\"contractVersion\":\"server-system-notifications-v1\",\"generatedAt\":\(jsonString(Self.isoString(generatedAt))),\"snapshotMode\":\"replace\",\"clientState\":{\"read\":\"none\",\"dismiss\":\"local_by_notification_id\"},\"notifications\":[\(notifications.joined(separator: ","))]}"
    }

    public func enableUsageLimitAttentionForServer(_ serverId: String) {
        lock.lock()
        usageLimitAttentionServers.insert(serverId)
        lock.unlock()
    }

    public func disableUsageLimitAttentionForServer(_ serverId: String) {
        lock.lock()
        usageLimitAttentionServers.remove(serverId)
        lock.unlock()
    }

    @discardableResult
    public func addSystemAttentionIncidentForTesting(
        serverId: String,
        machineId: String,
        provider: String = "codex",
        windowKey: String = "primary",
        affectedAgentIds: [String] = [],
        activatedAt: Date = Date(),
        resetsAt: Date? = nil
    ) -> String {
        lock.lock()
        let generation = (systemAttentionIncidents
            .filter { $0.serverId == serverId && $0.machineId == machineId && $0.provider == provider && $0.windowKey == windowKey }
            .map(\.activationGeneration)
            .max() ?? 0) + 1
        let id = UUID().uuidString.lowercased()
        systemAttentionIncidents.append(SystemAttentionIncident(
            id: id,
            serverId: serverId,
            machineId: machineId,
            provider: provider,
            windowKey: windowKey,
            activationGeneration: generation,
            affectedAgentIds: affectedAgentIds,
            activatedAt: activatedAt,
            lastObservedAt: activatedAt,
            resetsAt: resetsAt,
            state: "active"
        ))
        lock.unlock()
        return id
    }

    public func listSystemAttention(authorization: String?, serverId: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        let generatedAt = Date()
        let role = oauth.memberRole(serverId: serverId, userId: userId)
        guard role == "owner" || role == "admin" else {
            return Self.json(200, systemAttentionBody(generatedAt: generatedAt, notifications: []))
        }
        lock.lock()
        guard usageLimitAttentionServers.contains(serverId) else {
            lock.unlock()
            return Self.json(200, systemAttentionBody(generatedAt: generatedAt, notifications: []))
        }
        let incidents = systemAttentionIncidents
            .filter { $0.serverId == serverId && $0.state == "active" }
            .filter { systemAttentionReceipts["\($0.id)\n\(userId)"]?.dismissedAt == nil }
            .sorted { $0.activatedAt > $1.activatedAt }
        let notifications = incidents.map { incident -> String in
            let seenAt = systemAttentionReceipts["\(incident.id)\n\(userId)"]?.seenAt.map { jsonString(Self.isoString($0)) } ?? "null"
            let resetsAt = incident.resetsAt.map { jsonString(Self.isoString($0)) } ?? "null"
            let machineName = machines.first { $0.id == incident.machineId }?.name ?? ""
            let affected = incident.affectedAgentIds.map(jsonString).joined(separator: ",")
            return "{\"id\":\(jsonString(incident.id)),\"kind\":\"usage_limit_reached\",\"severity\":\"warning\",\"state\":\"active\",\"activatedAt\":\(jsonString(Self.isoString(incident.activatedAt))),\"lastObservedAt\":\(jsonString(Self.isoString(incident.lastObservedAt))),\"seenAt\":\(seenAt),\"machine\":{\"id\":\(jsonString(incident.machineId)),\"name\":\(jsonString(machineName))},\"provider\":\(jsonString(incident.provider)),\"windowKey\":\(jsonString(incident.windowKey)),\"resetsAt\":\(resetsAt),\"affectedAgentIds\":[\(affected)]}"
        }
        lock.unlock()
        return Self.json(200, systemAttentionBody(generatedAt: generatedAt, notifications: notifications))
    }

    public func markSystemAttentionSeen(authorization: String?, serverId: String, incidentId: String) -> HTTPReply {
        systemAttentionReceipt(authorization: authorization, serverId: serverId, incidentId: incidentId, dismiss: false)
    }

    public func dismissSystemAttention(authorization: String?, serverId: String, incidentId: String) -> HTTPReply {
        systemAttentionReceipt(authorization: authorization, serverId: serverId, incidentId: incidentId, dismiss: true)
    }

    func systemAttentionReceipt(
        authorization: String?,
        serverId: String,
        incidentId: String,
        dismiss: Bool
    ) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard ServerScope.isUUID(incidentId) else {
            return Self.json(400, "{\"error\":\"Invalid system attention incident\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) == "owner"
                || oauth.memberRole(serverId: serverId, userId: userId) == "admin"
        else {
            return Self.json(404, "{\"error\":\"System attention incident not found\"}")
        }
        lock.lock()
        guard usageLimitAttentionServers.contains(serverId),
              systemAttentionIncidents.contains(where: {
                  $0.id == incidentId && $0.serverId == serverId && $0.state == "active"
              })
        else {
            lock.unlock()
            return Self.json(404, "{\"error\":\"System attention incident not found\"}")
        }
        let key = "\(incidentId)\n\(userId)"
        let now = Date()
        var receipt = systemAttentionReceipts[key] ?? SystemAttentionReceipt(seenAt: nil, dismissedAt: nil)
        if receipt.seenAt == nil { receipt.seenAt = now }
        if dismiss { receipt.dismissedAt = now }
        systemAttentionReceipts[key] = receipt
        lock.unlock()
        return Self.json(200, "{\"ok\":true}")
    }

    func systemAttentionBody(generatedAt: Date, notifications: [String]) -> String {
        let unseen = notifications.reduce(0) { count, notification in
            count + (notification.contains("\"seenAt\":null") ? 1 : 0)
        }
        return "{\"contractVersion\":\"server-system-attention-v1\",\"generatedAt\":\(jsonString(Self.isoString(generatedAt))),\"snapshotMode\":\"replace\",\"unseenCount\":\(unseen),\"notifications\":[\(notifications.joined(separator: ","))]}"
    }

    public func mentionDeliveryDiagnostic(
        authorization: String?,
        serverId: String,
        machineId: String,
        agentId: String,
        messageId: String
    ) -> HTTPReply {
        guard ServerScope.isUUID(messageId) else {
            return Self.json(404, "{\"status\":\"NOT_JOINABLE\"}")
        }
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId),
              let agent = oauth.agentRuntimeInfo(id: agentId),
              agent.serverId == serverId, !agent.deleted
        else {
            return Self.json(404, "{\"status\":\"NOT_ACCESSIBLE\"}")
        }
        lock.lock()
        let machineMatches = machines.contains { $0.id == machineId && $0.serverId == serverId }
        let assigned = agentMachineIds[agentId] == machineId
        lock.unlock()
        guard machineMatches, assigned else {
            return Self.json(404, "{\"status\":\"NOT_ACCESSIBLE\"}")
        }
        guard role == "owner" || role == "admin" || agent.creatorUserId == userId else {
            return Self.json(404, "{\"status\":\"NOT_ACCESSIBLE\"}")
        }
        return Self.json(404, "{\"status\":\"NOT_JOINABLE\"}")
    }

    public func agentSessionTranscript(
        authorization: String?,
        serverId: String,
        machineId: String,
        agentId: String
    ) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(404, "{\"error\":\"Server not found\"}")
        }
        lock.lock()
        let machineExists = machines.contains { $0.id == machineId && $0.serverId == serverId }
        let assignedMachine = agentMachineIds[agentId]
        let online = machineOnline[machineId] == true
        lock.unlock()
        guard machineExists else {
            return Self.json(404, "{\"error\":\"Machine not found in this server\"}")
        }
        guard let agent = oauth.agentRuntimeInfo(id: agentId), agent.serverId == serverId, !agent.deleted else {
            return Self.json(404, "{\"error\":\"Agent not found in this server\"}")
        }
        guard assignedMachine == machineId else {
            return Self.json(400, "{\"error\":\"Agent is not assigned to this machine\"}")
        }
        guard role == "owner" || role == "admin" || agent.creatorUserId == userId else {
            return Self.json(403, "{\"error\":\"The `editAgents` capability or human creator authority is required to view agent diagnostics\"}")
        }
        guard online else {
            return Self.json(409, "{\"error\":\"Computer is offline\",\"code\":\"machine_offline\"}")
        }
        return Self.json(200, "{\"sessionId\":null,\"transcript\":[]}")
    }

    public func redriveMentionDelivery(
        authorization: String?,
        serverId: String,
        machineId: String,
        agentId: String,
        messageId: String,
        body: String
    ) -> HTTPReply {
        guard ServerScope.isUUID(messageId) else {
            return Self.json(404, "{\"status\":\"NOT_JOINABLE\"}")
        }
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId),
              let agent = oauth.agentRuntimeInfo(id: agentId),
              agent.serverId == serverId, !agent.deleted
        else {
            return Self.json(404, "{\"status\":\"NOT_ACCESSIBLE\"}")
        }
        lock.lock()
        let machineMatches = machines.contains { $0.id == machineId && $0.serverId == serverId }
        let assigned = agentMachineIds[agentId] == machineId
        lock.unlock()
        guard machineMatches, assigned else {
            return Self.json(404, "{\"status\":\"NOT_ACCESSIBLE\"}")
        }
        guard role == "owner" || role == "admin" || agent.creatorUserId == userId else {
            return Self.json(404, "{\"status\":\"NOT_ACCESSIBLE\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              object.count == 1,
              let version = object["expectedVersion"] as? NSNumber,
              version.doubleValue.rounded() == version.doubleValue,
              version.intValue >= 0
        else {
            return Self.json(400, "{\"status\":\"INVALID_REQUEST\"}")
        }
        return Self.json(404, "{\"status\":\"NOT_JOINABLE\"}")
    }

    public func submitTranscriptFeedback(
        authorization: String?,
        serverId: String,
        agentId: String,
        reportId: String,
        body: String
    ) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard reportId.wholeMatch(of: /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) != nil else {
            return Self.json(404, "{\"error\":\"Not found\"}")
        }
        guard let agent = oauth.agentRuntimeInfo(id: agentId), agent.serverId == serverId, !agent.deleted else {
            return Self.json(404, "{\"error\":\"Agent not found\"}")
        }
        guard role == "owner" || role == "admin" || agent.creatorUserId == userId else {
            return Self.json(403, "{\"error\":\"Forbidden\"}")
        }
        if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
                return Self.json(400, "{\"error\":\"Invalid transcript request\"}")
            }
            if let raw = object["reportGeneratedAt"], !(raw is NSNull) {
                let fractional = ISO8601DateFormatter()
                fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                guard let text = raw as? String,
                      fractional.date(from: text) != nil || ISO8601DateFormatter().date(from: text) != nil
                else {
                    return Self.json(400, "{\"error\":\"reportGeneratedAt must be an ISO timestamp\"}")
                }
            }
        }
        return Self.json(202, "{\"accepted\":true,\"feedbackReportId\":\(jsonString(reportId)),\"agentId\":\(jsonString(agentId))}")
    }

    /// `POST /api/share-artifacts/message-selection`. A PNG screenshot becomes a
    /// public share page plus the image behind it. The image bytes are served
    /// back exactly as uploaded, so the OG card advertises the real dimensions.
    public func createShareArtifact(
        authorization: String?,
        serverId: String,
        channelId: String?,
        image: (bytes: Data, sizeBytes: Int)?,
        serverBase: String,
        shareBase: String,
        cdnBase: String?
    ) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard role != "guest" else {
            return Self.json(403, "{\"error\":\"Guests cannot create share artifacts\"}")
        }
        let maxBytes = 10 * 1024 * 1024
        guard let image, image.sizeBytes > 0, !image.bytes.isEmpty else {
            return Self.json(400, "{\"error\":\"image is required\"}")
        }
        guard image.sizeBytes <= maxBytes else {
            return Self.json(413, "{\"error\":\"Max 10MB per image\",\"errorCode\":\"SHARE_ARTIFACT_TOO_LARGE\",\"maxBytes\":\(maxBytes)}")
        }
        guard Self.isPNGBytes(image.bytes) else {
            return Self.json(415, "{\"error\":\"Share artifact must be a PNG image\"}")
        }
        guard let channelId else {
            return Self.json(400, "{\"error\":\"channelId is required\"}")
        }
        switch taskChannelAccess(serverId: serverId, channelId: channelId, userId: userId) {
        case .missing:
            return Self.json(403, "{\"error\":\"You do not have access to this channel\"}")
        case .readOnly, .write:
            break
        }
        let id = UUID().uuidString.lowercased()
        let size = Self.pngDimensions(image.bytes)
        lock.lock()
        shareArtifacts[id] = ShareArtifactRecord(
            bytes: image.bytes,
            width: size.width,
            height: size.height,
            serverId: serverId,
            createdAt: Date()
        )
        lock.unlock()
        return Self.json(200, "{\"id\":\(jsonString(id)),\"url\":\(jsonString(Self.shareURL(id: id, shareBase: shareBase))),\"imageUrl\":\(jsonString(Self.shareImageURL(id: id, serverId: serverId, serverBase: serverBase, cdnBase: cdnBase)))}")
    }

    static func isPNGBytes(_ data: Data) -> Bool {
        data.count >= 8 && data.prefix(8).elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    /// Width and height from the PNG IHDR chunk, falling back to 1x1.
    static func pngDimensions(_ data: Data) -> (width: Int, height: Int) {
        guard data.count >= 24 else { return (1, 1) }
        let bytes = [UInt8](data[16..<24])
        let width = bytes[0..<4].reduce(0) { $0 << 8 | Int($1) }
        let height = bytes[4..<8].reduce(0) { $0 << 8 | Int($1) }
        return (width > 0 ? width : 1, height > 0 ? height : 1)
    }

    static func shareURL(id: String, shareBase: String) -> String {
        let base = shareBase.hasSuffix("/") ? String(shareBase.dropLast()) : shareBase
        return base + "/" + id
    }

    static func shareImageURL(id: String, serverId: String, serverBase: String, cdnBase: String?) -> String {
        if let cdnBase {
            let base = cdnBase.hasSuffix("/") ? String(cdnBase.dropLast()) : cdnBase
            return "\(base)/\(serverId)/share-artifacts/\(id).png"
        }
        let base = serverBase.hasSuffix("/") ? String(serverBase.dropLast()) : serverBase
        return base + "/share/" + id + ".png"
    }

}

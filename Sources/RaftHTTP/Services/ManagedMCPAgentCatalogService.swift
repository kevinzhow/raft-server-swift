import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Task idempotency, reminders and the MCP agent catalog-adjacent routes.
/// Migrated verbatim from the first half of `EmailLogin+ManagedMCP2.swift`.
///
/// The handlers stay on `EmailLoginDirectory`, which owns the lock and the
/// domain ledgers. This type is the named, `Sendable` handle a route can hold
/// instead of reaching for the composition root; it carries no state of its own.
public struct ManagedMCPAgentCatalogService: Sendable {
    public let directory: EmailLoginDirectory

    public init(directory: EmailLoginDirectory) {
        self.directory = directory
    }
}

extension EmailLoginDirectory {
    func orderedTasks(
        serverId: String,
        userId: String,
        status: String?
    ) -> [(task: TaskRecord, channelName: String, channelType: String)] {
        let visible = oauth.channelsForServer(serverId: serverId, userId: userId).filter {
            $0.joined && ($0.type == "channel" || $0.type == "joint")
                && oauth.channelArchivedAt(id: $0.id) == nil
        }
        let names = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0.name) })
        let types = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0.type) })
        lock.lock()
        let rows = taskRecords.filter {
            names[$0.channelId] != nil && (status == nil || $0.status == status)
        }
        lock.unlock()
        return rows
            .map { (task: $0, channelName: names[$0.channelId] ?? "", channelType: types[$0.channelId] ?? "channel") }
            .sorted {
                if $0.channelName != $1.channelName { return $0.channelName < $1.channelName }
                if $0.task.taskNumber != $1.task.taskNumber { return $0.task.taskNumber < $1.task.taskNumber }
                return $0.task.id < $1.task.id
            }
    }

    func legacyTasksBody(serverId: String, userId: String, status: String?) -> String {
        let ordered = orderedTasks(serverId: serverId, userId: userId, status: status)
        let items = ordered.map { entry in
            fullTaskJSON(entry.task, channelName: entry.channelName, channelType: entry.channelType)
        }.joined(separator: ",")
        return "{\"tasks\":[\("\(items)")]}"
    }



    func fullTaskJSON(_ task: TaskRecord, channelName: String, channelType: String) -> String {
        let description = task.description.map { jsonString($0) } ?? "null"
        return "{\"id\":\(jsonString(task.id)),\"channelId\":\(jsonString(task.channelId)),\"channelName\":\(jsonString(channelName)),\"channelType\":\(jsonString(channelType)),\"title\":\(jsonString(task.title)),\"description\":\(description),\"status\":\(jsonString(task.status)),\"taskNumber\":\(task.taskNumber),\"messageId\":\(jsonString(task.messageId)),\"revision\":\(task.revision)}"
    }

    func summaryTaskJSON(_ task: TaskRecord, channelName: String, channelType: String) -> String {
        let descriptionBytes = task.description.map { Data($0.utf8).count } ?? 0
        let hasDescription = task.description != nil && !(task.description ?? "").isEmpty
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let claimed = task.claimedAt.map { jsonString(formatter.string(from: $0)) } ?? "null"
        let completed = task.completedAt.map { jsonString(formatter.string(from: $0)) } ?? "null"
        let updated = task.updatedAt.map { jsonString(formatter.string(from: $0)) } ?? "null"
        let createdAt = jsonString(formatter.string(from: task.createdAt))
        let assignee = task.assigneeId.map { jsonString($0) } ?? "null"
        let assigneeType = task.assigneeType.map { jsonString($0) } ?? "null"
        var claimedByName = "null"
        if let assigneeId = task.assigneeId {
            lock.lock()
            if task.assigneeType == "agent", let agent = oauth.agentRuntimeInfo(id: assigneeId) {
                claimedByName = jsonString(agent.name)
            } else if let name = accounts.values.first(where: { $0.id == assigneeId })?.name {
                claimedByName = jsonString(name)
            }
            lock.unlock()
        }
        var createdById = "null"
        var createdByName = "null"
        var createdByType = "null"
        if let creatorId = task.creatorId {
            lock.lock()
            if let agent = oauth.agentRuntimeInfo(id: creatorId) {
                createdById = jsonString(creatorId)
                createdByName = jsonString(agent.name)
                createdByType = jsonString("agent")
            } else if let name = accounts.values.first(where: { $0.id == creatorId })?.name {
                createdById = jsonString(creatorId)
                createdByName = jsonString(name)
                createdByType = jsonString("user")
            }
            lock.unlock()
        }
        return "{\"channelId\":\(jsonString(task.channelId)),\"channelName\":\(jsonString(channelName)),\"channelType\":\(jsonString(channelType)),\"claimedAt\":\(claimed),\"claimedById\":\(assignee),\"claimedByName\":\(claimedByName),\"claimedByType\":\(assigneeType),\"completedAt\":\(completed),\"createdAt\":\(createdAt),\"createdById\":\(createdById),\"createdByName\":\(createdByName),\"createdByType\":\(createdByType),\"descriptionBytes\":\(descriptionBytes),\"hasDescription\":\(hasDescription),\"id\":\(jsonString(task.id)),\"isLegacy\":false,\"messageId\":\(jsonString(task.messageId)),\"readOnlyReason\":null,\"revision\":\(task.revision),\"source\":\"tasks\",\"status\":\(jsonString(task.status)),\"taskNumber\":\(task.taskNumber),\"title\":\(jsonString(task.title)),\"updatedAt\":\(updated)}"
    }








    public func taskRevisionForTesting(taskId: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return taskRecords.first(where: { $0.id == taskId })?.revision
    }

    public func taskClaimedAtForTesting(taskId: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return taskRecords.first(where: { $0.id == taskId })?.claimedAt
    }

    public func setTaskStatusForTesting(taskId: String, status: String) {
        lock.lock()
        if let index = taskRecords.firstIndex(where: { $0.id == taskId }) {
            taskRecords[index].status = status
        }
        lock.unlock()
    }


    static let agentApiIdempotencyTTL: TimeInterval = 24 * 60 * 60



    func agentApiIdempotencyReply(agentId: String, route: String, object: [String: Any]) -> HTTPReply? {
        let rawKey = (object["idempotencyKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawKey.isEmpty else { return nil }
        let fingerprint = Self.agentApiRequestFingerprint(object)
        let now = Date()
        lock.lock()
        let existing = agentApiIdempotencyKeys.first { $0.agentId == agentId && $0.route == route && $0.key == rawKey }
        if let existing, now.timeIntervalSince(existing.createdAt) < Self.agentApiIdempotencyTTL {
            let reply: HTTPReply
            if existing.fingerprint == fingerprint {
                reply = HTTPReply(status: existing.status, headers: ["Content-Type": AppFallback.jsonContentType, "Cache-Control": "no-store", "Content-Length": String(existing.responseBody.utf8.count)], body: existing.responseBody)
            } else {
                reply = Self.json(409, "{\"error\":\"This idempotencyKey was already used for a different request\",\"code\":\"idempotency_key_reused\",\"mismatch\":\"request\",\"suggestedNextAction\":\"Retry with a new idempotencyKey.\"}")
            }
            lock.unlock()
            return reply
        }
        lock.unlock()
        return nil
    }

    func storeAgentApiIdempotency(agentId: String, route: String, object: [String: Any], reply: HTTPReply) {
        guard reply.status == 200 || reply.status == 201 else { return }
        let rawKey = (object["idempotencyKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawKey.isEmpty else { return }
        let fingerprint = Self.agentApiRequestFingerprint(object)
        lock.lock()
        if let index = agentApiIdempotencyKeys.firstIndex(where: { $0.agentId == agentId && $0.route == route && $0.key == rawKey }) {
            agentApiIdempotencyKeys.remove(at: index)
        }
        agentApiIdempotencyKeys.append(AgentApiIdempotencyRecord(
            agentId: agentId, route: route, key: rawKey, fingerprint: fingerprint,
            status: reply.status, responseBody: reply.body, createdAt: Date()
        ))
        lock.unlock()
    }

    public func taskCountForTesting(channelId: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return taskRecords.filter { $0.channelId == channelId }.count
    }

    public func actionCardCountForTesting(agentId: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return actionCardRecords.values.filter { $0.requesterAgentId == agentId }.count
    }

    public func agentApiIdempotencyKeysForTesting(agentId: String, route: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return agentApiIdempotencyKeys.filter { $0.agentId == agentId && $0.route == route }.map(\.key)
    }

    public func ageAgentApiIdempotencyKeysForTesting(agentId: String, seconds: TimeInterval) {
        lock.lock()
        for index in agentApiIdempotencyKeys.indices where agentApiIdempotencyKeys[index].agentId == agentId {
            agentApiIdempotencyKeys[index].createdAt = agentApiIdempotencyKeys[index].createdAt.addingTimeInterval(-seconds)
        }
        lock.unlock()
    }

    @discardableResult
    public func pruneAgentApiIdempotencyKeysForTesting(now: Date = Date(), batchSize: Int = 3, maxBatches: Int = Int.max) -> Int {
        var deleted = 0
        var batches = 0
        lock.lock()
        while batches < maxBatches {
            let expired = agentApiIdempotencyKeys.enumerated()
                .filter { now.timeIntervalSince($0.element.createdAt) >= Self.agentApiIdempotencyTTL }
                .sorted { $0.element.createdAt < $1.element.createdAt }
            guard !expired.isEmpty else { break }
            let slice = expired.prefix(max(1, batchSize))
            for entry in slice.reversed() { agentApiIdempotencyKeys.remove(at: entry.offset) }
            deleted += slice.count
            batches += 1
            if slice.count < batchSize { break }
        }
        lock.unlock()
        return deleted
    }

    public func assigneeChangeEventsForTesting(taskId: String) -> [(
        assigneeId: String?, assigneeType: String?, previousAssigneeId: String?,
        previousAssigneeType: String?, actorType: String, actorId: String
    )] {
        lock.lock()
        defer { lock.unlock() }
        return assigneeChangeEvents.filter { $0.taskId == taskId }.map {
            ($0.assigneeId, $0.assigneeType, $0.previousAssigneeId, $0.previousAssigneeType, $0.actorType, $0.actorId)
        }
    }

    public func taskStatusForTesting(taskId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return taskRecords.first { $0.id == taskId }?.status
    }

    public func taskCompletedAtForTesting(taskId: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return taskRecords.first { $0.id == taskId }?.completedAt
    }

    public func taskClosedAtForTesting(taskId: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return taskRecords.first { $0.id == taskId }?.closedAt
    }

    public func setTaskAssigneeForTesting(taskId: String, type: String, id: String) {
        lock.lock()
        if let index = taskRecords.firstIndex(where: { $0.id == taskId }) {
            taskRecords[index].assigneeType = type
            taskRecords[index].assigneeId = id
            taskRecords[index].claimedAt = Date()
        }
        lock.unlock()
    }

    public func reopenTaskForTesting(taskId: String, status: String) {
        lock.lock()
        if let index = taskRecords.firstIndex(where: { $0.id == taskId }) {
            taskRecords[index].status = status
            taskRecords[index].completedAt = nil
            taskRecords[index].closedAt = nil
        }
        lock.unlock()
    }

    public func taskEventTypesForTesting(taskId: String) -> [(eventType: String, actorType: String)] {
        lock.lock()
        defer { lock.unlock() }
        return taskEvents.filter { $0.taskId == taskId }.map { ($0.eventType, $0.actorType) }
    }

    func closeOrphanTasksLocked(channelId: String, now: Date) {
        for index in taskRecords.indices where taskRecords[index].channelId == channelId {
            let status = taskRecords[index].status
            guard status != "done", status != "closed", status != "cancelled" else { continue }
            taskRecords[index].status = "closed"
            taskRecords[index].completedAt = now
            taskRecords[index].closedAt = now
            taskRecords[index].revision += 1
            taskEvents.append((taskId: taskRecords[index].id, eventType: "closed", actorType: "system"))
        }
    }

    public func addReminder(serverId: String, ownerAgentId: String, title: String, fireAt: Date) {
        lock.lock()
        reminderRecords.append(ReminderRecord(
            id: UUID().uuidString.lowercased(),
            serverId: serverId,
            ownerAgentId: ownerAgentId,
            title: title,
            fireAt: fireAt
        ))
        lock.unlock()
    }

    public func listReminders(authorization: String?, serverId: String, ownerAgentId: String?) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId) else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        let agents = oauth.serverAgents(serverId: serverId)
        if let ownerAgentId, !ownerAgentId.isEmpty {
            guard let agent = agents.first(where: { $0.id == ownerAgentId }) else {
                return Self.json(404, "{\"error\":\"Agent not found\"}")
            }
            guard role == "owner" || role == "admin" || agent.creatorUserId == userId else {
                return Self.json(403, "{\"error\":\"Forbidden\"}")
            }
            return Self.reminderListJSON(remindersFor([ownerAgentId]))
        }
        let visibleAgentIds: Set<String>
        if role == "owner" || role == "admin" {
            visibleAgentIds = Set(agents.map { $0.id })
        } else {
            visibleAgentIds = Set(agents.filter { $0.creatorUserId == userId }.map { $0.id })
        }
        return Self.reminderListJSON(remindersFor(visibleAgentIds))
    }

    func remindersFor(_ agentIds: Set<String>) -> [ReminderRecord] {
        lock.lock()
        defer { lock.unlock() }
        return reminderRecords.filter { agentIds.contains($0.ownerAgentId) }
    }




    public enum ReminderMutationOutcome: Sendable {
        case ok(version: Int)
        case notFound
        case conflict(currentVersion: Int)
        case invalid(String)
    }

    @discardableResult
    func appendReminderEventLocked(
        _ reminder: ReminderRecord, type: String, actorType: String, actorId: String? = nil,
        fireAt: Date? = nil
    ) -> ReminderRecord {
        var updated = reminder
        updated.updatedAt = Date()
        reminderEvents.append(ReminderEvent(
            reminderId: reminder.id, serverId: reminder.serverId, ownerAgentId: reminder.ownerAgentId,
            type: type, version: updated.version, actorType: actorType, actorId: actorId,
            createdAt: updated.updatedAt, fireAt: fireAt
        ))
        return updated
    }

    @discardableResult
    public func createAppReminder(
        serverId: String, ownerAgentId: String, title: String, fireAt: Date,
        notes: String? = nil, recurrenceJSON: String? = nil,
        channelId: String? = nil, threadId: String? = nil,
        actorType: String = "agent", actorId: String? = nil
    ) -> String {
        lock.lock()
        let reminder = ReminderRecord(
            id: UUID().uuidString.lowercased(), serverId: serverId, ownerAgentId: ownerAgentId,
            title: title, fireAt: fireAt, status: "scheduled", version: 1, notes: notes,
            recurrenceJSON: recurrenceJSON, channelId: channelId, threadId: threadId,
            createdAt: Date(), updatedAt: Date()
        )
        reminderRecords.append(appendReminderEventLocked(reminder, type: "scheduled", actorType: actorType, actorId: actorId))
        lock.unlock()
        return reminder.id
    }

    public func appReminderRow(id: String) -> (status: String, version: Int, title: String, fireAt: Date)? {
        lock.lock()
        defer { lock.unlock() }
        guard let reminder = reminderRecords.first(where: { $0.id == id }) else { return nil }
        return (reminder.status, reminder.version, reminder.title, reminder.fireAt)
    }

    public func appReminderEventsForTesting(reminderId: String) -> [(type: String, version: Int)] {
        lock.lock()
        defer { lock.unlock() }
        return reminderEvents.filter { $0.reminderId == reminderId }.map { ($0.type, $0.version) }
    }

    public func cancelAppReminder(reminderId: String, ownerAgentId: String, expectedVersion: Int) -> ReminderMutationOutcome {
        mutateAppReminder(reminderId: reminderId, ownerAgentId: ownerAgentId, expectedVersion: expectedVersion, type: "canceled") { reminder in
            reminder.status = "canceled"
        }
    }

    public func snoozeAppReminder(
        reminderId: String, ownerAgentId: String, expectedVersion: Int, fireAt: Date
    ) -> ReminderMutationOutcome {
        mutateAppReminder(reminderId: reminderId, ownerAgentId: ownerAgentId, expectedVersion: expectedVersion, type: "snoozed") { reminder in
            reminder.status = "scheduled"
            reminder.fireAt = fireAt
        }
    }

    public func updateAppReminder(
        reminderId: String, ownerAgentId: String, expectedVersion: Int,
        title: String?, fireAt: Date?, notes: String?
    ) -> ReminderMutationOutcome {
        guard title != nil || fireAt != nil || notes != nil else {
            return .invalid("no update fields")
        }
        return mutateAppReminder(reminderId: reminderId, ownerAgentId: ownerAgentId, expectedVersion: expectedVersion, type: "updated") { reminder in
            if let title { reminder.title = title }
            if let fireAt { reminder.fireAt = fireAt }
            if let notes { reminder.notes = notes }
        }
    }

    func mutateAppReminder(
        reminderId: String, ownerAgentId: String, expectedVersion: Int, type: String,
        mutate: (inout ReminderRecord) -> Void
    ) -> ReminderMutationOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard let index = reminderRecords.firstIndex(where: { $0.id == reminderId && $0.ownerAgentId == ownerAgentId }) else {
            return .notFound
        }
        if type == "updated", reminderRecords[index].status == "fired" {
            return .invalid("cannot update a fired reminder; snooze it back to scheduled first")
        }
        if type == "snoozed", reminderRecords[index].status == "canceled" {
            return .invalid("cannot snooze a canceled reminder")
        }
        guard reminderRecords[index].version == expectedVersion else {
            return .conflict(currentVersion: reminderRecords[index].version)
        }
        var reminder = reminderRecords[index]
        mutate(&reminder)
        reminder.version += 1
        let updated = appendReminderEventLocked(reminder, type: type, actorType: "agent", actorId: ownerAgentId)
        reminderRecords[index] = updated
        return .ok(version: updated.version)
    }

    public func listAppReminders(
        serverId: String, ownerAgentId: String, status: String?
    ) -> (rows: [(id: String, status: String, version: Int, title: String, fireAt: Date)], invalidStatus: Bool) {
        let allowed = Set(["scheduled", "canceled", "fired", "all"])
        var wanted: Set<String>?
        if let status, !status.isEmpty {
            let parts = status.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard !parts.isEmpty, parts.allSatisfy({ allowed.contains($0) }) else {
                return ([], true)
            }
            if !parts.contains("all") { wanted = Set(parts) }
        }
        lock.lock()
        defer { lock.unlock() }
        let rows = reminderRecords.filter { reminder in
            reminder.serverId == serverId && reminder.ownerAgentId == ownerAgentId
                && (wanted == nil || wanted!.contains(reminder.status))
        }.map { ($0.id, $0.status, $0.version, $0.title, $0.fireAt) }
        return (rows, false)
    }

    public func fireAppReminderForTesting(reminderId: String) -> ReminderMutationOutcome {
        mutateAppReminder(reminderId: reminderId, ownerAgentId: ownerAgentIdForReminder(reminderId) ?? "",
                          expectedVersion: appReminderRow(id: reminderId)?.version ?? 0, type: "fired") { reminder in
            reminder.status = "fired"
        }
    }

    public func agentIdForReminderTesting(reminderId: String) -> String? {
        ownerAgentIdForReminder(reminderId)
    }

    public func ownerAgentIdForReminder(_ reminderId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return reminderRecords.first(where: { $0.id == reminderId })?.ownerAgentId
    }

    public func appReminderEventLog(reminderId: String) -> [(eventType: String, version: Int)] {
        lock.lock()
        defer { lock.unlock() }
        return reminderEvents.filter { $0.reminderId == reminderId }
            .sorted { $0.createdAt > $1.createdAt }
            .map { ($0.type, $0.version) }
    }

    public func serverMemberRoles(serverId: String) -> [(userId: String, role: String)] {
        oauth.memberRoles(serverId: serverId)
    }

    static let remindersMovedReply = json(409, "{\"error\":\"Reminders are managed by the Reminder App now\",\"code\":\"reminders_moved_to_app\"}")

    func legacyReminderWritesMoved(serverId: String) -> Bool {
        featureFlagEnabledForServer("reminder_app", serverId: serverId)
    }

    func legacyReminderMachine(_ authorization: String?) -> (machineId: String, serverId: String)? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        let key = String(authorization.dropFirst("Bearer ".count))
        guard let machine = machineCredential(apiKey: key) else { return nil }
        return (machine.machineId, machine.serverId)
    }

    func reminderAgentOnServer(_ agentId: String, serverId: String) -> OAuthLedger.AgentRuntimeInfo? {
        guard let agent = oauth.agentRuntimeInfo(id: agentId), agent.serverId == serverId, !agent.deleted else {
            return nil
        }
        return agent
    }


    public func legacyReminderList(authorization: String?, agentId: String, status: String?) -> HTTPReply {
        guard let machine = legacyReminderMachine(authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard reminderAgentOnServer(agentId, serverId: machine.serverId) != nil else {
            return Self.json(404, "{\"error\":\"Agent not found\"}")
        }
        let listed = listAppReminders(serverId: machine.serverId, ownerAgentId: agentId, status: status)
        if listed.invalidStatus {
            return Self.json(400, "{\"error\":\"Invalid status filter\"}")
        }
        let rows = listed.rows.map {
            Self.reminderSummaryJSON(($0.id, $0.status, $0.version, $0.title), ownerAgentId: agentId, fireAt: $0.fireAt)
        }.joined(separator: ",")
        return Self.json(200, "{\"reminders\":[\(rows)]}")
    }

    public func legacyReminderCreate(authorization: String?, agentId: String, body: String) -> HTTPReply {
        guard let machine = legacyReminderMachine(authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard let agent = reminderAgentOnServer(agentId, serverId: machine.serverId) else {
            return Self.json(404, "{\"error\":\"Agent not found\"}")
        }
        if legacyReminderWritesMoved(serverId: machine.serverId) { return Self.remindersMovedReply }
        guard agent.runtime != "external" else {
            return Self.json(409, "{\"error\":\"External agents cannot create reminders\",\"code\":\"reminders_unsupported_for_external_agents\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let title = (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
        else {
            return Self.json(400, "{\"error\":\"title is required\"}")
        }
        guard let messageId = object["msgId"] as? String, !messageId.isEmpty else {
            return Self.json(400, "{\"error\":\"msgId is required for agent-created reminders\"}")
        }
        let fireAt: Date
        if let raw = object["fireAt"] as? String, let parsed = ISO8601DateFormatter().date(from: raw) {
            fireAt = parsed
        } else if let delay = object["delaySeconds"] as? Int, delay >= 0 {
            fireAt = Date().addingTimeInterval(Double(delay))
        } else {
            return Self.json(400, "{\"error\":\"fireAt or delaySeconds is required\"}")
        }
        let id = createAppReminder(
            serverId: machine.serverId, ownerAgentId: agentId, title: title, fireAt: fireAt,
            notes: object["notes"] as? String, recurrenceJSON: object["recurrence"] as? String,
            channelId: object["channelId"] as? String, threadId: object["threadId"] as? String,
            actorType: "agent", actorId: agentId
        )
        let row = (id: id, status: "scheduled", version: 1, title: title)
        return Self.json(200, "{\"reminder\":\(Self.reminderSummaryJSON(row))}")
    }

    public func legacyReminderCancel(authorization: String?, agentId: String, reminderId: String, body: String) -> HTTPReply {
        guard legacyReminderMachine(authorization) != nil else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        let expected = (try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])?["expectedVersion"] as? Int ?? 0
        switch cancelAppReminder(reminderId: reminderId, ownerAgentId: agentId, expectedVersion: expected) {
        case .notFound:
            return Self.json(404, "{\"error\":\"Reminder not found\"}")
        case .conflict(let current):
            return Self.json(409, "{\"error\":\"Reminder version conflict\",\"currentVersion\":\(current)}")
        case .invalid:
            return Self.json(400, "{\"error\":\"Invalid reminder update\"}")
        case .ok(let version):
            let row = (id: reminderId, status: "canceled", version: version, title: appReminderRow(id: reminderId)?.title ?? "")
            return Self.json(200, "{\"reminder\":\(Self.reminderSummaryJSON(row))}")
        }
    }

    func reminderMutationReply(_ outcome: ReminderMutationOutcome, reminderId: String, ownerAgentId: String) -> HTTPReply {
        switch outcome {
        case .notFound:
            return Self.json(404, "{\"error\":\"Reminder not found\"}")
        case .conflict(let current):
            return Self.json(409, "{\"error\":\"Reminder version conflict\",\"currentVersion\":\(current)}")
        case .invalid(let message):
            return Self.json(409, "{\"error\":\(jsonString(message))}")
        case .ok:
            let row = appReminderRow(id: reminderId)
            let summary = Self.reminderSummaryJSON(
                (reminderId, row?.status ?? "scheduled", row?.version ?? 0, row?.title ?? ""),
                ownerAgentId: ownerAgentId, fireAt: row?.fireAt
            )
            return Self.json(200, "{\"reminder\":\(summary)}")
        }
    }

    public func legacyReminderSnooze(authorization: String?, agentId: String, reminderId: String, body: String) -> HTTPReply {
        guard let machine = legacyReminderMachine(authorization) else { return Self.json(401, "{\"error\":\"Unauthorized\"}") }
        if legacyReminderWritesMoved(serverId: machine.serverId) { return Self.remindersMovedReply }
        guard let row = appReminderRow(id: reminderId), row.status != "canceled" else {
            return Self.json(404, "{\"error\":\"Reminder not found\"}")
        }
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
        let fireAt: Date
        if let raw = object["fireAt"] as? String, let parsed = ISO8601DateFormatter().date(from: raw) {
            fireAt = parsed
        } else if let delay = object["delaySeconds"] as? Int, delay >= 0 {
            fireAt = Date().addingTimeInterval(Double(delay))
        } else {
            return Self.json(400, "{\"error\":\"fireAt or delaySeconds is required\"}")
        }
        let outcome = snoozeAppReminder(reminderId: reminderId, ownerAgentId: agentId, expectedVersion: row.version, fireAt: fireAt)
        return reminderMutationReply(outcome, reminderId: reminderId, ownerAgentId: agentId)
    }

    public func legacyReminderUpdate(authorization: String?, agentId: String, reminderId: String, body: String) -> HTTPReply {
        guard let machine = legacyReminderMachine(authorization) else { return Self.json(401, "{\"error\":\"Unauthorized\"}") }
        if legacyReminderWritesMoved(serverId: machine.serverId) { return Self.remindersMovedReply }
        guard let row = appReminderRow(id: reminderId) else { return Self.json(404, "{\"error\":\"Reminder not found\"}") }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return Self.json(400, "{\"error\":\"Invalid reminder update\"}")
        }
        let fireAt = (object["fireAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        let outcome = updateAppReminder(
            reminderId: reminderId, ownerAgentId: agentId, expectedVersion: row.version,
            title: object["title"] as? String, fireAt: fireAt, notes: object["notes"] as? String
        )
        return reminderMutationReply(outcome, reminderId: reminderId, ownerAgentId: agentId)
    }


    public func legacyReminderLog(authorization: String?, agentId: String, reminderId: String) -> HTTPReply {
        guard legacyReminderMachine(authorization) != nil else { return Self.json(401, "{\"error\":\"Unauthorized\"}") }
        guard ownerAgentIdForReminder(reminderId) == agentId else { return Self.json(404, "{\"error\":\"Reminder not found\"}") }
        return Self.json(200, Self.reminderLogJSON(appReminderEventLog(reminderId: reminderId)))
    }

    public func agentApiReminderCancel(authorization: String?, reminderId: String) -> HTTPReply {
        if let denial = agentCapabilityDenial(authorization, required: "tasks") { return denial }
        guard let credential = agentCredentialAgent(authorization),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else { return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}") }
        guard let row = appReminderRow(id: reminderId) else { return Self.json(404, "{\"error\":\"Reminder not found\"}") }
        return reminderMutationReply(
            cancelAppReminder(reminderId: reminderId, ownerAgentId: agent.id, expectedVersion: row.version),
            reminderId: reminderId, ownerAgentId: agent.id
        )
    }

    public func agentApiReminderSnooze(authorization: String?, reminderId: String, body: String) -> HTTPReply {
        guard let credential = agentCredentialAgent(authorization),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else { return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}") }
        guard let row = appReminderRow(id: reminderId) else { return Self.json(404, "{\"error\":\"Reminder not found\"}") }
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
        let fireAt: Date
        if let raw = object["fireAt"] as? String, let parsed = ISO8601DateFormatter().date(from: raw) {
            fireAt = parsed
        } else if let delay = object["delaySeconds"] as? Int, delay >= 0 {
            fireAt = Date().addingTimeInterval(Double(delay))
        } else {
            return Self.json(400, "{\"error\":\"fireAt or delaySeconds is required\"}")
        }
        return reminderMutationReply(
            snoozeAppReminder(reminderId: reminderId, ownerAgentId: agent.id, expectedVersion: row.version, fireAt: fireAt),
            reminderId: reminderId, ownerAgentId: agent.id
        )
    }

    public func agentApiReminderUpdate(authorization: String?, reminderId: String, body: String) -> HTTPReply {
        guard let credential = agentCredentialAgent(authorization),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else { return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}") }
        guard let row = appReminderRow(id: reminderId) else { return Self.json(404, "{\"error\":\"Reminder not found\"}") }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return Self.json(400, "{\"error\":\"Invalid reminder update\"}")
        }
        let fireAt = (object["fireAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return reminderMutationReply(
            updateAppReminder(
                reminderId: reminderId, ownerAgentId: agent.id, expectedVersion: row.version,
                title: object["title"] as? String, fireAt: fireAt, notes: object["notes"] as? String
            ),
            reminderId: reminderId, ownerAgentId: agent.id
        )
    }

    public func agentApiReminderLog(authorization: String?, reminderId: String) -> HTTPReply {
        guard let credential = agentCredentialAgent(authorization),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else { return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}") }
        guard ownerAgentIdForReminder(reminderId) == agent.id else { return Self.json(404, "{\"error\":\"Reminder not found\"}") }
        return Self.json(200, Self.reminderLogJSON(appReminderEventLog(reminderId: reminderId)))
    }

    public func agentApiReminderList(authorization: String?, status: String?) -> HTTPReply {
        guard let credential = agentCredentialAgent(authorization),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        let listed = listAppReminders(serverId: agent.serverId, ownerAgentId: agent.id, status: status)
        if listed.invalidStatus {
            return Self.json(400, "{\"error\":\"Invalid status filter\"}")
        }
        let rows = listed.rows.map {
            Self.reminderSummaryJSON(($0.id, $0.status, $0.version, $0.title), ownerAgentId: agent.id, fireAt: $0.fireAt)
        }.joined(separator: ",")
        return Self.json(200, "{\"reminders\":[\(rows)]}")
    }

    public func agentApiReminderCreate(authorization: String?, body: String) -> HTTPReply {
        if let denial = agentCapabilityDenial(authorization, required: "tasks") { return denial }
        guard let credential = agentCredentialAgent(authorization),
              let agent = oauth.agentRuntimeInfo(id: credential.agentId), !agent.deleted
        else {
            return Self.json(401, "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        }
        guard agent.runtime != "external" else {
            return Self.json(409, "{\"error\":\"External agents cannot create reminders\",\"code\":\"reminders_unsupported_for_external_agents\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let title = (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
        else {
            return Self.json(400, "{\"error\":\"title is required\"}")
        }
        guard let messageId = object["msgId"] as? String, !messageId.isEmpty else {
            return Self.json(400, "{\"error\":\"msgId is required for agent-created reminders\"}")
        }
        _ = messageId
        let fireAt: Date
        if let raw = object["fireAt"] as? String, let parsed = ISO8601DateFormatter().date(from: raw) {
            fireAt = parsed
        } else if let delay = object["delaySeconds"] as? Int, delay >= 0 {
            fireAt = Date().addingTimeInterval(Double(delay))
        } else {
            return Self.json(400, "{\"error\":\"fireAt or delaySeconds is required\"}")
        }
        let id = createAppReminder(
            serverId: agent.serverId, ownerAgentId: agent.id, title: title, fireAt: fireAt,
            notes: object["notes"] as? String, recurrenceJSON: object["recurrence"] as? String,
            channelId: object["channelId"] as? String, threadId: object["threadId"] as? String,
            actorType: "agent", actorId: agent.id
        )
        let row = (id: id, status: "scheduled", version: 1, title: title)
        return Self.json(200, "{\"reminder\":\(Self.reminderSummaryJSON(row))}")
    }

    public func saveChannelMessage(authorization: String?, serverId: String, body: String) -> HTTPReply {
        guard let userId = sessionUserId(authorization: authorization) else {
            return Self.json(401, "{\"error\":\"Unauthorized\"}")
        }
        guard oauth.memberRole(serverId: serverId, userId: userId) != nil else {
            return Self.json(403, "{\"error\":\"Not a member of this server\"}")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let messageId = object["messageId"] as? String,
              oauth.saveMessage(userId: userId, messageId: messageId)
        else {
            return Self.json(404, "{\"error\":\"Message not found\"}")
        }
        return Self.json(200, "{\"ok\":true}")
    }
}

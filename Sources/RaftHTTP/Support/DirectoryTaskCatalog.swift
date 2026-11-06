import Foundation

public struct DirectoryTaskCatalog: Sendable {
    let directory: EmailLoginDirectory

    public init(directory: EmailLoginDirectory) { self.directory = directory }

    func taskChannelAccess(serverId: String, channelId: String, userId: String) -> TaskChannelAccess {
        TasksAndLabsService.channelAccess(oauth: directory.oauth, serverId: serverId, channelId: channelId, userId: userId)
    }

    public func channelTaskAccess(serverId: String, channelId: String, userId: String) -> ChannelTaskAccess {
        switch taskChannelAccess(serverId: serverId, channelId: channelId, userId: userId) {
        case .missing:
            .missing
        case .readOnly:
            .readOnly
        case .write:
            .write
        }
    }

    public func addTasks(
        channelId: String, titles: [String], descriptions: [String?]? = nil,
        creatorId: String? = nil, creatorType: String = "user"
    ) -> [String] {
        // The directory lock keeps this append ordered with the readers that
        // still snapshot taskRecords; the store method itself is one locked
        // read-modify-write for the row array. `creatorType` is accepted for
        // callers but the row has no column for it, as before.
        directory.lock.lock()
        defer { directory.lock.unlock() }
        return directory.tasksAndRemindersStore.appendTasks(
            channelId: channelId,
            titles: titles,
            descriptions: descriptions,
            creatorId: creatorId
        )
    }

    func orderedTasks(
        serverId: String,
        userId: String,
        status: String?
    ) -> [(task: TaskRecord, channelName: String, channelType: String)] {
        let visible = directory.oauth.channelsForServer(serverId: serverId, userId: userId).filter {
            $0.joined && ($0.type == "channel" || $0.type == "joint")
                && directory.oauth.channelArchivedAt(id: $0.id) == nil
        }
        let names = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0.name) })
        let types = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0.type) })
        directory.lock.lock()
        let rows = directory.taskRecords.filter {
            names[$0.channelId] != nil && (status == nil || $0.status == status)
        }
        directory.lock.unlock()
        return rows
            .map { (task: $0, channelName: names[$0.channelId] ?? "", channelType: types[$0.channelId] ?? "channel") }
            .sorted {
                if $0.channelName != $1.channelName { return $0.channelName < $1.channelName }
                if $0.task.taskNumber != $1.task.taskNumber { return $0.task.taskNumber < $1.task.taskNumber }
                return $0.task.id < $1.task.id
            }
    }

    func fullTaskJSON(_ task: TaskRecord, channelName: String, channelType: String) -> String {
        OrderedJSON.object([
            OrderedJSONField("id", task.id), OrderedJSONField("channelId", task.channelId),
            OrderedJSONField("channelName", channelName), OrderedJSONField("channelType", channelType),
            OrderedJSONField("title", task.title), OrderedJSONField("description", optional: task.description),
            OrderedJSONField("status", task.status), OrderedJSONField("taskNumber", task.taskNumber),
            OrderedJSONField("messageId", task.messageId), OrderedJSONField("revision", task.revision),
        ]).render()
    }

    func summaryTaskJSON(_ task: TaskRecord, channelName: String, channelType: String) -> String {
        let descriptionBytes = task.description.map { Data($0.utf8).count } ?? 0
        let hasDescription = task.description != nil && !(task.description ?? "").isEmpty
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let claimed = task.claimedAt.map(formatter.string(from:))
        let completed = task.completedAt.map(formatter.string(from:))
        let updated = task.updatedAt.map(formatter.string(from:))
        let createdAt = formatter.string(from: task.createdAt)
        let assignee = task.assigneeId
        let assigneeType = task.assigneeType
        var claimedByName: String?
        if let assigneeId = task.assigneeId {
            directory.lock.lock()
            if task.assigneeType == "agent", let agent = directory.oauth.agentRuntimeInfo(id: assigneeId) {
                claimedByName = agent.name
            } else if let name = directory.accounts.values.first(where: { $0.id == assigneeId })?.name {
                claimedByName = name
            }
            directory.lock.unlock()
        }
        var createdById: String?
        var createdByName: String?
        var createdByType: String?
        if let creatorId = task.creatorId {
            directory.lock.lock()
            if let agent = directory.oauth.agentRuntimeInfo(id: creatorId) {
                createdById = creatorId
                createdByName = agent.name
                createdByType = "agent"
            } else if let name = directory.accounts.values.first(where: { $0.id == creatorId })?.name {
                createdById = creatorId
                createdByName = name
                createdByType = "user"
            }
            directory.lock.unlock()
        }
        return OrderedJSON.object([
            OrderedJSONField("channelId", task.channelId),
            OrderedJSONField("channelName", channelName),
            OrderedJSONField("channelType", channelType),
            OrderedJSONField("claimedAt", optional: claimed),
            OrderedJSONField("claimedById", optional: assignee),
            OrderedJSONField("claimedByName", optional: claimedByName),
            OrderedJSONField("claimedByType", optional: assigneeType),
            OrderedJSONField("completedAt", optional: completed),
            OrderedJSONField("createdAt", createdAt),
            OrderedJSONField("createdById", optional: createdById),
            OrderedJSONField("createdByName", optional: createdByName),
            OrderedJSONField("createdByType", optional: createdByType),
            OrderedJSONField("descriptionBytes", descriptionBytes),
            OrderedJSONField("hasDescription", hasDescription),
            OrderedJSONField("id", task.id),
            OrderedJSONField("isLegacy", false),
            OrderedJSONField("messageId", task.messageId),
            OrderedJSONField("readOnlyReason", .null),
            OrderedJSONField("revision", task.revision),
            OrderedJSONField("source", "tasks"),
            OrderedJSONField("status", task.status),
            OrderedJSONField("taskNumber", task.taskNumber),
            OrderedJSONField("title", task.title),
            OrderedJSONField("updatedAt", optional: updated),
        ]).render()
    }
}

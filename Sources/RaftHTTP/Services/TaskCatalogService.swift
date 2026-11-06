import Foundation

public struct TaskCatalogService: Sendable {
    private let tasks: TasksAndRemindersStore
    private let profiles: AuthProfileStore
    private let oauth: OAuthLedger

    init(tasks: TasksAndRemindersStore, profiles: AuthProfileStore, oauth: OAuthLedger) {
        self.tasks = tasks
        self.profiles = profiles
        self.oauth = oauth
    }

    func taskChannelAccess(serverId: String, channelId: String, userId: String) -> TaskChannelAccess {
        TasksAndLabsService.channelAccess(oauth: oauth, serverId: serverId, channelId: channelId, userId: userId)
    }

    func canReadChannel(serverId: String, channelId: String, userId: String) -> Bool {
        switch taskChannelAccess(serverId: serverId, channelId: channelId, userId: userId) {
        case .missing: false
        case .readOnly, .write: true
        }
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
        // Number allocation and the batch append are one Tasks transaction.
        // `creatorType` remains accepted without a corresponding row column.
        return tasks.appendTasks(
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
        let visible = oauth.channelsForServer(serverId: serverId, userId: userId).filter {
            $0.joined && ($0.type == "channel" || $0.type == "joint")
                && oauth.channelArchivedAt(id: $0.id) == nil
        }
        let names = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0.name) })
        let types = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0.type) })
        let rows = tasks.taskRecords.filter {
            names[$0.channelId] != nil && (status == nil || $0.status == status)
        }
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
            if task.assigneeType == "agent", let agent = oauth.agentRuntimeInfo(id: assigneeId) {
                claimedByName = agent.name
            } else if let name = profiles.account(userId: assigneeId)?.name {
                claimedByName = name
            }
        }
        var createdById: String?
        var createdByName: String?
        var createdByType: String?
        if let creatorId = task.creatorId {
            if let agent = oauth.agentRuntimeInfo(id: creatorId) {
                createdById = creatorId
                createdByName = agent.name
                createdByType = "agent"
            } else if let name = profiles.account(userId: creatorId)?.name {
                createdById = creatorId
                createdByName = name
                createdByType = "user"
            }
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

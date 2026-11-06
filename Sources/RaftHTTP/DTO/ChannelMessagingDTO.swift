import Foundation

/// `POST /api/tasks/channel/:channelId` request body.
///
/// The upstream handler reads this body with the raw object cast: `tasks` must
/// be a present, non-empty array of objects, while an individual `title` or
/// `description` that is not a string is skipped instead of failing the batch.
/// This decoder keeps that exact tolerance so the migrated service cannot turn
/// a previously accepted body into a 400. A `tasks` value that is absent, not
/// an array, or holds a non-object element still fails to decode, which is the
/// same shape the raw array-of-dictionaries cast rejected.
public struct CreateChannelTasksRequest: Codable, Sendable, Equatable {
    public var tasks: [TaskDraft]

    public init(tasks: [TaskDraft]) {
        self.tasks = tasks
    }

    private enum CodingKeys: String, CodingKey {
        case tasks
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tasks = try container.decode([LenientTaskDraft].self, forKey: .tasks).map(\.task)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tasks, forKey: .tasks)
    }
}

/// One decoded row of `CreateChannelTasksRequest`.
public struct TaskDraft: Codable, Sendable, Equatable {
    public var title: String?
    public var description: String?

    public init(title: String? = nil, description: String? = nil) {
        self.title = title
        self.description = description
    }
}

/// Per-field tolerance for one task row: a value of the wrong JSON type becomes
/// `nil`, exactly like `as? String` in the raw parser.
private struct LenientTaskDraft: Decodable {
    let task: TaskDraft

    private enum CodingKeys: String, CodingKey {
        case title
        case description
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let title = (try? container.decodeIfPresent(String.self, forKey: .title)) ?? nil
        let description = (try? container.decodeIfPresent(String.self, forKey: .description)) ?? nil
        task = TaskDraft(title: title, description: description)
    }
}

/// `POST /api/tasks/channel/:channelId` success body. The order is the upstream
/// single key, so the canonical encoder reproduces `{"taskIds":[…]}`.
public struct TaskIDsResponse: Codable, Sendable, Equatable {
    public let taskIds: [String]

    public init(taskIds: [String]) {
        self.taskIds = taskIds
    }
}

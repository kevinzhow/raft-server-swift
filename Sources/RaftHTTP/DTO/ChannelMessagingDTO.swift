import Foundation

/// `POST /api/tasks/channel/:channelId` request body. The decoder preserves
/// missing or mistyped fields for the service's Node validation order: require a
/// nonempty batch, cap it at 50, then reject each missing/blank title.
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
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            task = TaskDraft()
            return
        }
        let title = (try? container.decodeIfPresent(String.self, forKey: .title)) ?? nil
        let description = (try? container.decodeIfPresent(String.self, forKey: .description)) ?? nil
        task = TaskDraft(title: title, description: description)
    }
}

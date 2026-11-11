import Foundation

/// One retained task lifecycle event.
///
/// The canonical fields are one group because upstream `task_events` is a
/// single insert: `id`, global `seq`, `actorId`, the event-specific `payload`
/// and `createdAt` all exist together or not at all. An older snapshot that
/// predates the group is restored as a pre-canonical row (`history == nil`);
/// such a row never appears in the published history because upstream has no
/// representable partial event. A present group is strict: a missing member
/// rejects the whole snapshot.
struct TaskEventRecord: Sendable, Equatable {
    struct History: Sendable, Equatable {
        var id: String
        var seq: Int
        /// `nil` for the upstream `system` actor.
        var actorId: String?
        /// The event-specific JSON object, already rendered in published order.
        var payloadJSON: String
        var createdAt: Date
    }

    var taskId: String
    var eventType: String
    var actorType: String
    var history: History?
}

extension TasksAndRemindersStore {
    /// Append one canonical event. The caller already holds the task owner's
    /// Mutex and passes its state; this helper never locks. `seq` is the single
    /// owner-wide monotonic sequence upstream assigns with a global bigserial.
    static func appendTaskEventLocked(
        state: inout State,
        taskId: String,
        eventType: String,
        actorType: String,
        actorId: String?,
        payloadJSON: String,
        now: Date
    ) {
        let nextSeq = (state.taskEvents.compactMap { $0.history?.seq }.max() ?? 0) + 1
        state.taskEvents.append(TaskEventRecord(
            taskId: taskId,
            eventType: eventType,
            actorType: actorType,
            history: TaskEventRecord.History(
                id: UUID().uuidString.lowercased(),
                seq: nextSeq,
                actorId: actorId,
                payloadJSON: payloadJSON,
                createdAt: now
            )
        ))
    }

    /// Upstream `writeCanonicalStatus`: a closed transition is `closed`, a
    /// transition out of `closed` is `reopened`, every other write is
    /// `status_changed`.
    static func statusEventType(from previous: String, to next: String) -> String {
        if next == "closed" { return "closed" }
        if previous == "closed" { return "reopened" }
        return "status_changed"
    }

    static func statusEventPayload(from previous: String, to next: String, forced: Bool) -> String {
        OrderedJSON.object([
            .init("from", previous),
            .init("to", next),
            .init("forced", forced),
        ]).render()
    }

    /// The published history of one task in `seq` order. Pre-canonical rows are
    /// omitted: they carry no id, timestamp or payload and upstream would never
    /// have written such a row.
    func publishedTaskEvents(taskId: String) -> [TaskEventRecord] {
        mutex.withLock { storage in
            storage.taskEvents
                .filter { $0.taskId == taskId && $0.history != nil }
                .sorted { ($0.history?.seq ?? 0) < ($1.history?.seq ?? 0) }
        }
    }
}

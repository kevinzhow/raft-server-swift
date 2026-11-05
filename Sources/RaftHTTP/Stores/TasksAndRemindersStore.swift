import Foundation

/// Owns the task, reminder and assignee-change rows that used to be stored inline on
/// `EmailLoginDirectory`.
///
/// HTTP decisions stay in the directory extensions; this store serializes only
/// its own rows behind a private lock and hands back strong Swift values.
/// `EmailLoginDirectory` keeps computed accessors that forward here so the
/// existing extension files and tests keep their property names while the
/// directory body stays a composition root.
final class TasksAndRemindersStore: @unchecked Sendable {
    /// Every row this store owns. Grouping them lets one locked value be the
    /// whole store snapshot; each accessor below copies it, which is cheap
    /// because the collections are copy-on-write.
    struct State {
        var reminderRecords: [ReminderRecord] = []
        var reminderEvents: [ReminderEvent] = []
        var taskRecords: [TaskRecord] = []
        var taskWriteHolds: [String: (seen: Int, latest: Int)] = [:]
        var taskEvents: [(taskId: String, eventType: String, actorType: String)] = []
        var lastTaskServerWarning: String? = nil
        var lastTaskServerQuery: String? = nil
        var assigneeChangeEvents: [(taskId: String, assigneeId: String?, assigneeType: String?, previousAssigneeId: String?, previousAssigneeType: String?, actorType: String, actorId: String)] = []
    }

    private let lock = NSLock()
    private var storage = State()

    /// The whole owned state. A read or a write is one locked critical section.
    var state: State {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }

    var reminderRecords: [ReminderRecord] {
        get { state.reminderRecords }
        set { state.reminderRecords = newValue }
    }

    var reminderEvents: [ReminderEvent] {
        get { state.reminderEvents }
        set { state.reminderEvents = newValue }
    }

    var taskRecords: [TaskRecord] {
        get { state.taskRecords }
        set { state.taskRecords = newValue }
    }

    var taskWriteHolds: [String: (seen: Int, latest: Int)] {
        get { state.taskWriteHolds }
        set { state.taskWriteHolds = newValue }
    }

    var taskEvents: [(taskId: String, eventType: String, actorType: String)] {
        get { state.taskEvents }
        set { state.taskEvents = newValue }
    }

    var lastTaskServerWarning: String? {
        get { state.lastTaskServerWarning }
        set { state.lastTaskServerWarning = newValue }
    }

    var lastTaskServerQuery: String? {
        get { state.lastTaskServerQuery }
        set { state.lastTaskServerQuery = newValue }
    }

    var assigneeChangeEvents: [(taskId: String, assigneeId: String?, assigneeType: String?, previousAssigneeId: String?, previousAssigneeType: String?, actorType: String, actorId: String)] {
        get { state.assigneeChangeEvents }
        set { state.assigneeChangeEvents = newValue }
    }
}

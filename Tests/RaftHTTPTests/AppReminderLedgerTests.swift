import Foundation
import Testing
@testable import RaftHTTP
import TestSupport

@Test func appReminderLifecycleIsVersionBoundAndEventful() {
    let reminders = TasksAndRemindersStore()
    let reminder = reminders.createReminder(
        serverId: "s1", ownerAgentId: "a1", title: "Stand up",
        fireAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    #expect(reminders.reminderRow(id: reminder)?.status == "scheduled")
    #expect(reminders.reminderRow(id: reminder)?.version == 1)
    #expect(reminders.reminderEventLog(reminderId: reminder).map(\.eventType) == ["scheduled"])

    guard case .conflict(let current) = reminders.cancelReminder(
        reminderId: reminder, ownerAgentId: "a1", expectedVersion: 99
    ) else { Issue.record("stale cancel must conflict"); return }
    #expect(current == 1)
    #expect(reminders.reminderRow(id: reminder)?.status == "scheduled")

    guard case .ok(let version) = reminders.snoozeReminder(
        reminderId: reminder, ownerAgentId: "a1", expectedVersion: 1,
        fireAt: Date(timeIntervalSince1970: 1_700_000_600)
    ) else { Issue.record("snooze must succeed"); return }
    #expect(version == 2)
    guard case .ok(let updatedVersion) = reminders.updateReminder(
        reminderId: reminder, ownerAgentId: "a1", expectedVersion: 2,
        title: "Stand up and stretch", fireAt: nil, notes: "with notes"
    ) else { Issue.record("update must succeed"); return }
    #expect(updatedVersion == 3)
    guard case .ok(let canceledVersion) = reminders.cancelReminder(
        reminderId: reminder, ownerAgentId: "a1", expectedVersion: 3
    ) else { Issue.record("cancel must succeed"); return }
    #expect(canceledVersion == 4)
    #expect(reminders.reminderRow(id: reminder)?.status == "canceled")
    // The log is newest-first by creation time; the four events share a clock
    // tick at worst, so compare as a set of (type, version) pairs.
    let log = reminders.reminderEventLog(reminderId: reminder)
    #expect(Set(log.map(\.eventType)) == ["scheduled", "snoozed", "updated", "canceled"])
    #expect(log.map(\.version).sorted() == [1, 2, 3, 4])
}

@Test func appReminderOwnershipAndStatusFilterAreEnforced() {
    let reminders = TasksAndRemindersStore()
    let first = reminders.createReminder(serverId: "s1", ownerAgentId: "a1", title: "One", fireAt: Date())
    let second = reminders.createReminder(serverId: "s1", ownerAgentId: "a2", title: "Two", fireAt: Date())
    _ = reminders.cancelReminder(reminderId: second, ownerAgentId: "a2", expectedVersion: 1)

    guard case .notFound = reminders.cancelReminder(reminderId: first, ownerAgentId: "a2", expectedVersion: 1) else {
        Issue.record("another agent must not mutate the reminder"); return
    }
    #expect(reminders.reminders(serverId: "s1", ownerAgentId: "a1", statuses: ["scheduled"]).map(\.id) == [first])
    #expect(reminders.reminders(serverId: "s1", ownerAgentId: "a2", statuses: ["canceled"]).map(\.id) == [second])
    #expect(reminders.reminders(serverId: "s2", ownerAgentId: "a1", statuses: nil).isEmpty)
}

@Test func reminderWriteWithoutExpectedVersionBindsToTheCurrentRow() {
    let reminders = TasksAndRemindersStore()
    let id = reminders.createReminder(serverId: "s1", ownerAgentId: "a1", title: "One", fireAt: Date())
    guard case .ok(let first) = reminders.snoozeReminder(
        reminderId: id, ownerAgentId: "a1", expectedVersion: nil, fireAt: Date()
    ), case .ok(let second) = reminders.updateReminder(
        reminderId: id, ownerAgentId: "a1", expectedVersion: nil, title: "Two", fireAt: nil, notes: nil
    ) else { Issue.record("current-version writes must succeed"); return }
    #expect((first, second) == (2, 3))
    guard case .invalid(let message) = reminders.updateReminder(
        reminderId: id, ownerAgentId: "a1", expectedVersion: nil, title: nil, fireAt: nil, notes: nil
    ) else { Issue.record("an empty update must be invalid"); return }
    #expect(message == "no update fields")
}

@Test func reminderWritesFromManyThreadsEachTakeOneVersion() async {
    let reminders = TasksAndRemindersStore()
    let id = reminders.createReminder(serverId: "s1", ownerAgentId: "a1", title: "One", fireAt: Date())
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<50 {
            group.addTask {
                _ = reminders.snoozeReminder(
                    reminderId: id, ownerAgentId: "a1", expectedVersion: nil, fireAt: Date()
                )
            }
        }
    }
    #expect(reminders.reminderRow(id: id)?.version == 51)
    #expect(reminders.reminderEventLog(reminderId: id).count == 51)
}

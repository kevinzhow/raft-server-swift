import Foundation
import Testing
@testable import RaftHTTP
import TestSupport

@Test func appReminderLifecycleIsVersionBoundAndEventful() {
    let accounts = EmailLoginDirectory()
    let reminder = accounts.createAppReminderForTesting(
        serverId: "s1", ownerAgentId: "a1", title: "Stand up",
        fireAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    #expect(accounts.appReminderRowForTesting(id: reminder)?.status == "scheduled")
    #expect(accounts.appReminderRowForTesting(id: reminder)?.version == 1)
    #expect(accounts.appReminderEventsForTesting(reminderId: reminder).map(\.type) == ["scheduled"])

    guard case .conflict(let current) = accounts.cancelAppReminder(
        reminderId: reminder, ownerAgentId: "a1", expectedVersion: 99
    ) else { Issue.record("stale cancel must conflict"); return }
    #expect(current == 1)
    #expect(accounts.appReminderRowForTesting(id: reminder)?.status == "scheduled")

    guard case .ok(let version) = accounts.snoozeAppReminder(
        reminderId: reminder, ownerAgentId: "a1", expectedVersion: 1,
        fireAt: Date(timeIntervalSince1970: 1_700_000_600)
    ) else { Issue.record("snooze must succeed"); return }
    #expect(version == 2)
    guard case .ok(let updatedVersion) = accounts.updateAppReminder(
        reminderId: reminder, ownerAgentId: "a1", expectedVersion: 2,
        title: "Stand up and stretch", fireAt: nil, notes: "with notes"
    ) else { Issue.record("update must succeed"); return }
    #expect(updatedVersion == 3)
    guard case .ok(let canceledVersion) = accounts.cancelAppReminder(
        reminderId: reminder, ownerAgentId: "a1", expectedVersion: 3
    ) else { Issue.record("cancel must succeed"); return }
    #expect(canceledVersion == 4)
    #expect(accounts.appReminderRowForTesting(id: reminder)?.status == "canceled")
    #expect(accounts.appReminderEventsForTesting(reminderId: reminder).map(\.type) == ["scheduled", "snoozed", "updated", "canceled"])
    #expect(accounts.appReminderEventsForTesting(reminderId: reminder).map(\.version) == [1, 2, 3, 4])
}

@Test func appReminderOwnershipAndStatusFilterAreEnforced() {
    let accounts = EmailLoginDirectory()
    let first = accounts.createAppReminderForTesting(serverId: "s1", ownerAgentId: "a1", title: "One", fireAt: Date())
    let second = accounts.createAppReminderForTesting(serverId: "s1", ownerAgentId: "a2", title: "Two", fireAt: Date())
    _ = accounts.cancelAppReminder(reminderId: second, ownerAgentId: "a2", expectedVersion: 1)

    guard case .notFound = accounts.cancelAppReminder(reminderId: first, ownerAgentId: "a2", expectedVersion: 1) else {
        Issue.record("another agent must not mutate the reminder"); return
    }
    let scheduled = accounts.listAppReminders(serverId: "s1", ownerAgentId: "a1", status: "scheduled")
    #expect(scheduled.invalidStatus == false)
    #expect(scheduled.rows.map(\.id) == [first])
    let canceled = accounts.listAppReminders(serverId: "s1", ownerAgentId: "a2", status: "canceled")
    #expect(canceled.rows.map(\.id) == [second])
    #expect(accounts.listAppReminders(serverId: "s1", ownerAgentId: "a1", status: "bogus").invalidStatus)
    #expect(accounts.listAppReminders(serverId: "s2", ownerAgentId: "a1", status: nil).rows.isEmpty)
}

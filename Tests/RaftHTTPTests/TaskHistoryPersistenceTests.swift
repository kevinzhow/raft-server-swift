import Foundation
import Testing
@testable import RaftHTTP

/// The task owner persists canonical `task_events` in its existing strict
/// snapshot. The new event fields are one nested group: an old snapshot without
/// the group restores the rows as pre-canonical records (omitted from history),
/// while a present group must be complete. New keys are only added, so an older
/// binary can still decode a newer snapshot.

private func taskPersistenceEnvelope(taskEvents: String) -> Data {
    Data("""
    {"business":{"assigneeChangeEvents":[],"lastTaskServerWarning":null,"reminderEvents":[],"reminderRecords":[],"taskRecords":[],"taskWriteHolds":{},"taskEvents":\(taskEvents)},"dateEncoding":"foundation-reference-date-ieee754-binary64-hex","format":"raft.tasks-and-reminders","version":1}
    """.utf8)
}

@Test func oldTaskSnapshotWithoutHistoryGroupRestoresLegacyRowsAsAbsent() throws {
    let store = TasksAndRemindersStore()
    try store.restorePersistenceData(taskPersistenceEnvelope(taskEvents: """
    [{"actorType":"user","eventType":"created","taskId":"pre-canonical-task"}]
    """))
    #expect(store.taskEvents.count == 1)
    #expect(store.taskEvents.first?.eventType == "created")
    #expect(store.taskEvents.first?.history == nil)
    #expect(store.publishedTaskEvents(taskId: "pre-canonical-task").isEmpty)
}

@Test func canonicalTaskEventsPersistTheirCompleteHistoryGroupAndDoNotFabricateOldRows() throws {
    let store = TasksAndRemindersStore()
    try store.restorePersistenceData(taskPersistenceEnvelope(taskEvents: """
    [{"actorType":"user","eventType":"created","taskId":"pre-canonical-task"}]
    """))
    let created = store.appendTaskBatch(
        channelId: "channel", titles: ["persisted task"], creatorId: "agent-1", now: Date(timeIntervalSince1970: 1_800_000_000))
    let events = store.publishedTaskEvents(taskId: created[0].id)
    #expect(events.count == 1)
    let event = try #require(events.first)
    #expect(event.eventType == "created")
    #expect(event.actorType == "agent")
    #expect(event.history?.actorId == "agent-1")
    #expect(event.history?.seq == 1)
    #expect(event.history?.payloadJSON.contains("\"taskNumber\":1") == true)
    #expect(store.publishedTaskEvents(taskId: "pre-canonical-task").isEmpty)

    let exported = try store.exportPersistenceData()
    let object = try #require(try JSONSerialization.jsonObject(with: exported) as? [String: Any])
    let business = try #require(object["business"] as? [String: Any])
    let rows = try #require(business["taskEvents"] as? [[String: Any]])
    #expect(rows.count == 2)
    let legacy = try #require(rows.first { $0["taskId"] as? String == "pre-canonical-task" })
    #expect(legacy["history"] == nil)
    let canonical = try #require(rows.first { $0["taskId"] as? String == created[0].id })
    let history = try #require(canonical["history"] as? [String: Any])
    #expect(Set(history.keys) == ["id", "seq", "actorId", "payloadJSON", "createdAt"])

    let restored = TasksAndRemindersStore()
    try restored.restorePersistenceData(exported)
    #expect(restored.publishedTaskEvents(taskId: "pre-canonical-task").isEmpty)
    let roundTripped = restored.publishedTaskEvents(taskId: created[0].id)
    #expect(roundTripped == events)
}

@Test func partialTaskEventHistoryGroupRejectsTheSnapshot() {
    let store = TasksAndRemindersStore()
    #expect(throws: (any Error).self) {
        try store.restorePersistenceData(taskPersistenceEnvelope(taskEvents: """
        [{"actorType":"user","eventType":"created","history":{"id":"partial"},"taskId":"partial-task"}]
        """))
    }
    #expect(store.taskEvents.isEmpty)
    // `actorId` is nullable but still a required member of the group.
    #expect(throws: (any Error).self) {
        try store.restorePersistenceData(taskPersistenceEnvelope(taskEvents: """
        [{"actorType":"system","eventType":"closed","history":{"createdAt":"0000000000000000","id":"partial","payloadJSON":"{}","seq":1},"taskId":"partial-task"}]
        """))
    }
    #expect(store.taskEvents.isEmpty)
}

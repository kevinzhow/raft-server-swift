import Foundation
import Testing
import RaftDaemonClient

private let nowMs = 1_792_152_010_000

private func message(
    senderType: String = "human", timestamp: String = "2026-10-16T12:00:00.000Z", mentioned: Bool = false
) -> TurnTriggerMessage {
    .init(mentioned: mentioned, senderType: senderType, timestamp: timestamp)
}

@Test func noMessageIsAnOtherTriggerWithNoAge() {
    #expect(TurnTriggerTrace.messageAttrs(nil, nowMs: nowMs) { _ in nil } == .init(kind: "other"))
}

@Test func ageComesFromTheOldestMessageAndAnyMentionMakesAMention() {
    let older = message()
    let newer = message(timestamp: "2026-10-16T12:00:05.000Z", mentioned: true)
    let received: [String: Int] = [older.timestamp: nowMs - 3_000, newer.timestamp: nowMs - 1_000]
    #expect(TurnTriggerTrace.messageAttrs([newer, older], nowMs: nowMs) { received[$0.timestamp] } == .init(
        kind: "mention", triggerAgeMs: 10_000, localWaitMs: 3_000
    ))
}

@Test func askewedClockKeepsANegativeAge() {
    let future = message(timestamp: "2026-10-16T12:00:12.000Z")
    #expect(TurnTriggerTrace.messageAttrs([future], nowMs: nowMs) { _ in nil } == .init(
        kind: "message", triggerAgeMs: -2_000
    ))
}

@Test func thirdPartyAppEventsAreTheirOwnKind() {
    let attrs = TurnTriggerTrace.messageAttrs([message(senderType: "third_party_app")], nowMs: nowMs) { _ in nil }
    #expect(attrs.kind == "app")
}

@Test func appInboxItemsMapReminderCleanerHintAndOtherApps() {
    let item: (String, Int) -> TurnTriggerInboxItem = { TurnTriggerInboxItem(appId: $0, createdAtMs: $1) }
    #expect(TurnTriggerTrace.appInboxAttrs([item("system.cleaner", nowMs - 50), item("system.reminder", nowMs - 400)], nowMs: nowMs) == .init(
        kind: "reminder", triggerAgeMs: 400, localWaitMs: 400
    ))
    #expect(TurnTriggerTrace.appInboxAttrs([item("system.cleaner", nowMs)], nowMs: nowMs).kind == "wake_hint")
    #expect(TurnTriggerTrace.appInboxAttrs([item("acme.app", nowMs)], nowMs: nowMs).kind == "app")
}

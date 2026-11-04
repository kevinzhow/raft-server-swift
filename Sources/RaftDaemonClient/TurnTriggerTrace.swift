import Foundation

/// What woke a turn and how long it waited, for the end-to-end wake latency
/// view: only a kind and millisecond counts, no ids or content.
/// - `triggerAgeMs`: turn start − creation of the oldest trigger in the batch.
///   Message timestamps use the Server clock, so skew shows up here and
///   negative values are kept (filter them rather than hiding at 0). App inbox
///   items are minted locally, so their age uses one clock.
/// - `localWaitMs`: turn start − when this daemon received the oldest trigger;
///   local clock only, showing the part of the wait spent on this machine.
/// Ported from the upstream daemon trace helper.
public struct TurnTriggerMessage: Sendable, Equatable {
    public var mentioned: Bool
    public var senderType: String
    public var timestamp: String
    public init(mentioned: Bool = false, senderType: String, timestamp: String) {
        self.mentioned = mentioned
        self.senderType = senderType
        self.timestamp = timestamp
    }
}

public struct TurnTriggerInboxItem: Sendable, Equatable {
    public var appId: String
    public var createdAtMs: Int?
    public init(appId: String, createdAtMs: Int?) {
        self.appId = appId
        self.createdAtMs = createdAtMs
    }
}

public struct TurnTriggerAttrs: Sendable, Equatable {
    public var kind: String
    public var triggerAgeMs: Int?
    public var localWaitMs: Int?
    public init(kind: String, triggerAgeMs: Int? = nil, localWaitMs: Int? = nil) {
        self.kind = kind
        self.triggerAgeMs = triggerAgeMs
        self.localWaitMs = localWaitMs
    }
}

public enum TurnTriggerTrace {
    public static let wakeHintAppIds: Set<String> = ["system.cleaner"]

    public static func kindForAppId(_ appId: String) -> String {
        if appId == ReminderInboxDefinition.appId { return "reminder" }
        if wakeHintAppIds.contains(appId) { return "wake_hint" }
        return "app"
    }

    static func oldest(_ values: [Int?]) -> Int? {
        var minimum: Int?
        for value in values {
            guard let value else { continue }
            if minimum == nil || value < minimum! { minimum = value }
        }
        return minimum
    }

    static func ageAttrs(nowMs: Int, createdMs: Int?, receivedMs: Int?) -> (Int?, Int?) {
        let triggerAge = createdMs.map { Int((Double(nowMs - $0)).rounded()) }
        let localWait = receivedMs.map { max(0, Int((Double(nowMs - $0)).rounded())) }
        return (triggerAge, localWait)
    }

    static func parseMillis(_ timestamp: String) -> Int? {
        if let date = ISO8601DateFormatter().date(from: timestamp) {
            return Int((date.timeIntervalSince1970 * 1000).rounded())
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: timestamp) {
            return Int((date.timeIntervalSince1970 * 1000).rounded())
        }
        return nil
    }

    public static func messageAttrs(
        _ messages: [TurnTriggerMessage]?,
        nowMs: Int,
        receivedAtMs: (TurnTriggerMessage) -> Int?
    ) -> TurnTriggerAttrs {
        guard let messages, !messages.isEmpty else { return TurnTriggerAttrs(kind: "other") }
        let kind: String
        if messages.contains(where: \.mentioned) {
            kind = "mention"
        } else if messages.allSatisfy({ $0.senderType == "third_party_app" }) {
            kind = "app"
        } else {
            kind = "message"
        }
        let (triggerAge, localWait) = ageAttrs(
            nowMs: nowMs,
            createdMs: oldest(messages.map { Self.parseMillis($0.timestamp) }),
            receivedMs: oldest(messages.map { receivedAtMs($0) })
        )
        return TurnTriggerAttrs(kind: kind, triggerAgeMs: triggerAge, localWaitMs: localWait)
    }

    public static func appInboxAttrs(_ items: [TurnTriggerInboxItem], nowMs: Int) -> TurnTriggerAttrs {
        guard !items.isEmpty else { return TurnTriggerAttrs(kind: "other") }
        var first = items[0]
        for item in items.dropFirst() {
            let candidate = item.createdAtMs ?? Int.max
            let current = first.createdAtMs ?? Int.max
            if candidate < current { first = item }
        }
        let createdMs = oldest(items.map(\.createdAtMs))
        // The item is written to the local inbox when it is minted, so mint
        // time is also receive time.
        let (triggerAge, localWait) = ageAttrs(nowMs: nowMs, createdMs: createdMs, receivedMs: createdMs)
        return TurnTriggerAttrs(
            kind: kindForAppId(first.appId), triggerAgeMs: triggerAge, localWaitMs: localWait
        )
    }
}

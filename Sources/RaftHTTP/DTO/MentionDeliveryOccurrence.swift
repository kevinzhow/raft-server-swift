import Foundation

/// Upstream `mentionDeliveryOccurrences` (migration 0240) as a value group on
/// the formal mention row it belongs to. `occurrenceId` IS the mention row id,
/// exactly as upstream's primary key references `message_mentions.id`.
///
/// The group is optional on `StoredMention`: a snapshot written before this
/// slice has no key and restores as "no occurrence" (upstream's missing
/// occurrence, published as `unknown`). Only new optional keys are added, so an
/// older build can still restore a newer snapshot.
struct MentionDeliveryOccurrence: Codable, Sendable, Equatable {
    /// `recorded | server_decided | daemon_received | daemon_pending |
    /// daemon_drained | acked | terminal_error`. Kept as text because upstream
    /// stores text and `evaluate` must diagnose an unrecognised value instead of
    /// letting a typed decode reject the whole business snapshot.
    var state: String
    /// `unknown | immediate | busy`
    var deliveryPath: String
    var machineIdSnapshot: String?
    var launchIdSnapshot: String?
    var sessionIdSnapshot: String?
    var mentionRecordedAt: Date
    var serverDecidedAt: Date?
    var daemonReceivedAt: Date?
    var daemonPendingAt: Date?
    var daemonDrainedAt: Date?
    var ackedAt: Date?
    var terminalErrorAt: Date?
    var terminalErrorCode: String?
    var terminalDecision: MentionDeliveryTerminalDecision?
    var pendingCoalescedCount: Int
    var version: Int
    /// The exact `AgentMessage` JSON the server decided to deliver. Upstream
    /// stores the same snapshot in `delivery_payload`; recovery filters on its
    /// presence, so a mention whose payload was never prepared is readable but
    /// not redrivable (the declared degradation).
    var deliveryPayloadJSON: String?
    /// A one-shot latch in upstream (`redrive_count` pinned to 0 by the claim);
    /// retained so the diagnostic redrive route can be ported later.
    var redriveCount: Int
    var lastRedriveAt: Date?
    /// Automatic recovery rounds already spent while the daemon held the
    /// occurrence. Bounded to `MENTION_DELIVERY_MAX_RECOVERY_ROUNDS`.
    var recoveryCount: Int
}

/// Upstream `MentionDeliveryTerminalDecision`: bounded provenance only.
struct MentionDeliveryTerminalDecision: Codable, Sendable, Equatable {
    var layer: String
    var stage: String
    var originalDaemonCode: String?
}

enum MentionDeliveryState: String, Sendable {
    case recorded
    case serverDecided = "server_decided"
    case daemonReceived = "daemon_received"
    case daemonPending = "daemon_pending"
    case daemonDrained = "daemon_drained"
    case acked
    case terminalError = "terminal_error"

    var rank: Int {
        switch self {
        case .recorded: 0
        case .serverDecided: 1
        case .daemonReceived: 2
        case .daemonPending: 3
        case .daemonDrained: 4
        case .acked: 5
        case .terminalError: 6
        }
    }
}

/// The closed terminal-code set from `@botiverse/raft-shared`
/// (`MENTION_DELIVERY_TERMINAL_ERROR_CODES`, referenced by
/// `mentionDeliveryOccurrenceService.ts`).
enum MentionDeliveryTerminalCodes {
    static let all: Set<String> = [
        "IDENTITY_UNKNOWN", "IDENTITY_DRIFT", "QUOTA_LIMITED", "DELIVERY_REJECTED",
        "UNSUPPORTED_DELIVERY_PATH", "INSTRUMENT_FAILED", "REDELIVERY_EXHAUSTED",
    ]
}

/// The closed diagnostic result of `evaluateMentionDeliveryOccurrence`.
enum MentionDeliveryLookupResult: Equatable, Sendable {
    case notJoinable
    case instrumentFailed(missingReceipt: String, version: Int)
    case brokenHop(hop: String, version: Int)
    case terminalError(code: String, version: Int)
    case acked(version: Int)
}

enum MentionDeliveryOccurrenceEvaluation {
    /// Upstream bounds automatic recovery rounds for an occurrence the daemon
    /// already holds but never terminalises.
    static let maxRecoveryRounds = 3

    /// `mentionDeliveryOccurrenceService.evaluateMentionDeliveryOccurrence`.
    ///
    /// A state that claims a transition without its receipt is instrument
    /// failure, never an ordinary missing hop. A receipt that is *later* than
    /// the missing one excuses it as a broken hop instead: a stale row was
    /// written by a real transition whose own receipt landed.
    static func evaluate(_ row: MentionDeliveryOccurrence) -> MentionDeliveryLookupResult {
        guard let state = MentionDeliveryState(rawValue: row.state) else {
            return .instrumentFailed(missingReceipt: "UNRECOGNISED_STATE", version: row.version)
        }
        if !row.mentionRecordedAt.timeIntervalSinceReferenceDate.isFinite {
            return .instrumentFailed(missingReceipt: "MENTION_RECORDED", version: row.version)
        }
        if row.serverDecidedAt == nil {
            return laterReceiptExists(row, hop: "SERVER_DECISION") || state.rank >= 1
                ? .instrumentFailed(missingReceipt: "SERVER_DECISION", version: row.version)
                : .brokenHop(hop: "SERVER_DECISION", version: row.version)
        }
        if state == .terminalError {
            guard row.terminalErrorAt != nil,
                  let code = row.terminalErrorCode, MentionDeliveryTerminalCodes.all.contains(code) else {
                return .instrumentFailed(missingReceipt: "TERMINAL_ERROR", version: row.version)
            }
            return .terminalError(code: code, version: row.version)
        }
        if row.daemonReceivedAt == nil {
            return laterReceiptExists(row, hop: "DAEMON_RECEIVE") || state.rank >= 2
                ? .instrumentFailed(missingReceipt: "DAEMON_RECEIVE", version: row.version)
                : .brokenHop(hop: "DAEMON_RECEIVE", version: row.version)
        }
        if row.deliveryPath == "busy" && row.daemonPendingAt == nil {
            return laterReceiptExists(row, hop: "DAEMON_PENDING") || state.rank >= 3
                ? .instrumentFailed(missingReceipt: "DAEMON_PENDING", version: row.version)
                : .brokenHop(hop: "DAEMON_PENDING", version: row.version)
        }
        if row.daemonDrainedAt == nil {
            return laterReceiptExists(row, hop: "DAEMON_DRAIN") || state.rank >= 4
                ? .instrumentFailed(missingReceipt: "DAEMON_DRAIN", version: row.version)
                : .brokenHop(hop: "DAEMON_DRAIN", version: row.version)
        }
        if row.ackedAt == nil {
            return laterReceiptExists(row, hop: "ACK") || state.rank >= 5
                ? .instrumentFailed(missingReceipt: "ACK", version: row.version)
                : .brokenHop(hop: "ACK", version: row.version)
        }
        return .acked(version: row.version)
    }

    private static func laterReceiptExists(_ row: MentionDeliveryOccurrence, hop: String) -> Bool {
        switch hop {
        case "SERVER_DECISION":
            return row.daemonReceivedAt != nil || row.daemonPendingAt != nil
                || row.daemonDrainedAt != nil || row.ackedAt != nil || row.terminalErrorAt != nil
        case "DAEMON_RECEIVE":
            return row.daemonPendingAt != nil || row.daemonDrainedAt != nil
                || row.ackedAt != nil || row.terminalErrorAt != nil
        case "DAEMON_PENDING":
            return row.daemonDrainedAt != nil || row.ackedAt != nil || row.terminalErrorAt != nil
        case "DAEMON_DRAIN":
            return row.ackedAt != nil || row.terminalErrorAt != nil
        case "ACK":
            // Nothing is later than the terminal receipt; a terminal timestamp
            // carrying no code is the row this guard exists for.
            return row.terminalErrorAt != nil
        default:
            return false
        }
    }

    /// The initial row `insertMentionRowsWithOccurrenceRecords` writes.
    static func recorded(at date: Date) -> MentionDeliveryOccurrence {
        MentionDeliveryOccurrence(
            state: MentionDeliveryState.recorded.rawValue, deliveryPath: "unknown",
            machineIdSnapshot: nil, launchIdSnapshot: nil, sessionIdSnapshot: nil,
            mentionRecordedAt: date, serverDecidedAt: nil, daemonReceivedAt: nil,
            daemonPendingAt: nil, daemonDrainedAt: nil, ackedAt: nil, terminalErrorAt: nil,
            terminalErrorCode: nil, terminalDecision: nil, pendingCoalescedCount: 0,
            version: 0, deliveryPayloadJSON: nil, redriveCount: 0, lastRedriveAt: nil,
            recoveryCount: 0)
    }

    /// Identity frozen on the server decision, checked by every daemon receipt.
    struct Identity: Sendable, Equatable {
        var machineId: String
        var launchId: String
        var sessionId: String
    }

    static func identityMatches(_ row: MentionDeliveryOccurrence, _ identity: Identity) -> Bool {
        row.machineIdSnapshot == identity.machineId
            && row.launchIdSnapshot == identity.launchId
            && row.sessionIdSnapshot == identity.sessionId
    }
}

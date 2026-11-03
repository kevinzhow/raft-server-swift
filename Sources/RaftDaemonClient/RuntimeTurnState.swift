import Foundation

/// Tracks Codex app-server turn lifecycle state for stdin steering: turn ids,
/// pending acceptance, the post-tool steering gate and the activity/usage
/// evidence used to decide whether a turn produced anything. Ported from the
/// upstream daemon helper.
public final class RuntimeTurnState {
    private var currentTurnId: String?
    private var pendingTurnId: String?
    private var turnInProgress = false
    private var currentTurnHadRuntimeActivity = false
    private var currentTurnHadTokenUsage = false
    private var currentTurnHadNonEmptyInput = false
    private var pendingNonEmptyInputTurnIds: [String] = []
    private var completedTurnIds: [String] = []
    private var steeringGateActive = false

    public init() {}

    public func reset() {
        currentTurnId = nil
        pendingTurnId = nil
        turnInProgress = false
        currentTurnHadRuntimeActivity = false
        currentTurnHadTokenUsage = false
        currentTurnHadNonEmptyInput = false
        pendingNonEmptyInputTurnIds = []
        completedTurnIds = []
        steeringGateActive = false
    }

    public var activeTurnId: String? { currentTurnId }
    public var hasLiveTurn: Bool { turnInProgress || pendingTurnId != nil }
    public var canSteerBusy: Bool { currentTurnId != nil && pendingTurnId == nil && !steeringGateActive }

    public func markTurnStarted(_ turnId: String? = nil) {
        if let startedTurnId = turnId ?? pendingTurnId {
            currentTurnId = startedTurnId
            let hadPendingInput = pendingNonEmptyInputTurnIds.contains(startedTurnId)
            pendingNonEmptyInputTurnIds.removeAll { $0 == startedTurnId }
            currentTurnHadNonEmptyInput = hadPendingInput
        }
        pendingTurnId = nil
        turnInProgress = true
        currentTurnHadRuntimeActivity = false
        currentTurnHadTokenUsage = false
        steeringGateActive = false
    }

    public func noteTurnAccepted(_ turnId: String) {
        pendingTurnId = turnId
    }

    public func markProgress() {
        currentTurnHadRuntimeActivity = true
        steeringGateActive = false
    }

    public func markToolBoundary() {
        currentTurnHadRuntimeActivity = true
        steeringGateActive = true
    }

    public func markTokenUsage() {
        currentTurnHadTokenUsage = true
    }

    public func markNonEmptyInputForTurn(_ turnId: String?) {
        guard let turnId, !completedTurnIds.contains(turnId) else { return }
        if turnInProgress && currentTurnId == turnId {
            currentTurnHadNonEmptyInput = true
        } else if !pendingNonEmptyInputTurnIds.contains(turnId) {
            pendingNonEmptyInputTurnIds.append(turnId)
        }
    }

    public func hasNonEmptyInputEvidence() -> Bool { currentTurnHadNonEmptyInput }

    public func completedWithoutRuntimeActivity() -> Bool {
        turnInProgress && !currentTurnHadRuntimeActivity && !currentTurnHadTokenUsage
    }

    public func markTurnCompleted() {
        if let currentTurnId {
            completedTurnIds.append(currentTurnId)
            if completedTurnIds.count > 16 { completedTurnIds.removeFirst() }
        }
        currentTurnId = nil
        pendingTurnId = nil
        turnInProgress = false
        currentTurnHadRuntimeActivity = false
        currentTurnHadTokenUsage = false
        currentTurnHadNonEmptyInput = false
        steeringGateActive = false
    }
}

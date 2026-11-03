import Testing
import RaftDaemonClient

@Test func allowsBusySteeringDuringAnActiveTurnButNotFromAnAcceptedResponse() {
    let state = RuntimeTurnState()
    state.markTurnStarted("turn-1")
    #expect(state.activeTurnId == "turn-1")
    #expect(state.canSteerBusy)

    let accepted = RuntimeTurnState()
    accepted.noteTurnAccepted("turn-1")
    #expect(accepted.activeTurnId == nil)
    #expect(!accepted.canSteerBusy)
    accepted.markTurnStarted("turn-1")
    #expect(accepted.activeTurnId == "turn-1")
    #expect(accepted.canSteerBusy)
}

@Test func blocksStaleActiveTurnSteeringWhileANewTurnIsPending() {
    let state = RuntimeTurnState()
    state.markTurnStarted("turn-1")
    state.noteTurnAccepted("turn-2")
    #expect(state.activeTurnId == "turn-1")
    #expect(!state.canSteerBusy)
    state.markTurnStarted("turn-2")
    #expect(state.activeTurnId == "turn-2")
    #expect(state.canSteerBusy)
}

@Test func gatesBusySteeringAfterAToolBoundaryUntilProgress() {
    let state = RuntimeTurnState()
    state.markTurnStarted("turn-1")
    state.markToolBoundary()
    #expect(state.activeTurnId == "turn-1")
    #expect(!state.canSteerBusy)
    state.markProgress()
    #expect(state.activeTurnId == "turn-1")
    #expect(state.canSteerBusy)
}

@Test func clearsTurnAndGateOnCompletionAndReset() {
    let completed = RuntimeTurnState()
    completed.markTurnStarted("turn-1")
    completed.markToolBoundary()
    completed.markTurnCompleted()
    #expect(completed.activeTurnId == nil)
    #expect(!completed.canSteerBusy)

    let reset = RuntimeTurnState()
    reset.markTurnStarted("turn-1")
    reset.markToolBoundary()
    reset.reset()
    #expect(reset.activeTurnId == nil)
    #expect(!reset.canSteerBusy)
}

@Test func hasLiveTurnCoversAcceptedAndRunningTurnsNotCompletedOnes() {
    let state = RuntimeTurnState()
    #expect(!state.hasLiveTurn)
    state.noteTurnAccepted("turn-1")
    #expect(state.hasLiveTurn)
    state.markTurnStarted("turn-1")
    #expect(state.hasLiveTurn)
    state.markTurnCompleted()
    #expect(!state.hasLiveTurn)
}

@Test func tracksNonEmptyInputAndActivityEvidenceAcrossTurns() {
    let state = RuntimeTurnState()
    state.markTurnStarted("turn-1")
    state.markNonEmptyInputForTurn("turn-1")
    #expect(state.hasNonEmptyInputEvidence())
    #expect(state.completedWithoutRuntimeActivity(), "non-empty input alone is not runtime activity")
    state.markTokenUsage()
    #expect(!state.completedWithoutRuntimeActivity())
    state.markTurnCompleted()
    #expect(!state.hasNonEmptyInputEvidence())

    let pending = RuntimeTurnState()
    pending.noteTurnAccepted("turn-2")
    pending.markNonEmptyInputForTurn("turn-2")
    pending.markTurnStarted("turn-2")
    #expect(pending.hasNonEmptyInputEvidence())

    let quiet = RuntimeTurnState()
    quiet.markTurnStarted("turn-3")
    #expect(quiet.completedWithoutRuntimeActivity())
    quiet.markProgress()
    #expect(!quiet.completedWithoutRuntimeActivity())
    quiet.markTurnCompleted()
    quiet.markNonEmptyInputForTurn("turn-3")
    #expect(!quiet.hasNonEmptyInputEvidence(), "a completed turn cannot collect non-empty input evidence")
}

@Test func completedTurnIdsAreBoundedToTheMostRecentSixteen() {
    let state = RuntimeTurnState()
    for index in 0..<20 {
        state.markTurnStarted("turn-\(index)")
        state.markTurnCompleted()
    }
    state.markNonEmptyInputForTurn("turn-0")
    #expect(!state.hasNonEmptyInputEvidence())
    state.markNonEmptyInputForTurn("turn-19")
    #expect(!state.hasNonEmptyInputEvidence())
}

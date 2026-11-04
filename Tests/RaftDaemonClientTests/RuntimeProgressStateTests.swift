import Testing
import RaftDaemonClient

@Test func recordsRuntimeEventsAndClearsTheStaleLatch() {
    let state = RuntimeProgressState(nowMs: 100)
    state.markStale(nowMs: 200)
    state.noteRuntimeEvent(eventKind: "tool_output", nowMs: 300)
    #expect(state.lastEventAt == 300)
    #expect(state.lastEventKind == "tool_output")
    #expect(state.staleSince == nil)
    #expect(!state.isStale)
}

@Test func internalProgressDoesNotChangeTheLastEventKind() {
    let state = RuntimeProgressState(nowMs: 100)
    state.noteRuntimeEvent(eventKind: "tool_output", nowMs: 200)
    state.markStale(nowMs: 300)
    state.noteInternalProgress(observedAtMs: 350)
    #expect(state.lastEventAt == 350)
    #expect(state.lastEventKind == "tool_output")
    #expect(state.staleSince == nil)
}

@Test func preservesTheFirstStaleTimestamp() {
    let state = RuntimeProgressState(nowMs: 100)
    #expect(state.markStale(nowMs: 200) == 200)
    #expect(state.markStale(nowMs: 300) == 200)
    #expect(state.staleSince == 200)
}

@Test func ageComesFromTheLastEvent() {
    let state = RuntimeProgressState(nowMs: 100)
    #expect(state.ageMs(nowMs: 350) == 250)
}

@Test func stallAgeAnchorsOnTurnStartWhileLastEventAgeDoesNot() {
    let state = RuntimeProgressState(nowMs: 0)
    state.noteRuntimeEvent(eventKind: "turn_end", nowMs: 1_000)
    state.noteTurnStarted(nowMs: 100_000)
    #expect(state.ageMs(nowMs: 100_500) == 500, "stall age counts from the later turn start")
    #expect(state.lastEventAgeMs(nowMs: 100_500) == 99_500, "last_event_age keeps its literal meaning")

    state.noteRuntimeEvent(eventKind: "tool_output", nowMs: 200_000)
    #expect(state.ageMs(nowMs: 200_100) == 100, "a newer runtime event wins over an older turn start")
    #expect(state.lastEventAgeMs(nowMs: 200_100) == 100)
}

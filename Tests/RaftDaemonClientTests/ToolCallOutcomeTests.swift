import RaftDaemonClient
import Testing

@Test func daemonMeasuresACallFromItsStartToItsEndByCallId() {
    var starts = ToolCallOutcomeBookkeeping.OpenCalls()
    ToolCallOutcomeBookkeeping.noteStart(&starts, callId: "a", nowMs: 1_000)
    ToolCallOutcomeBookkeeping.noteStart(&starts, callId: "b", nowMs: 1_200)
    #expect(ToolCallOutcomeBookkeeping.finish(&starts, callId: "b", ok: true, durationMs: nil, exitCode: nil, nowMs: 1_700) == .init(callId: "b", ok: true, durationMs: 500))
    #expect(ToolCallOutcomeBookkeeping.finish(&starts, callId: "a", ok: false, durationMs: nil, exitCode: nil, nowMs: 3_000) == .init(callId: "a", ok: false, durationMs: 2_000))
    #expect(starts.count == 0, "finished calls are forgotten")
}

@Test func runtimeDurationWinsAndNonsenseDurationsAreDropped() {
    var starts = ToolCallOutcomeBookkeeping.OpenCalls()
    ToolCallOutcomeBookkeeping.noteStart(&starts, callId: "a", nowMs: 1_000)
    #expect(ToolCallOutcomeBookkeeping.finish(&starts, callId: "a", ok: nil, durationMs: 43, exitCode: nil, nowMs: 9_000)?.durationMs == 43)
    ToolCallOutcomeBookkeeping.noteStart(&starts, callId: "b", nowMs: 1_000)
    #expect(ToolCallOutcomeBookkeeping.finish(&starts, callId: "b", ok: nil, durationMs: -1, exitCode: nil, nowMs: 1_010)?.durationMs == 10)
}

@Test func endWithNothingReportedYieldsNoOutcomeAndUnknownIdStillReports() {
    var starts = ToolCallOutcomeBookkeeping.OpenCalls()
    #expect(ToolCallOutcomeBookkeeping.finish(&starts, callId: nil, ok: nil, durationMs: nil, exitCode: nil, nowMs: 5) == nil)
    #expect(ToolCallOutcomeBookkeeping.finish(&starts, callId: "never-started", ok: true, durationMs: nil, exitCode: 2, nowMs: 5) == .init(callId: "never-started", ok: true, durationMs: nil, exitCode: 2))
}

@Test func openCallsAreBoundedSoAnUnendingRuntimeCannotGrowTheMap() {
    var starts = ToolCallOutcomeBookkeeping.OpenCalls()
    for index in 0..<(ToolCallOutcomeBookkeeping.maxOpenToolCalls + 10) {
        ToolCallOutcomeBookkeeping.noteStart(&starts, callId: "c\(index)", nowMs: index)
    }
    #expect(starts.count == ToolCallOutcomeBookkeeping.maxOpenToolCalls)
    #expect(starts.starts["c0"] == nil, "the oldest open call is dropped first")
    #expect(starts.starts["c\(ToolCallOutcomeBookkeeping.maxOpenToolCalls + 9)"] != nil)
}

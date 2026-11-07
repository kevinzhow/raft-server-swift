import Dispatch
import Synchronization
import RaftDaemonClient
import Testing

@Test func turnSummaryFoldsEntriesAndSendOutcomesUntilFinish() {
    let tracker = DaemonTurnSummaryTracker()
    #expect(tracker.begin(agentId: "a", now: 10, trigger: .init(target: "#general", sender: "richard", messageId: "m1")).isEmpty)
    tracker.observe(agentId: "a", entries: [
        .toolStart(toolName: "Bash", toolInput: "git push origin HEAD", callId: "c1"),
        .init(kind: .other),
    ], now: 11)
    tracker.observe(agentId: "a", entries: [.toolEnd(callId: "c1", ok: false)], now: 12)
    tracker.noteSendOutcome(agentId: "a", state: "held", messageId: nil, now: 13)
    tracker.noteSendOutcome(agentId: "a", state: "sent", messageId: "r1", now: 14)
    let entries = tracker.finish(agentId: "a", outcome: "completed", now: 20)
    #expect(entries.count == 1)
    guard case .turnSummary(let summary) = entries[0] else {
        Issue.record("expected a turn summary")
        return
    }
    #expect(summary.startedAt == 10)
    #expect(summary.endedAt == 20)
    #expect(summary.outcome == "completed")
    #expect(summary.trigger == .init(target: "#general", sender: "richard", messageId: "m1"))
    #expect(summary.actions.map { "\($0.kind):\($0.count)" } == ["version_control:1"])
    #expect(summary.toolCalls == 1)
    #expect(summary.problems.map { "\($0.kind):\($0.reason):\($0.at)" } == ["version_control:call_failed:12", "send_message:send_held:13"])
    #expect(summary.problemCount == 2)
    #expect(summary.messagesSent == 1)
    #expect(summary.lastReplyMessageId == "r1")
    #expect(tracker.finish(agentId: "a", outcome: "completed", now: 21).isEmpty, "a turn is summarized once")
}

@Test func newTurnClosesAnUnfinishedOneAndToolActivityWithoutBeginOpensOne() {
    let tracker = DaemonTurnSummaryTracker()
    tracker.observe(agentId: "a", entries: [.toolStart(toolName: "Bash", toolInput: "ls", callId: "c1")], now: 5)
    let previous = tracker.begin(agentId: "a", now: 30, trigger: nil, previousOutcome: "failed")
    #expect(previous.count == 1)
    guard case .turnSummary(let summary) = previous[0] else {
        Issue.record("expected a turn summary")
        return
    }
    #expect(summary.outcome == "failed")
    #expect(summary.startedAt == 5)
    #expect(summary.trigger == nil)
    tracker.noteSendOutcome(agentId: "b", state: "sent", messageId: "x", now: 31)
    #expect(tracker.finish(agentId: "b", outcome: "completed", now: 32).isEmpty, "no turn, no summary")
}

@Test func turnOutcomeForActivityEndsOnIdleStopAndCrashOnly() {
    #expect(DaemonTurnSummaryRules.outcomeForActivity(activityKind: "online", detailKind: "idle") == "completed")
    #expect(DaemonTurnSummaryRules.outcomeForActivity(activityKind: "offline", detailKind: "stopped") == "interrupted")
    #expect(DaemonTurnSummaryRules.outcomeForActivity(activityKind: "offline", detailKind: "runtime_crashed") == "failed")
    #expect(DaemonTurnSummaryRules.outcomeForActivity(activityKind: "offline", detailKind: "runtime_unavailable") == "failed")
    #expect(DaemonTurnSummaryRules.outcomeForActivity(activityKind: "error", detailKind: "runtime_error") == nil)
    #expect(DaemonTurnSummaryRules.outcomeForActivity(activityKind: "working", detailKind: "tool_end") == nil)
}

@Test func triggerIsTheFirstMessagesTargetSenderAndId() {
    let channel = DaemonAgentMessageInfo(
        channelId: "c", channelName: "proj-runtime", channelType: "channel",
        senderName: "Tenny", messageId: "07a75d55-0000"
    )
    #expect(turnTriggerFromMessages([channel]) == .init(
        target: "#proj-runtime", channelId: "c", sender: "Tenny", messageId: "07a75d55-0000"
    ))
    let thread = DaemonAgentMessageInfo(
        channelId: "t", channelName: "thread-9b526607", channelType: "thread",
        parentChannelName: "proj-runtime", parentChannelType: "channel",
        senderName: "Tenny", messageId: "m2"
    )
    #expect(turnTriggerFromMessages([thread])?.target == "#proj-runtime:9b526607")
    #expect(turnTriggerFromMessages([]) == nil)
}

@Test func concurrentTurnSummaryObservationsAndFinishesKeepOneCompleteSummary() throws {
    let tracker = DaemonTurnSummaryTracker()
    let batch: [DaemonTrajectoryEntry] = [
        .toolStart(toolName: "read_file", toolInput: "", callId: "c1"),
        .init(kind: .other),
        .toolStart(toolName: "Bash", toolInput: "git push origin HEAD", callId: nil),
        .toolStart(toolName: "grep", toolInput: "", callId: nil),
        .toolEnd(callId: nil, ok: true, exitCode: 7),
        .toolEnd(callId: "c1", ok: false, exitCode: 9),
        .toolEnd(callId: nil, ok: false),
    ]
    // An observation opens the unknown turn and fixes first-action order. The
    // mixed explicit/unmatched ends also exercise FIFO association within a batch.
    tracker.observe(agentId: "a", entries: batch, now: 10)
    tracker.noteSendOutcome(agentId: "a", state: "held", messageId: nil, now: 11)
    tracker.noteSendOutcome(agentId: "a", state: "sent", messageId: "r1", now: 12)
    let reports = 256
    DispatchQueue.concurrentPerform(iterations: reports) { _ in
        tracker.observe(agentId: "a", entries: batch, now: 13)
        tracker.noteSendOutcome(agentId: "a", state: "held", messageId: nil, now: 14)
        tracker.noteSendOutcome(agentId: "a", state: "sent", messageId: nil, now: 15)
    }

    // Every update has returned before finishes race. Collect only the actual
    // public entries, without holding the result mutex across tracker calls.
    let finished = Mutex<[DaemonTurnSummaryEntry]>([])
    DispatchQueue.concurrentPerform(iterations: reports) { _ in
        let entries = tracker.finish(agentId: "a", outcome: "completed", now: 5)
        finished.withLock { $0.append(contentsOf: entries) }
    }
    let entries = finished.withLock { $0 }
    #expect(entries.count == 1)
    let entry = try #require(entries.first)
    guard case .turnSummary(let summary) = entry else {
        Issue.record("expected a turn summary")
        return
    }
    #expect(summary.v == 1)
    #expect(summary.startedAt == 10)
    #expect(summary.endedAt == 10, "end time never precedes the start")
    #expect(summary.outcome == "completed")
    #expect(summary.trigger == nil)
    #expect(summary.actions.map { "\($0.kind):\($0.count)" } == [
        "read_file:257", "version_control:257", "search:257",
    ])
    #expect(summary.toolCalls == 771)
    #expect(summary.messagesSent == 257)
    #expect(summary.lastReplyMessageId == "r1", "nil sent ids preserve the last actual reply id")
    #expect(summary.problemCount == 1_028)
    #expect(summary.problems.count == 20, "only the stored problems are capped, not the total")
    #expect(Array(summary.problems.prefix(4)) == [
        DaemonTurnProblem(kind: "version_control", reason: "exit_nonzero", exitCode: 7, at: 10),
        DaemonTurnProblem(kind: "read_file", reason: "call_failed", exitCode: 9, at: 10),
        DaemonTurnProblem(kind: "search", reason: "call_failed", at: 10),
        DaemonTurnProblem(kind: "send_message", reason: "send_held", at: 11),
    ])
    let toolKinds = summary.problems.filter { $0.reason != "send_held" }.map(\.kind)
    let batchProblemKinds = ["version_control", "read_file", "search"]
    #expect(toolKinds.enumerated().allSatisfy { index, kind in
        kind == batchProblemKinds[index % batchProblemKinds.count]
    }, "each observation preserves entry order and unmatched FIFO association")
    #expect(tracker.finish(agentId: "a", outcome: "completed", now: 20).isEmpty)
}

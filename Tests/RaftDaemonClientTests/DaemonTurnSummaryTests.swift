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

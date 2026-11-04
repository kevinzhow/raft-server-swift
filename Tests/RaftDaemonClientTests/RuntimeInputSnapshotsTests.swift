import Testing
import RaftDaemonClient

@Test func emptyResumeCopyIsIndependentOfDeliveryMode() {
    #expect(RuntimeInputSnapshots.formatResumeEmptyPrompt() == "No new messages while you were away. Nothing to do — just stop.")
}

@Test func unreadResumeCopyDescribesTheCatchUpWork() {
    let prompt = RuntimeInputSnapshots.formatResumeUnreadSummaryPrompt([
        .init(target: "#general", count: 2), .init(target: "dm:@bob", count: 1),
    ])
    #expect(prompt == """
    You have unread messages from while you were offline:
    - #general: 2 unread
    - dm:@bob: 1 unread

    Use `raft message read` to catch up on the channels listed above, then stop. Read each listed channel at most once unless a read fails. Do NOT call `raft message check` in this mode. If the history reveals a direct request, assignment, @mention, review request, or task clearly addressed to you, switch into active handling instead of stopping: reply using `raft message send --target <exact target>` and claim the relevant task with `raft task claim` before starting work. Otherwise, do NOT send any message in this mode.
    """)
}

@Test func inboxNoticesCarryReadingGuidance() {
    let notice = RuntimeInputSnapshots.formatInboxUpdateRuntimeInput([
        .init(target: "#general", pendingCount: 1, firstMessageId: "00000000", latestSenderName: "richard", latestMessageId: "00000000"),
    ], pendingMessages: 1, changedTargets: 1)
    #expect(notice == """
    [Raft inbox notice:
    Inbox update: 1 message pending your read across all conversations; 1 changed target
    #general  pending: 1 message · first msg=00000000 · latest sender @richard · latest msg=00000000
    ]
    These messages have not been read. Choose when to read them: `raft message read --target <target> --unread` reads one conversation's unread messages; `raft message check` reads all of them.
    """)
}

@Test func unreadSuffixesRenderEverySuppliedTargetAndCount() {
    let unread: [UnreadTarget] = [.init(target: "#general", count: 12), .init(target: "dm:@bob", count: 1)]
    #expect(RuntimeInputSnapshots.formatOtherUnreadChannelsSuffix(unread) == """


    You also have unread messages in other channels:
    - #general: 12 unread
    - dm:@bob: 1 unread

    Run `raft inbox check` at a natural breakpoint if you choose to inspect those targets; it lists every unread conversation with the command that opens it.
    """)
    #expect(RuntimeInputSnapshots.formatBoundedStartupUnreadSuffix(unread) == """


    Some unread channels may not be included in this bounded startup batch:
    - #general: 12 unread
    - dm:@bob: 1 unread

    Run `raft inbox check` at a natural breakpoint if you choose to inspect those targets; it lists every unread conversation with the command that opens it.
    """)
}

@Test func missingUnreadTargetsEmitNoSuffix() {
    #expect(RuntimeInputSnapshots.formatOtherUnreadChannelsSuffix(nil) == "")
    #expect(RuntimeInputSnapshots.formatBoundedStartupUnreadSuffix(nil) == "")
    #expect(RuntimeInputSnapshots.formatOtherUnreadChannelsSuffix([]) == "")
    #expect(RuntimeInputSnapshots.formatBoundedStartupUnreadSuffix([]) == "")
}

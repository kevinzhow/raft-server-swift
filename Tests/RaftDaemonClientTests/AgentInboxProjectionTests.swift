import Foundation
import Testing
import RaftDaemonClient

private func targetRowKeysWithout(_ keys: String...) -> Set<String> {
    Set(AgentInboxFlags.targetRowKeys.filter { !keys.contains($0) })
}

@Test func projectionGroupsPendingMessagesByTargetWithoutContent() {
    let rows = AgentInboxProjection.projectSnapshot([
        .init(seq: 10, messageId: "aaaaaaaa-0000-4000-8000-000000000000",
              channelId: "thread-channel-id", channelType: "thread",
              channelName: "thread-12345678-aaaa-bbbb-cccc-000000000000",
              parentChannelType: "channel", parentChannelName: "proj-aiax",
              senderType: "human", senderName: "tygg"),
        .init(seq: 12, messageId: "bbbbbbbb-0000-4000-8000-000000000000",
              channelId: "thread-channel-id", channelType: "thread",
              channelName: "thread-12345678-aaaa-bbbb-cccc-000000000000",
              parentChannelType: "channel", parentChannelName: "proj-aiax",
              senderType: "agent", senderName: "Jianwei"),
        .init(seq: 11, id: "cccccccc-0000-4000-8000-000000000000",
              channelId: "dm-channel-id", channelType: "dm", channelName: "tygg",
              senderType: "human", senderName: "tygg", taskStatus: "todo"),
    ])
    #expect(rows.count == 2)
    #expect(rows[0].target == "#proj-aiax:12345678")
    #expect(rows[0].pendingCount == 2)
    #expect(rows[0].firstPendingMsgId == "aaaaaaaa-0000-4000-8000-000000000000")
    #expect(rows[0].firstPendingSeq == 10)
    #expect(rows[0].latestMsgId == "bbbbbbbb-0000-4000-8000-000000000000")
    #expect(rows[0].latestSeq == 12)
    #expect(rows[0].latestSenderName == "Jianwei")
    #expect(rows[0].flags == ["thread"])
    #expect(rows[1].target == "dm:@tygg")
    #expect(rows[1].flags == ["dm", "task"])
}

@Test func mentionFlagsAreRecipientSpecific() {
    let rows = AgentInboxProjection.projectSnapshot([
        .init(seq: 20, messageId: "dddddddd-0000-4000-8000-000000000000", channelType: "channel", channelName: "proj-aiax", senderType: "human", senderName: "tygg"),
        .init(seq: 21, messageId: "eeeeeeee-0000-4000-8000-000000000000", channelType: "channel", channelName: "proj-runtime", senderType: "human", senderName: "tygg", mentioned: true),
    ])
    #expect(rows.first { $0.target == "#proj-aiax" }?.flags == [])
    #expect(rows.first { $0.target == "#proj-runtime" }?.flags == ["mention"])
}

@Test func notifyOnlyOutsiderReplyGuidanceIsPreserved() {
    let rows = AgentInboxProjection.projectSnapshot([
        .init(seq: 22, messageId: "ffffffff-0000-4000-8000-000000000000", channelType: "thread",
              channelName: "thread-12345678-aaaa-bbbb-cccc-000000000000",
              parentChannelType: "channel", parentChannelName: "proj-aiax",
              senderType: "human", senderName: "tygg", mentioned: true, nonMemberMention: true),
    ])
    #expect(rows[0].flags == ["mention", "non_member_mention", "thread"])
    let output = AgentInboxProjection.formatDelta(rows)
    #expect(output.contains("If no reply is needed, no action is required. Otherwise, DM the person who mentioned you or join the channel to participate"))
}

@Test func generatedBucketInvariantsHold() {
    let messages: [AgentInboxProjectionMessage] = [
        .init(seq: 1, messageId: "generated-0001", channelType: "channel", channelName: "proj-runtime",
              senderType: "human", senderName: "tygg", taskNumber: nil, taskStatus: "todo", mentioned: false),
        .init(seq: 2, messageId: "generated-0002", channelType: "dm", channelName: "tygg",
              senderType: "agent", senderName: "Jianwei", mentioned: true),
        .init(seq: 3, messageId: "generated-0003", channelType: "thread",
              channelName: "thread-feedface-0000-4000-8000-000000000000",
              parentChannelType: "channel", parentChannelName: "proj-runtime",
              senderType: "system", senderName: "system", taskNumber: 7),
        .init(seq: 4, messageId: "generated-0004", channelType: "dm", channelName: "stdrc",
              senderType: "third_party_app", senderName: "external-build-app", mentioned: false),
    ]
    let rows = AgentInboxProjection.projectSnapshot(messages)
    #expect(rows.count == 4)
    let runtime = rows.first { $0.target == "#proj-runtime" }!
    #expect(runtime.pendingCount == 1)
    #expect(runtime.latestSenderType == "human")
    #expect(runtime.flags == ["task"])
    let thread = rows.first { $0.target == "#proj-runtime:feedface" }!
    #expect(thread.flags == ["task", "thread"])
    let dm = rows.first { $0.target == "dm:@tygg" }!
    #expect(dm.flags == ["dm", "mention"])
    #expect(dm.latestSenderType == "agent")
    #expect(rows.map(\.latestSeq) == [4, 3, 2, 1])
    #expect(rows.first { $0.target == "dm:@stdrc" }?.latestSenderType == "third_party_app")
}

@Test func explicitStructuredM2AttentionHintIsRendered() {
    let hint = AttentionHint(
        schema: "attention-dependency-hint.v1", trigger: "M2", scope: "#proj-runtime",
        suggestedCommand: "raft channel mute \"#proj-runtime\"",
        copy: "You've received 12 updates from #proj-runtime with no action taken. If this channel doesn't need your attention: raft channel mute \"#proj-runtime\" -- @mentions still reach you; followed threads keep delivering until you unfollow them.",
        copyVersion: 1, epochMs: 123,
        thresholds: .init(K: 12, windowMs: 7 * 24 * 60 * 60 * 1000)
    )
    var messages: [AgentInboxProjectionMessage] = []
    for index in 0..<12 {
        messages.append(.init(
            seq: index + 1, messageId: String(format: "%08d-0000-4000-8000-000000000000", index + 1),
            channelId: "channel-proj-runtime", channelType: "channel", channelName: "proj-runtime",
            senderType: "human", senderName: "tygg",
            attentionHint: index == 11 ? hint : nil
        ))
    }
    let rows = AgentInboxProjection.projectSnapshot(messages)
    #expect(rows.count == 1)
    #expect(rows[0].attentionHint?.trigger == "M2")
    #expect(rows[0].attentionHint?.scope == "#proj-runtime")
    #expect(rows[0].attentionHint?.thresholds.K == 12)
    let delta = AgentInboxProjection.formatDelta(rows, totalPendingMessages: 12)
    #expect(delta.contains("attention_hint="))
    #expect(delta.contains("\"schema\":\"attention-dependency-hint.v1\""))
    #expect(delta.contains("\"trigger\":\"M2\""))
    #expect(delta.contains("followed threads keep delivering until you unfollow them"))
    #expect(!delta.contains("must not leak"))
}

@Test func noHintIsSynthesizedWithoutExplicitOraclePayload() {
    let messages = (0..<12).map { index in
        AgentInboxProjectionMessage(
            seq: index + 1, messageId: String(format: "%08d-0000-4000-8000-000000000000", index + 1),
            channelId: "channel-proj-runtime", channelType: "channel", channelName: "proj-runtime",
            senderType: "human", senderName: "tygg"
        )
    }
    let rows = AgentInboxProjection.projectSnapshot(messages)
    #expect(rows[0].attentionHint == nil)
    #expect(rows[0].flags == [])
}

@Test func formattingRendersTargetRowsWithoutPreviews() {
    let rows = AgentInboxProjection.projectSnapshot([
        .init(seq: 1, messageId: "dddddddd-0000-4000-8000-000000000000", channelType: "channel",
              channelName: "proj-runtime", senderType: "human", senderName: "tygg"),
    ])
    let snapshot = AgentInboxProjection.formatSnapshot(rows)
    #expect(snapshot.hasPrefix("Inbox: 1 pending target"))
    #expect(snapshot.contains("#proj-runtime"))
    #expect(snapshot.contains("first msg=dddddddd"))
    #expect(!snapshot.contains("hidden"))
    let delta = AgentInboxProjection.formatDelta(rows)
    #expect(delta.hasPrefix("Inbox update: 1 changed target"))
    let totalDelta = AgentInboxProjection.formatDelta(rows, totalPendingMessages: 3)
    #expect(totalDelta.hasPrefix("Inbox update: 3 messages pending your read across all conversations; 1 changed target"))
    #expect(!totalDelta.split(separator: "\n")[0].contains("unread"))
}

@Test func thirdPartyEventNoticeStaysAGroupedPendingProjection() {
    let rows = AgentInboxProjection.projectSnapshot([
        .init(messageId: "11111111-0000-4000-8000-000000000000", channelId: "third-party-agent-events:agent-123",
              channelType: "dm", channelName: "third-party-agent-events:agent-123",
              senderType: "third_party_app", senderName: "task44-demo-third-party"),
        .init(messageId: "22222222-0000-4000-8000-000000000000", channelId: "third-party-agent-events:agent-123",
              channelType: "dm", channelName: "third-party-agent-events:agent-123",
              senderType: "third_party_app", senderName: "task44-demo-third-party"),
    ])
    #expect(rows.count == 1)
    #expect(rows[0].target == "dm:@third-party-agent-events:agent-123")
    #expect(rows[0].pendingCount == 2)
    #expect(rows[0].latestSenderType == "third_party_app")
    #expect(rows[0].flags == ["dm"])
    let delta = AgentInboxProjection.formatDelta(rows, totalPendingMessages: 2)
    #expect(!delta.contains("third-party-agent-events"))
    #expect(delta.contains("Third-party app events  pending: 2 messages"))
    #expect(delta.contains("fetch with raft message check"))
    #expect(!delta.contains("agent-event:aaaaaaaa"))
}

@Test func formattingHandlesEmptySnapshotAndDelta() {
    #expect(AgentInboxProjection.formatSnapshot([]) == "Inbox: empty")
    #expect(AgentInboxProjection.formatDelta([]) == "Inbox update: no pending targets")
}

@Test func suppressedCountAttachesToItsTargetRow() {
    let rows = AgentInboxProjection.projectSnapshot(
        [.init(seq: 5, id: "m1", channelId: "c1", channelType: "channel", channelName: "qa")],
        suppressedByTarget: ["#qa": 4]
    )
    #expect(rows.first { $0.target == "#qa" }?.suppressedCount == 4)
}

@Test func allSuppressedTargetStillProducesARow() {
    let rows = AgentInboxProjection.projectSnapshot([], suppressedByTarget: ["#silent": 3])
    #expect(rows.count == 1)
    #expect(rows[0].target == "#silent")
    #expect(rows[0].pendingCount == 0)
    #expect(rows[0].suppressedCount == 3)
}

@Test func omittingTheSiblingArgumentChangesNothing() {
    let messages = [AgentInboxProjectionMessage(seq: 5, id: "m1", channelId: "c1", channelType: "channel", channelName: "qa")]
    #expect(AgentInboxProjection.projectSnapshot(messages) == AgentInboxProjection.projectSnapshot(messages, suppressedByTarget: [:]))
}

@Test func zeroCountAddsNeitherRowNorField() {
    let rows = AgentInboxProjection.projectSnapshot([], suppressedByTarget: ["#none": 0])
    #expect(rows.isEmpty)
}

@Test func invalidSuppressedCountsAreRejectedNotRendered() {
    let message = AgentInboxProjectionMessage(seq: 1, id: "m1", channelId: "c1", channelType: "channel", channelName: "qa")
    for bad in [Double.infinity, 1.5, -3, Double.nan] {
        let rows = AgentInboxProjection.projectSnapshot([message], suppressedByTarget: ["#qa": bad])
        #expect(rows[0].suppressedCount == nil)
    }
}

@Test func invalidSuppressedCountsCannotConjureASuppressedOnlyRow() {
    for bad in [Double.infinity, 1.5, -3, Double.nan] {
        #expect(AgentInboxProjection.projectSnapshot([], suppressedByTarget: ["#ghost": bad]).isEmpty)
    }
}

@Test func aValidPositiveSuppressedCountStillPasses() {
    let rows = AgentInboxProjection.projectSnapshot([], suppressedByTarget: ["#ok": 2])
    #expect(rows[0].suppressedCount == 2)
}

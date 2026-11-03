import Testing
import RaftDaemonClient

@Test func rejectsEveryWeakConclusionBearingDetailKind() {
    for detailKind in ["none", "daemon_activity", "external_activity", "slock_action", "other"] {
        let built = DaemonActivityProducer.build(.init(
            agentId: "agent-1", activityKind: "error", detail: "producer conclusion must not cross the wire",
            detailKind: detailKind, isHeartbeat: false
        ))
        guard case .drop(let drop) = built else { Issue.record("expected drop for \(detailKind)"); continue }
        #expect(drop.reason == "non_fact_activity_detail_kind")
    }
    let missing = DaemonActivityProducer.build(.init(
        agentId: "agent-1", activityKind: "working", detail: "missing fact kind",
        detailKind: nil, isHeartbeat: false
    ))
    guard case .drop(let drop) = missing else { Issue.record("expected drop"); return }
    #expect(drop.reason == "unknown_activity_detail_kind")
}

@Test func factTypedActivityOmitsProducerConclusionsFromEnvelopeAndStatusEntries() {
    let entries = [
        DaemonActivityEntry(kind: "status", detail: "Runtime failed", detailKind: "runtime_error",
                            activity: "working", activityKind: "working"),
    ]
    let built = DaemonActivityProducer.build(.init(
        agentId: "agent-1", activityKind: "working", detail: "Runtime failed",
        detailKind: "runtime_error", entries: entries, isHeartbeat: false
    ))
    guard case .ok(let message) = built else { Issue.record("expected ok"); return }
    #expect(!message.hasActivityField)
    #expect(!message.hasActivityKindField)
    #expect(message.entries == [DaemonActivityEntry(kind: "status", detail: "Runtime failed", detailKind: "runtime_error")])
}

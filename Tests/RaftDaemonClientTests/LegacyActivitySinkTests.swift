import Testing
import RaftDaemonClient

private let producer = ActivityProducerContext(
    present: true, serverId: "server-1", machineId: "machine-1",
    processInstanceId: "proc-1", sessionIdPresent: true, runtime: "claude"
)

private final class Harness: @unchecked Sendable {
    var sent: [ActivityMessage] = []
    var events: [ActivityTraceEvent] = []
    var seq = 0
    var transport: LegacyActivitySink!
    let instanceId: String?

    init(daemonInstanceId: String? = "daemon-1") {
        instanceId = daemonInstanceId
        var sinkRef: LegacyActivitySink?
        transport = LegacyActivitySink(
            sendToServer: { [unowned self] message in self.sent.append(message) },
            nextClientSeq: { [unowned self] in self.seq += 1; return self.seq },
            daemonInstanceId: { daemonInstanceId },
            recordEvent: { [unowned self] name, attrs, status in
                self.events.append(ActivityTraceEvent(name: name, attrs: attrs, status: status))
            },
            now: { 1_000 }
        )
        sinkRef = transport
        _ = sinkRef
    }
}

@Test func stampsNewFactsWithSequenceFactIdObservationTimeAndDaemonGeneration() {
    let harness = Harness()
    let sent = harness.transport.publishFact(
        .init(agentId: "a1", activityKind: "working", detail: "Running command…",
              detailKind: "running_command", entries: [], launchId: "launch-1"),
        producer
    )
    #expect(sent == "running_command")
    #expect(harness.sent == [.init(
        agentId: "a1", detail: "Running command…", detailKind: "running_command",
        entries: [], launchId: "launch-1", daemonInstanceId: "daemon-1", clientSeq: 1,
        producerFactId: "daemon_activity:a1:launch-1:daemon-1:1", observedAtMs: 1_000,
        isHeartbeat: false, probeId: nil
    )])
    let produced = harness.events.first { $0.name == "daemon.agent.activity.produced" }
    #expect(produced?.attrs["client_seq"] == "1")
    #expect(produced?.attrs["producer_fact_id"] == "daemon_activity:a1:launch-1:daemon-1:1")
    #expect(produced?.attrs["is_heartbeat"] == "false")
    #expect(produced?.attrs["server_id"] == "server-1")
    #expect(produced?.attrs["ap_present"] == "true")
    #expect(produced?.attrs["correlation_id"] == "agent:a1:daemonActivity:launch-1:1")
}

@Test func dropsNonFactDetailKindsAndRecordsWhy() {
    let harness = Harness()
    let sent = harness.transport.publishFact(
        .init(agentId: "a1", activityKind: "working", detail: "", detailKind: "other", entries: []),
        producer
    )
    #expect(sent == nil)
    #expect(harness.sent.isEmpty)
    #expect(harness.events.map(\.name) == ["daemon.agent.activity.dropped"])
    #expect(harness.events.map(\.status) == ["error"])
}

@Test func heartbeatsMarkReplayProvenanceAndUseTheLegacyNamespace() {
    let harness = Harness(daemonInstanceId: nil)
    harness.transport.publishHeartbeat(
        .init(agentId: "a1", activityKind: "thinking", detail: "", detailKind: "thinking_started"),
        producer
    )
    let message = harness.sent[0]
    #expect(message.isHeartbeat == true)
    #expect(message.clientSeq == 1)
    #expect(message.producerFactId == "daemon_activity:a1:legacy:1")
    #expect(message.observedAtMs == 1_000)
    #expect(message.daemonInstanceId == nil)
    #expect(harness.events.last?.attrs["is_heartbeat"] == "true")
    #expect(harness.events.last?.attrs["entry_kinds"] == "")
}

@Test func probeRepliesCarryTheProbeIdAndNoObservationTime() {
    let harness = Harness()
    harness.transport.respondToProbe(
        .init(agentId: "a1", activityKind: "offline", detail: "Agent not running",
              detailKind: "runtime_unavailable"),
        "probe-7", ActivityProducerContext(present: false, sessionIdPresent: false)
    )
    let message = harness.sent[0]
    #expect(message.probeId == "probe-7")
    #expect(message.clientSeq == 1)
    #expect(message.isHeartbeat == false)
    #expect(message.observedAtMs == nil)
    #expect(harness.events.last?.attrs["ap_present"] == "false")
}

@Test func rawSendsPassCallerAssignedSequencesThrough() {
    let harness = Harness()
    harness.transport.send(.init(agentId: "a1", activityKind: "working", detail: "",
                                 detailKind: "freshness_hold", clientSeq: nil, isHeartbeat: false))
    #expect(harness.sent[0].clientSeq == nil)
    #expect(harness.sent[0].daemonInstanceId == "daemon-1")
    #expect(harness.sent[0].detailKind == "freshness_hold")
}

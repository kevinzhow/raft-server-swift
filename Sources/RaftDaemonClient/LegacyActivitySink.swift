import Foundation

/// The legacy `agent:activity` transport: stamps sequence, producer fact id,
/// observation time and daemon generation onto new facts, derives heartbeats /
/// probe replies / raw sends with their own shapes, and records whether a frame
/// was produced or dropped. Ported from the upstream daemon sink.
public struct ActivityProducerContext: Sendable, Equatable {
    public var present: Bool
    public var serverId: String?
    public var machineId: String?
    public var processInstanceId: String?
    public var sessionIdPresent: Bool
    public var runtime: String?
    public init(present: Bool, serverId: String? = nil, machineId: String? = nil,
                processInstanceId: String? = nil, sessionIdPresent: Bool, runtime: String? = nil) {
        self.present = present
        self.serverId = serverId
        self.machineId = machineId
        self.processInstanceId = processInstanceId
        self.sessionIdPresent = sessionIdPresent
        self.runtime = runtime
    }
}

public struct ActivityFactInput: Sendable {
    public var agentId: String
    public var activityKind: String
    public var detail: String
    public var detailKind: String?
    public var entries: [DaemonActivityEntry]?
    public var launchId: String?
    public var clientSeq: Int?
    public var isHeartbeat: Bool
    public init(agentId: String, activityKind: String, detail: String, detailKind: String?,
                entries: [DaemonActivityEntry]? = nil, launchId: String? = nil,
                clientSeq: Int? = nil, isHeartbeat: Bool = false) {
        self.agentId = agentId
        self.activityKind = activityKind
        self.detail = detail
        self.detailKind = detailKind
        self.entries = entries
        self.launchId = launchId
        self.clientSeq = clientSeq
        self.isHeartbeat = isHeartbeat
    }
}

public struct ActivityMessage: Sendable, Equatable {
    public var type = "agent:activity"
    public var agentId: String
    public var detail: String
    public var detailKind: String
    public var entries: [DaemonActivityEntry]?
    public var launchId: String?
    public var daemonInstanceId: String?
    public var clientSeq: Int?
    public var producerFactId: String?
    public var observedAtMs: Int?
    public var isHeartbeat: Bool
    public var probeId: String?

    public init(type: String = "agent:activity", agentId: String, detail: String, detailKind: String,
                entries: [DaemonActivityEntry]?, launchId: String?, daemonInstanceId: String?,
                clientSeq: Int?, producerFactId: String?, observedAtMs: Int?,
                isHeartbeat: Bool, probeId: String?) {
        self.type = type
        self.agentId = agentId
        self.detail = detail
        self.detailKind = detailKind
        self.entries = entries
        self.launchId = launchId
        self.daemonInstanceId = daemonInstanceId
        self.clientSeq = clientSeq
        self.producerFactId = producerFactId
        self.observedAtMs = observedAtMs
        self.isHeartbeat = isHeartbeat
        self.probeId = probeId
    }
}

public struct ActivityTraceEvent: Sendable, Equatable {
    public var name: String
    public var attrs: [String: String]
    public var status: String?

    public init(name: String, attrs: [String: String], status: String?) {
        self.name = name
        self.attrs = attrs
        self.status = status
    }
}

public final class LegacyActivitySink: Sendable {
    public typealias Send = @Sendable (ActivityMessage) -> Void
    public typealias RecordEvent = @Sendable (String, [String: String], String?) -> Void

    private let sendToServer: Send
    private let nextClientSeq: @Sendable () -> Int
    private let daemonInstanceId: @Sendable () -> String?
    private let recordEvent: RecordEvent
    private let now: @Sendable () -> Int

    public init(
        sendToServer: @escaping Send,
        nextClientSeq: @escaping @Sendable () -> Int,
        daemonInstanceId: @escaping @Sendable () -> String?,
        recordEvent: @escaping RecordEvent,
        now: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.sendToServer = sendToServer
        self.nextClientSeq = nextClientSeq
        self.daemonInstanceId = daemonInstanceId
        self.recordEvent = recordEvent
        self.now = now
    }

    static func factId(agentId: String, launchId: String?, instance: String?, seq: Int) -> String {
        let namespace = launchId ?? "legacy"
        if let instance, !instance.isEmpty {
            return "daemon_activity:\(agentId):\(namespace):\(instance):\(seq)"
        }
        return "daemon_activity:\(agentId):\(namespace):\(seq)"
    }

    static func correlationId(agentId: String, launchId: String?, seq: Int) -> String {
        "agent:\(agentId):daemonActivity:\(launchId ?? "legacy"):\(seq)"
    }

    static func entryKinds(_ entries: [DaemonActivityEntry]?) -> String {
        (entries ?? []).map(\.kind).joined(separator: ",")
    }

    public func publishFact(_ input: ActivityFactInput, _ producer: ActivityProducerContext) -> String? {
        guard let detailKind = input.detailKind, AgentActivityDetailKinds.isKnown(detailKind) else {
            recordDrop(input, kind: input.detailKind ?? "non_string", reason: "unknown_activity_detail_kind")
            return nil
        }
        if AgentActivityDetailKinds.nonFact.contains(detailKind) {
            recordDrop(input, kind: detailKind, reason: "non_fact_activity_detail_kind")
            return nil
        }
        let seq = nextClientSeq()
        let instance = daemonInstanceId()
        let factId = Self.factId(agentId: input.agentId, launchId: input.launchId, instance: instance, seq: seq)
        let message = ActivityMessage(
            agentId: input.agentId, detail: input.detail, detailKind: detailKind,
            entries: input.entries, launchId: input.launchId, daemonInstanceId: instance,
            clientSeq: seq, producerFactId: factId, observedAtMs: now(), isHeartbeat: false, probeId: nil
        )
        sendToServer(message)
        var attrs: [String: String] = [
            "client_seq": "\(seq)",
            "producer_fact_id": factId,
            "is_heartbeat": "false",
            "ap_present": "\(producer.present)",
            "correlation_id": Self.correlationId(agentId: input.agentId, launchId: input.launchId, seq: seq),
            "entry_kinds": Self.entryKinds(input.entries),
        ]
        if let serverId = producer.serverId { attrs["server_id"] = serverId }
        recordEvent("daemon.agent.activity.produced", attrs, nil)
        return detailKind
    }

    public func publishHeartbeat(_ input: ActivityFactInput, _ producer: ActivityProducerContext) {
        let seq = nextClientSeq()
        let instance = daemonInstanceId()
        let message = ActivityMessage(
            agentId: input.agentId, detail: input.detail, detailKind: input.detailKind ?? "",
            entries: input.entries, launchId: input.launchId, daemonInstanceId: instance,
            clientSeq: seq,
            producerFactId: Self.factId(agentId: input.agentId, launchId: input.launchId, instance: nil, seq: seq),
            observedAtMs: now(), isHeartbeat: true, probeId: nil
        )
        sendToServer(message)
        var attrs: [String: String] = [
            "client_seq": "\(seq)",
            "producer_fact_id": message.producerFactId ?? "",
            "is_heartbeat": "true",
            "ap_present": "\(producer.present)",
            "entry_kinds": Self.entryKinds(input.entries),
        ]
        if let serverId = producer.serverId { attrs["server_id"] = serverId }
        recordEvent("daemon.agent.activity.produced", attrs, nil)
    }

    public func respondToProbe(_ input: ActivityFactInput, _ probeId: String, _ producer: ActivityProducerContext) {
        let seq = nextClientSeq()
        let message = ActivityMessage(
            agentId: input.agentId, detail: input.detail, detailKind: input.detailKind ?? "",
            entries: input.entries, launchId: input.launchId, daemonInstanceId: daemonInstanceId(),
            clientSeq: seq, producerFactId: nil, observedAtMs: nil, isHeartbeat: false, probeId: probeId
        )
        sendToServer(message)
        recordEvent("daemon.agent.activity.produced", [
            "client_seq": "\(seq)", "is_heartbeat": "false",
            "ap_present": "\(producer.present)", "entry_kinds": Self.entryKinds(input.entries),
        ], nil)
    }

    public func send(_ input: ActivityFactInput) {
        let message = ActivityMessage(
            agentId: input.agentId, detail: input.detail, detailKind: input.detailKind ?? "",
            entries: input.entries, launchId: input.launchId, daemonInstanceId: daemonInstanceId(),
            clientSeq: input.clientSeq, producerFactId: nil, observedAtMs: nil,
            isHeartbeat: input.isHeartbeat, probeId: nil
        )
        sendToServer(message)
    }

    private func recordDrop(_ input: ActivityFactInput, kind: String, reason: String) {
        recordEvent("daemon.agent.activity.dropped", [
            "activity": input.activityKind,
            "detail_kind": kind,
            "reason": reason,
            "is_heartbeat": "\(input.isHeartbeat)",
        ], "error")
    }
}

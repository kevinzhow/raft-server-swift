import Foundation

/// Raw daemon ready inventory, independent of Core execution admission. Pending
/// omission is not an empty detected inventory. No runtime whitelist is applied.
public struct MachineRuntimeInventoryReport: Decodable, Sendable {
    public let runtimes: [String]?
    public let runtimeVersions: [String: String]?
    public let runtimeDetection: Detection?
    public let hostname: String?
    public let os: String?
    public let osVariant: String?
    public let deviceClass: String?
    public let daemonVersion: String?
    public let computerVersion: String?

    func event(machine: MachineRecord) -> String {
        var body = OrderedJSONObject()
        body.append("machineId", machine.id)
        body.append("runtimes", .array(machine.runtimes.map(OrderedJSON.string)))
        body.append("runtimeVersions", .object(machine.runtimeVersions.sorted { $0.key < $1.key }.map { .init($0.key, $0.value) }))
        body.append("runtimeDetection", ifPresent: machine.runtimeDetection?.jsonBody)
        body.append("hostname", ifPresent: hostname); body.append("os", ifPresent: os)
        body.append("osVariant", ifPresent: osVariant); body.append("deviceClass", ifPresent: deviceClass)
        body.append("daemonVersion", ifPresent: daemonVersion); body.append("computerVersion", ifPresent: computerVersion)
        return body.json.render()
    }

    public struct Detection: Decodable, Sendable {
        public let status: MachineRuntimeDetectionFact.Status
        public let reason: String?
        public let unfinishedRuntimes: [String]?
        public let durationMs: Double?
    }
}

/// Factual detection metadata. Its timestamp is the server's observation time;
/// duration, when present, remains the daemon's own reported duration.
public struct MachineRuntimeDetectionFact: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case pending, incomplete, complete }
    public let status: Status
    public let reason: String?
    public let unfinishedRuntimes: [String]?
    public let durationMs: Double?
    public let updatedAtMs: Int

    var jsonBody: OrderedJSON {
        var fields = [OrderedJSONField("status", status.rawValue)]
        if status == .incomplete {
            fields.append(.init("unfinishedRuntimes", .array((unfinishedRuntimes ?? []).map(OrderedJSON.string))))
            if let reason { fields.append(.init("reason", reason)) }
        }
        fields.append(.init("updatedAtMs", updatedAtMs))
        return .object(fields)
    }
}

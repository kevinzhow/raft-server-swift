import Foundation

/// Consecutive terminal context-compaction failures of one runtime session,
/// kept on disk per agent so a daemon/computer restart does not reset them.
/// After the threshold, starts refuse to resume that session until it is reset;
/// a new session id, another model, or a successful compaction clears it.
/// Stored in the workspace's hidden `.raft/` directory, ids/counts only.
/// Ported from the upstream daemon ledger.
public final class SessionCompactionFailureLedger {
    public static let sessionNeedsResetThreshold = 3
    static let fileName = "compaction-failures.json"

    struct Record: Equatable {
        var version = 1
        var sessionId: String
        var model: String?
        var count: Int
        var updatedAtMs: Int
    }

    private let agentsDir: String
    private let now: () -> Int

    /// `agentsDir` holds one workspace directory per agent id.
    public init(agentsDir: String, now: @escaping () -> Int = { Int(Date().timeIntervalSince1970 * 1000) }) {
        self.agentsDir = agentsDir
        self.now = now
    }

    private func file(agentId: String) -> String {
        agentsDir + "/" + agentId + "/.raft/" + Self.fileName
    }

    private func read(agentId: String) -> Record? {
        guard let data = FileManager.default.contents(atPath: file(agentId: agentId)),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (object["version"] as? NSNumber)?.intValue == 1,
              let sessionId = object["sessionId"] as? String,
              let count = (object["count"] as? NSNumber)?.intValue
        else { return nil }
        return Record(
            sessionId: sessionId,
            model: object["model"] as? String,
            count: count,
            updatedAtMs: (object["updatedAtMs"] as? NSNumber)?.intValue ?? 0
        )
    }

    /// Counts one terminal compaction failure; returns the consecutive count.
    @discardableResult
    public func recordFailure(agentId: String, sessionId: String, model: String?) -> Int {
        let current = read(agentId: agentId)
        let same = current != nil && current?.sessionId == sessionId && current?.model == model
        let record = Record(
            sessionId: sessionId, model: model,
            count: same ? (current?.count ?? 0) + 1 : 1,
            updatedAtMs: now()
        )
        let path = file(agentId: agentId)
        let manager = FileManager.default
        try? manager.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var object: [String: Any] = [
            "version": 1, "sessionId": sessionId, "count": record.count, "updatedAtMs": record.updatedAtMs,
        ]
        if let model = record.model { object["model"] = model }
        if let data = try? JSONSerialization.data(withJSONObject: object) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        return record.count
    }

    /// A compaction succeeded: the session is healthy again.
    public func clear(agentId: String) {
        try? FileManager.default.removeItem(atPath: file(agentId: agentId))
    }

    /// The consecutive failure count when resuming this exact session/model must
    /// be refused, else nil.
    public func needsReset(agentId: String, sessionId: String, model: String?) -> Int? {
        guard let current = read(agentId: agentId),
              current.sessionId == sessionId,
              current.model == model
        else { return nil }
        return current.count >= Self.sessionNeedsResetThreshold ? current.count : nil
    }
}

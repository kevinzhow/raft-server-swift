import Crypto
import Foundation

/// task #13 — keeping a resumed session's standing prompt current. Several
/// runtimes keep the prompt their session started with and ignore a new one at
/// resume until compaction, so a rule added to the standing prompt never
/// reached an existing session. The daemon records per agent a hash of the
/// prompt each session runs on; a resumed session whose recorded hash differs
/// gets the full current prompt at the front of its first input, marked as
/// replacing the earlier standing instructions. A session with no record gets
/// one written (`baseline_unknown`) without an injection. Ported from the
/// upstream daemon helper.
public enum StandingPromptRefresh {
    /// Config fields whose changes alone never count as a new standing prompt.
    public static let volatileFields = [
        "runtimeContext.daemonVersion",
        "runtimeProfileControl",
    ]

    /// `config` with the volatile fields cleared: this is what is hashed (and injected).
    public static func stableConfig(_ config: [String: Any]) -> [String: Any] {
        var stable = config
        stable["runtimeProfileControl"] = nil
        if let runtimeContext = config["runtimeContext"] as? [String: Any] {
            var context = runtimeContext
            context["daemonVersion"] = nil
            stable["runtimeContext"] = context
        }
        return stable
    }

    public static func hash(prompt: String) -> String {
        let digest = SHA256.hash(data: Data(prompt.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    public struct LedgerRecord: Sendable, Equatable {
        public var version = 1
        public var sessionId: String
        public var promptHash: String
        public var recordedAtMs: Int
        public init(sessionId: String, promptHash: String, recordedAtMs: Int) {
            self.sessionId = sessionId
            self.promptHash = promptHash
            self.recordedAtMs = recordedAtMs
        }
    }

    public enum Plan: Sendable, Equatable {
        case none
        case unchanged
        case baselineUnknown
        case inject(staleForMs: Int)
    }

    public enum Format {
        public static func update(_ standingPrompt: String) -> String {
            [
                "<raft-standing-prompt-update>",
                "Raft updated your standing instructions since this session started. The instructions below replace the earlier standing instructions (system or developer prompt) for the rest of this session; where they differ, follow these.",
                "",
                standingPrompt,
                "</raft-standing-prompt-update>",
                "",
                "",
            ].joined(separator: "\n")
        }
    }

    public static func apply(
        plan: Plan, standingPrompt: String, prompt: String, promptSource: String
    ) -> (prompt: String, promptSource: String) {
        guard case .inject = plan else { return (prompt, promptSource) }
        return (Format.update(standingPrompt) + prompt, promptSource + "_with_standing_prompt_update")
    }

    public static func plan(
        ledger: StandingPromptLedger,
        agentId: String,
        resumeSessionId: String?,
        refreshesOnResume: Bool,
        promptHash: String,
        nowMs: Int
    ) -> Plan {
        guard let resumeSessionId, !refreshesOnResume else { return .none }
        guard let record = ledger.read(agentId: agentId), record.sessionId == resumeSessionId else {
            return .baselineUnknown
        }
        if record.promptHash == promptHash { return .unchanged }
        return .inject(staleForMs: max(0, nowMs - record.recordedAtMs))
    }
}

/// One record per agent, in its workspace's hidden `.raft/`: ids, a hash and a
/// time only.
public final class StandingPromptLedger: @unchecked Sendable {
    private let agentsDir: String
    private let now: @Sendable () -> Int
    private let lock = NSLock()

    public init(agentsDir: String, now: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970 * 1000) }) {
        self.agentsDir = agentsDir
        self.now = now
    }

    func file(_ agentId: String) -> String {
        agentsDir + "/" + agentId + "/.raft/standing-prompt.json"
    }

    public func read(agentId: String) -> StandingPromptRefresh.LedgerRecord? {
        guard let data = FileManager.default.contents(atPath: file(agentId)),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (object["version"] as? NSNumber)?.intValue == 1,
              let sessionId = object["sessionId"] as? String,
              let promptHash = object["promptHash"] as? String
        else { return nil }
        return .init(
            sessionId: sessionId, promptHash: promptHash,
            recordedAtMs: (object["recordedAtMs"] as? NSNumber)?.intValue ?? 0
        )
    }

    public func write(agentId: String, sessionId: String, promptHash: String) throws {
        lock.lock(); defer { lock.unlock() }
        let file = file(agentId)
        try FileManager.default.createDirectory(
            atPath: (file as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        let record = StandingPromptRefresh.LedgerRecord(
            sessionId: sessionId, promptHash: promptHash, recordedAtMs: now()
        )
        let object: [String: Any] = [
            "version": 1, "sessionId": record.sessionId,
            "promptHash": record.promptHash, "recordedAtMs": record.recordedAtMs,
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: URL(fileURLWithPath: file), options: .atomic)
    }
}

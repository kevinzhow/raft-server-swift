import Foundation

/// RFC 070 wake-session recycling: cold gaps plus large contexts retire the
/// prior session instead of resuming its expired prompt cache. Ported from the
/// upstream daemon module (the constructed panel and startup-memory extras are
/// separate slices).
public struct WakeRecycleConfig: Sendable, Equatable {
    public var enabled: Bool
    public var minContextTokens: Int
    public var minColdGapMs: Int
    public static let defaultMinContextTokens = 128_000
    public static let defaultMinColdGapMs = 3_600_000

    public init(enabled: Bool, minContextTokens: Int, minColdGapMs: Int) {
        self.enabled = enabled
        self.minContextTokens = minContextTokens
        self.minColdGapMs = minColdGapMs
    }
}

public struct SessionResumeFacts: Sendable, Equatable {
    public var transcriptPath: String?
    public var lastActivityAtMs: Int?
    public var lastContextTokens: Int?
    public init(transcriptPath: String?, lastActivityAtMs: Int?, lastContextTokens: Int?) {
        self.transcriptPath = transcriptPath
        self.lastActivityAtMs = lastActivityAtMs
        self.lastContextTokens = lastContextTokens
    }
}

public enum WakeRecyclePlan: Sendable, Equatable {
    case resume(reason: String)
    case recycle(priorSessionId: String, idleMs: Int, priorContextTokens: Int, briefing: String)

    public var action: String {
        switch self {
        case .resume: "resume"
        case .recycle: "recycle"
        }
    }
    public var reason: String {
        switch self {
        case .resume(let reason): reason
        case .recycle: "cold_gap_large_context"
        }
    }
}

public enum WakeSessionRecycle {
    public static let enabledRuntimes: Set<String> = ["claude", "codex", "pi", "builtin", "grok", "kimi-sdk"]
    public static let coldIdleSweepMs = 600_000
    static let transcriptTailBytes = 512 * 1024
    static let workspaceProjectDir = "-workspace-agent"

    // MARK: config

    static func parseBooleanFlag(_ value: String?) -> Bool? {
        guard let value else { return nil }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "on": return true
        case "0", "false", "off", "": return false
        default: return nil
        }
    }

    static func parsePositiveInteger(_ value: String?) -> Int? {
        guard let value, let parsed = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)), parsed > 0 else { return nil }
        return parsed
    }

    /// Server flag only; per-agent env beats the daemon process env, and
    /// `RAFT_WAKE_RECYCLE=0` stays a local kill switch that no env can flip on.
    public static func resolveConfig(
        serverEnabled: Bool?,
        agentEnvVars: [String: String]?,
        processEnv: [String: String] = [:]
    ) -> WakeRecycleConfig {
        func pick(_ key: String) -> String? { agentEnvVars?[key] ?? processEnv[key] }
        return WakeRecycleConfig(
            enabled: serverEnabled == true && parseBooleanFlag(pick("RAFT_WAKE_RECYCLE")) != false,
            minContextTokens: parsePositiveInteger(pick("RAFT_WAKE_RECYCLE_MIN_CONTEXT_TOKENS")) ?? WakeRecycleConfig.defaultMinContextTokens,
            minColdGapMs: parsePositiveInteger(pick("RAFT_WAKE_RECYCLE_MIN_COLD_GAP_MS")) ?? WakeRecycleConfig.defaultMinColdGapMs
        )
    }

    // MARK: transcript facts

    static func transcriptPath(sessionId: String, homeDir: String?) -> String {
        let home = homeDir ?? NSHomeDirectory()
        return home + "/.claude/projects/\(workspaceProjectDir)/\(sessionId).jsonl"
    }

    static func contextTokens(fromUsage usage: Any?) -> Int? {
        guard let usage = usage as? [String: Any] else { return nil }
        func finite(_ value: Any?) -> Int {
            guard let number = value as? NSNumber else { return 0 }
            return number.doubleValue.isFinite ? number.intValue : 0
        }
        return finite(usage["input_tokens"]) + finite(usage["cache_read_input_tokens"])
            + finite(usage["cache_creation_input_tokens"])
    }

    /// Tail scan of the Claude transcript: last record timestamp is the last
    /// activity, and the last assistant usage record carries the context size.
    public static func readClaudeSessionResumeFacts(sessionId: String, homeDir: String? = nil) -> SessionResumeFacts {
        let path = transcriptPath(sessionId: sessionId, homeDir: homeDir)
        guard let data = FileManager.default.contents(atPath: path) else {
            return SessionResumeFacts(transcriptPath: nil, lastActivityAtMs: nil, lastContextTokens: nil)
        }
        let tail = data.count > transcriptTailBytes ? data.suffix(transcriptTailBytes) : data
        let text = String(decoding: tail, as: UTF8.self)
        var lastActivity: Int?
        var lastTokens: Int?
        for line in text.split(separator: "\n") {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            if let timestamp = object["timestamp"] as? String, let ms = parseISO(timestamp) {
                lastActivity = ms
            }
            if object["type"] as? String == "assistant",
               let message = object["message"] as? [String: Any],
               let tokens = contextTokens(fromUsage: message["usage"]) {
                lastTokens = tokens
            }
        }
        return SessionResumeFacts(transcriptPath: path, lastActivityAtMs: lastActivity, lastContextTokens: lastTokens)
    }

    public static func parseISO(_ value: String) -> Int? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return Int(date.timeIntervalSince1970 * 1000) }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value).map { Int($0.timeIntervalSince1970 * 1000) }
    }

    public static func readRuntimeSessionResumeFacts(runtime: String, sessionId: String, homeDir: String? = nil) -> SessionResumeFacts {
        runtime == "claude"
            ? readClaudeSessionResumeFacts(sessionId: sessionId, homeDir: homeDir)
            : SessionResumeFacts(transcriptPath: nil, lastActivityAtMs: nil, lastContextTokens: nil)
    }

    // MARK: decision

    public struct DecisionInput: Sendable {
        public var config: WakeRecycleConfig
        public var runtime: String?
        public var sessionId: String?
        public var hasResumePrompt: Bool
        public var hasRuntimeProfileControl: Bool
        public var facts: SessionResumeFacts
        public var nowMs: Int
        public init(config: WakeRecycleConfig, runtime: String?, sessionId: String?, hasResumePrompt: Bool,
                    hasRuntimeProfileControl: Bool, facts: SessionResumeFacts, nowMs: Int) {
            self.config = config
            self.runtime = runtime
            self.sessionId = sessionId
            self.hasResumePrompt = hasResumePrompt
            self.hasRuntimeProfileControl = hasRuntimeProfileControl
            self.facts = facts
            self.nowMs = nowMs
        }
    }

    public static func runtimeProfileControlBlocksRecycle(kind: String?) -> Bool {
        guard let kind else { return false }
        return kind != "daemon_release_notice"
    }

    /// Every failed gate resolves to a plain resume with its own reason;
    /// unknown facts always mean resume.
    public static func decide(_ input: DecisionInput) -> WakeRecyclePlan {
        guard input.config.enabled else { return .resume(reason: "disabled") }
        guard enabledRuntimes.contains(input.runtime ?? "claude") else { return .resume(reason: "unsupported_runtime") }
        guard let sessionId = input.sessionId, !sessionId.isEmpty else { return .resume(reason: "no_prior_session") }
        guard !input.hasResumePrompt else { return .resume(reason: "explicit_resume_prompt") }
        guard !input.hasRuntimeProfileControl else { return .resume(reason: "runtime_profile_control") }
        guard let lastActivity = input.facts.lastActivityAtMs, let context = input.facts.lastContextTokens else {
            return .resume(reason: "session_facts_unavailable")
        }
        let idleMs = input.nowMs - lastActivity
        guard idleMs > input.config.minColdGapMs else { return .resume(reason: "cache_possibly_warm") }
        guard context > input.config.minContextTokens else { return .resume(reason: "context_below_threshold") }
        return .recycle(priorSessionId: sessionId, idleMs: idleMs, priorContextTokens: context, briefing: "")
    }

    /// The recycled wake carries no announcement and no instructions.
    public static func buildRecycleBriefing(idleMs: Int, priorContextTokens: Int) -> String { "" }

    // MARK: cold-idle sweep

    public struct ColdIdleRuntimeView: Sendable {
        public var agentId: String
        public var runtime: String?
        public var sessionId: String?
        public var constructedWakeContext: Bool?
        public var envVars: [String: String]?
        public var idle: Bool
        public var lastEventAtMs: Int
        public var liveSessionId: String?
        public init(agentId: String, runtime: String?, sessionId: String?, constructedWakeContext: Bool?,
                    envVars: [String: String]?, idle: Bool, lastEventAtMs: Int, liveSessionId: String?) {
            self.agentId = agentId
            self.runtime = runtime
            self.sessionId = sessionId
            self.constructedWakeContext = constructedWakeContext
            self.envVars = envVars
            self.idle = idle
            self.lastEventAtMs = lastEventAtMs
            self.liveSessionId = liveSessionId
        }
    }

    public struct ColdIdleRecycleStop: Sendable, Equatable {
        public var agentId: String
        public var sessionId: String
        public var idleMs: Int
        public var priorContextTokens: Int
    }

    public static func selectColdIdleRecycleStops(
        _ views: [ColdIdleRuntimeView],
        nowMs: Int,
        homeDir: String? = nil,
        processEnv: [String: String] = [:],
        onSkip: ((String, String) -> Void)? = nil
    ) -> [ColdIdleRecycleStop] {
        var stops: [ColdIdleRecycleStop] = []
        for view in views {
            let config = resolveConfig(serverEnabled: view.constructedWakeContext, agentEnvVars: view.envVars, processEnv: processEnv)
            func skip(_ reason: String) { onSkip?(view.agentId, reason) }
            guard config.enabled else { skip("disabled"); continue }
            guard view.idle else { skip("not_idle"); continue }
            guard enabledRuntimes.contains(view.runtime ?? "claude") else { skip("unsupported_runtime"); continue }
            guard let sessionId = view.liveSessionId ?? view.sessionId else { skip("no_session"); continue }
            guard nowMs - view.lastEventAtMs > config.minColdGapMs else { skip("recent_event"); continue }
            let facts = readRuntimeSessionResumeFacts(runtime: view.runtime ?? "claude", sessionId: sessionId, homeDir: homeDir)
            guard let lastActivity = facts.lastActivityAtMs, let context = facts.lastContextTokens else {
                skip("session_facts_unavailable"); continue
            }
            let sidecar = facts.transcriptPath.flatMap { latestMtimeUnder(String($0.dropLast(".jsonl".count))) }
            let lastActive = max(lastActivity, max(view.lastEventAtMs, sidecar ?? 0))
            guard nowMs - lastActive > config.minColdGapMs else { skip("recent_activity"); continue }
            guard context > config.minContextTokens else { skip("context_below_threshold"); continue }
            guard let transcriptPath = facts.transcriptPath else { skip("no_transcript"); continue }
            guard let outstanding = transcriptOutstandingBackgroundTasks(transcriptPath) else {
                skip("background_tasks_unknown"); continue
            }
            guard outstanding == 0 else { skip("background_tasks_outstanding"); continue }
            stops.append(.init(agentId: view.agentId, sessionId: sessionId, idleMs: nowMs - lastActive, priorContextTokens: context))
        }
        return stops
    }

    static func latestMtimeUnder(_ dir: String, depth: Int = 0) -> Int? {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: dir, isDirectory: &isDirectory) else { return nil }
        var latest = (try? manager.attributesOfItem(atPath: dir))?[.modificationDate] as? Date
        if isDirectory.boolValue, depth < 2, let entries = try? manager.contentsOfDirectory(atPath: dir) {
            for entry in entries {
                if let nested = latestMtimeUnder(dir + "/" + entry, depth: depth + 1) {
                    let date = Date(timeIntervalSince1970: Double(nested) / 1000)
                    if latest == nil || date > latest! { latest = date }
                }
            }
        }
        return latest.map { Int($0.timeIntervalSince1970 * 1000) }
    }

    static let createPatterns = [
        #"Monitor started \(task ([a-z0-9]+)"#,
        #"background with ID: ([a-z0-9]+)"#,
        #"moved to the background \(ID: ([a-z0-9]+)\)"#,
    ]
    static let terminalPatterns = [
        #"<task-id>([a-z0-9]+)</task-id>[\s\S]{0,400}?<status>(?:completed|failed|stopped|killed)</status>"#,
        #"Successfully stopped task: ([a-z0-9]+)"#,
    ]

    /// Conservative sweep gate: any background marker ever seen disqualifies a
    /// session unless a later terminal marker cleared it. Nil means unknown.
    public static func transcriptOutstandingBackgroundTasks(_ transcriptPath: String) -> Int? {
        guard let data = FileManager.default.contents(atPath: transcriptPath),
              let text = String(data: data, encoding: .utf8) else { return nil }
        var live: Set<String> = []
        for pattern in createPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    if let range = Range(match.range(at: 1), in: text) { live.insert(String(text[range])) }
                }
            }
        }
        for pattern in terminalPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) {
                for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    if let range = Range(match.range(at: 1), in: text) { live.remove(String(text[range])) }
                }
            }
        }
        return live.count
    }

    // MARK: plan

    public static func plan(
        config: WakeRecycleConfig,
        runtime: String?,
        sessionId: String?,
        hasResumePrompt: Bool,
        runtimeProfileControlKind: String?,
        nowMs: Int,
        homeDir: String? = nil,
        processEnv: [String: String] = [:]
    ) -> WakeRecyclePlan {
        guard config.enabled, let sessionId, !sessionId.isEmpty, enabledRuntimes.contains(runtime ?? "claude") else {
            return decide(.init(
                config: config, runtime: runtime, sessionId: sessionId,
                hasResumePrompt: hasResumePrompt,
                hasRuntimeProfileControl: runtimeProfileControlBlocksRecycle(kind: runtimeProfileControlKind),
                facts: .init(transcriptPath: nil, lastActivityAtMs: nil, lastContextTokens: nil), nowMs: nowMs
            ))
        }
        let facts = readRuntimeSessionResumeFacts(runtime: runtime ?? "claude", sessionId: sessionId, homeDir: homeDir)
        return decide(.init(
            config: config, runtime: runtime, sessionId: sessionId,
            hasResumePrompt: hasResumePrompt,
            hasRuntimeProfileControl: runtimeProfileControlBlocksRecycle(kind: runtimeProfileControlKind),
            facts: facts, nowMs: nowMs
        ))
    }
}

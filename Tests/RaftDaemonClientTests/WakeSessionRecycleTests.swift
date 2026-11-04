import Foundation
import Testing
import RaftDaemonClient

private let hourMs = 3_600_000

private func enabledConfig(_ minContext: Int = 128_000, _ minGap: Int = hourMs) -> WakeRecycleConfig {
    .init(enabled: true, minContextTokens: minContext, minColdGapMs: minGap)
}

private func facts(_ lastActivity: Int? = 0, _ tokens: Int? = 500_000, path: String? = "/tmp/x.jsonl") -> SessionResumeFacts {
    .init(transcriptPath: path, lastActivityAtMs: lastActivity, lastContextTokens: tokens)
}

private func decision(_ overrides: (inout WakeSessionRecycle.DecisionInput) -> Void = { _ in }) -> WakeRecyclePlan {
    var input = WakeSessionRecycle.DecisionInput(
        config: enabledConfig(), runtime: "claude", sessionId: "session-1",
        hasResumePrompt: false, hasRuntimeProfileControl: false, facts: facts(), nowMs: 2 * hourMs
    )
    overrides(&input)
    return WakeSessionRecycle.decide(input)
}

private func tempHome() -> String {
    let home = NSTemporaryDirectory() + "wake-recycle-\(UUID().uuidString)"
    let project = home + "/.claude/projects/-workspace-agent"
    try? FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
    return home
}

private func projectDir(_ home: String) -> String {
    home + "/.claude/projects/-workspace-agent"
}

private func writeTranscript(_ home: String, _ sessionId: String, lines: [String]) {
    let path = projectDir(home) + "/\(sessionId).jsonl"
    try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
}

@Test func recyclingRunsOnlyWithTheServerFlag() {
    #expect(WakeSessionRecycle.resolveConfig(serverEnabled: nil, agentEnvVars: nil).enabled == false)
    #expect(WakeSessionRecycle.resolveConfig(serverEnabled: false, agentEnvVars: nil).enabled == false)
    #expect(WakeSessionRecycle.resolveConfig(serverEnabled: false, agentEnvVars: ["RAFT_WAKE_RECYCLE": "1"], processEnv: ["RAFT_WAKE_RECYCLE": "1"]).enabled == false)
    let config = WakeSessionRecycle.resolveConfig(serverEnabled: true, agentEnvVars: nil)
    #expect(config.enabled)
    #expect(!WakeSessionRecycle.resolveConfig(serverEnabled: true, agentEnvVars: nil, processEnv: ["RAFT_WAKE_RECYCLE": "0"]).enabled)
    #expect(!WakeSessionRecycle.resolveConfig(serverEnabled: true, agentEnvVars: ["RAFT_WAKE_RECYCLE": "0"]).enabled)
    #expect(config.minContextTokens == 128_000)
    #expect(config.minColdGapMs == hourMs)
}

@Test func perAgentEnvVarsOverrideDaemonEnv() {
    let config = WakeSessionRecycle.resolveConfig(
        serverEnabled: true,
        agentEnvVars: ["RAFT_WAKE_RECYCLE": "1", "RAFT_WAKE_RECYCLE_MIN_CONTEXT_TOKENS": "96000"],
        processEnv: ["RAFT_WAKE_RECYCLE": "0", "RAFT_WAKE_RECYCLE_MIN_COLD_GAP_MS": "7200000"]
    )
    #expect(config.enabled)
    #expect(config.minContextTokens == 96_000)
    #expect(config.minColdGapMs == 7_200_000)
}

@Test func coldGapWithLargeContextRecycles() {
    let plan = decision()
    guard case .recycle(let priorSessionId, let idleMs, let tokens, let briefing) = plan else {
        Issue.record("expected recycle, got \(plan)")
        return
    }
    #expect(priorSessionId == "session-1")
    #expect(idleMs == 2 * hourMs)
    #expect(tokens == 500_000)
    #expect(briefing.isEmpty)
}

@Test func everyFailedGateResumesWithItsOwnReason() {
    let cases: [(String, (inout WakeSessionRecycle.DecisionInput) -> Void)] = [
        ("disabled", { $0.config.enabled = false }),
        ("unsupported_runtime", { $0.runtime = "cursor" }),
        ("no_prior_session", { $0.sessionId = nil }),
        ("explicit_resume_prompt", { $0.hasResumePrompt = true }),
        ("runtime_profile_control", { $0.hasRuntimeProfileControl = true }),
        ("session_facts_unavailable", { $0.facts = facts(nil, 500_000) }),
        ("session_facts_unavailable", { $0.facts = facts(0, nil) }),
        ("cache_possibly_warm", { $0.nowMs = hourMs }),
        ("context_below_threshold", { $0.facts = facts(0, 128_000) }),
    ]
    for (reason, mutate) in cases {
        let plan = decision(mutate)
        #expect(plan.action == "resume", "\(reason)")
        #expect(plan.reason == reason)
    }
    let codexUnknown = decision { $0.runtime = "codex"; $0.facts = facts(0, nil) }
    #expect(codexUnknown.reason == "session_facts_unavailable")
}

@Test func briefingIsEmpty() {
    let briefing = WakeSessionRecycle.buildRecycleBriefing(idleMs: 5 * hourMs, priorContextTokens: 480_000)
    #expect(briefing.isEmpty)
}

@Test func transcriptTailYieldsActivityAndContextSize() {
    let home = tempHome()
    let sessionId = "11111111-2222-3333-4444-555555555555"
    writeTranscript(home, sessionId, lines: [
        #"{"type":"user","timestamp":"2026-08-30T00:00:00.000Z","message":{"content":"hi"}}"#,
        #"{"type":"assistant","timestamp":"2026-08-30T00:00:10.000Z","message":{"usage":{"input_tokens":12,"cache_read_input_tokens":400000,"cache_creation_input_tokens":2000}}}"#,
        #"{"type":"user","timestamp":"2026-08-30T01:00:00.000Z","message":{"content":"tool result"}}"#,
    ])
    let result = WakeSessionRecycle.readClaudeSessionResumeFacts(sessionId: sessionId, homeDir: home)
    #expect(result.lastActivityAtMs == WakeSessionRecycle.parseISO("2026-08-30T01:00:00.000Z") ?? -1)
    #expect(result.lastContextTokens == 402_012)
}

@Test func missingTranscriptYieldsUnknownFacts() {
    let home = tempHome()
    let result = WakeSessionRecycle.readClaudeSessionResumeFacts(sessionId: "99999999-0000-0000-0000-000000000000", homeDir: home)
    #expect(result.transcriptPath == nil)
    #expect(result.lastActivityAtMs == nil)
    #expect(result.lastContextTokens == nil)
}

@Test func coldIdleSweepSelectsOnlyEnabledIdleColdRuntimes() {
    let home = tempHome()
    let nowMs = Int(Date().timeIntervalSince1970 * 1000)
    let coldSession = "cccccccc-1111-2222-3333-444444444444"
    writeTranscript(home, coldSession, lines: [
        #"{"type":"assistant","timestamp":"\#(iso(nowMs - 3 * hourMs))","message":{"usage":{"input_tokens":5,"cache_read_input_tokens":400000,"cache_creation_input_tokens":0}}}"#
    ])
    func view(_ agentId: String, env: [String: String] = ["RAFT_WAKE_RECYCLE": "1"], runtime: String = "claude",
              idle: Bool = true, lastEvent: Int? = nil, live: String? = coldSession) -> WakeSessionRecycle.ColdIdleRuntimeView {
        .init(agentId: agentId, runtime: runtime, sessionId: nil, constructedWakeContext: true,
              envVars: env, idle: idle, lastEventAtMs: lastEvent ?? (nowMs - 3 * hourMs), liveSessionId: live)
    }
    var skipped: [String] = []
    let stops = WakeSessionRecycle.selectColdIdleRecycleStops([
        view("agent-cold"),
        view("agent-busy", idle: false),
        view("agent-warm-memory", lastEvent: nowMs - 60_000),
        view("agent-disabled", env: ["RAFT_WAKE_RECYCLE": "0"]),
        view("agent-codex", runtime: "codex"),
        view("agent-no-session", live: nil),
        view("agent-no-transcript", live: "dddddddd-1111-2222-3333-444444444444"),
    ], nowMs: nowMs, homeDir: home, onSkip: { skipped.append("\($0):\($1)") })
    #expect(stops.map(\.agentId) == ["agent-cold"])
    #expect(skipped == [
        "agent-busy:not_idle",
        "agent-warm-memory:recent_event",
        "agent-disabled:disabled",
        "agent-codex:session_facts_unavailable",
        "agent-no-session:no_session",
        "agent-no-transcript:session_facts_unavailable",
    ])
    #expect(stops.first?.sessionId == coldSession)
    #expect(stops.first?.priorContextTokens == 400_005)
}

@Test func coldIdleSweepSkipsOutstandingBackgroundTasks() {
    let home = tempHome()
    let nowMs = Int(Date().timeIntervalSince1970 * 1000)
    let cold = #"{"type":"assistant","timestamp":"\#(iso(nowMs - 3 * hourMs))","message":{"usage":{"input_tokens":5,"cache_read_input_tokens":400000,"cache_creation_input_tokens":0}}}"#
    let created = #"{"type":"user","timestamp":"\#(iso(nowMs - 3 * hourMs))","message":{"content":[{"type":"tool_result","tool_use_id":"t","content":"Monitor started (task babc123x, timeout 60000ms). You will be notified"}]}}"#
    let resolved = #"{"type":"user","timestamp":"\#(iso(nowMs - 3 * hourMs))","message":{"content":"<task-notification><task-id>babc123x</task-id><status>completed</status></task-notification>"}}"#
    let armed = "ffffffff-1111-2222-3333-444444444444"
    let cleared = "ffffffff-5555-6666-7777-888888888888"
    writeTranscript(home, armed, lines: [cold, created])
    writeTranscript(home, cleared, lines: [cold, created, resolved])
    func view(_ agentId: String, _ session: String) -> WakeSessionRecycle.ColdIdleRuntimeView {
        .init(agentId: agentId, runtime: "claude", sessionId: nil, constructedWakeContext: true,
              envVars: ["RAFT_WAKE_RECYCLE": "1"], idle: true, lastEventAtMs: nowMs - 3 * hourMs, liveSessionId: session)
    }
    var skipped: [String] = []
    let stops = WakeSessionRecycle.selectColdIdleRecycleStops(
        [view("agent-armed", armed), view("agent-cleared", cleared)],
        nowMs: nowMs, homeDir: home, onSkip: { skipped.append("\($0):\($1)") }
    )
    #expect(stops.map(\.agentId) == ["agent-cleared"])
    #expect(skipped == ["agent-armed:background_tasks_outstanding"])
}

@Test func coldIdleSweepSparesActiveSubagentSidecar() {
    let home = tempHome()
    let nowMs = Int(Date().timeIntervalSince1970 * 1000)
    let sessionId = "eeeeeeee-1111-2222-3333-444444444444"
    writeTranscript(home, sessionId, lines: [
        #"{"type":"assistant","timestamp":"\#(iso(nowMs - 3 * hourMs))","message":{"usage":{"input_tokens":5,"cache_read_input_tokens":400000,"cache_creation_input_tokens":0}}}"#
    ])
    let sidecar = projectDir(home) + "/\(sessionId)/subagents"
    try? FileManager.default.createDirectory(atPath: sidecar, withIntermediateDirectories: true)
    try? "{}\n".write(toFile: sidecar + "/agent-live.jsonl", atomically: true, encoding: .utf8)
    let view = WakeSessionRecycle.ColdIdleRuntimeView(
        agentId: "agent-with-subagent", runtime: "claude", sessionId: nil, constructedWakeContext: true,
        envVars: ["RAFT_WAKE_RECYCLE": "1"], idle: true, lastEventAtMs: nowMs - 3 * hourMs, liveSessionId: sessionId
    )
    let stops = WakeSessionRecycle.selectColdIdleRecycleStops([view], nowMs: nowMs, homeDir: home)
    #expect(stops.isEmpty)
}

@Test func coldIdleSweepTrustsTheFreshestClock() {
    let home = tempHome()
    let nowMs = Int(Date().timeIntervalSince1970 * 1000)
    let sessionId = "dddddddd-1111-2222-3333-444444444444"
    writeTranscript(home, sessionId, lines: [
        #"{"type":"assistant","timestamp":"\#(iso(nowMs - 30_000))","message":{"usage":{"input_tokens":5,"cache_read_input_tokens":400000,"cache_creation_input_tokens":0}}}"#
    ])
    let view = WakeSessionRecycle.ColdIdleRuntimeView(
        agentId: "agent-x", runtime: "claude", sessionId: nil, constructedWakeContext: true,
        envVars: ["RAFT_WAKE_RECYCLE": "1"], idle: true, lastEventAtMs: nowMs - 3 * hourMs, liveSessionId: sessionId
    )
    #expect(WakeSessionRecycle.selectColdIdleRecycleStops([view], nowMs: nowMs, homeDir: home).isEmpty)
}

@Test func planRecyclesEndToEndFromARealTranscript() {
    let home = tempHome()
    let sessionId = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    let lastTurn = Int(Date().timeIntervalSince1970 * 1000) - 3 * hourMs
    writeTranscript(home, sessionId, lines: [
        #"{"type":"assistant","timestamp":"\#(iso(lastTurn))","message":{"usage":{"input_tokens":5,"cache_read_input_tokens":600000,"cache_creation_input_tokens":1500}}}"#
    ])
    let plan = WakeSessionRecycle.plan(
        config: enabledConfig(), runtime: "claude", sessionId: sessionId,
        hasResumePrompt: false, runtimeProfileControlKind: nil,
        nowMs: Int(Date().timeIntervalSince1970 * 1000), homeDir: home
    )
    guard case .recycle(let prior, _, let tokens, _) = plan else {
        Issue.record("expected recycle, got \(plan)")
        return
    }
    #expect(prior == sessionId)
    #expect(tokens == 601_505)
    let disabled = WakeSessionRecycle.plan(
        config: WakeSessionRecycle.resolveConfig(serverEnabled: true, agentEnvVars: ["RAFT_WAKE_RECYCLE": "0"]),
        runtime: "claude", sessionId: sessionId, hasResumePrompt: false,
        runtimeProfileControlKind: nil, nowMs: Int(Date().timeIntervalSince1970 * 1000), homeDir: home
    )
    #expect(disabled.action == "resume")
}

private func iso(_ ms: Int) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
}

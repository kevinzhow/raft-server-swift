import Foundation
import Testing
import RaftDaemonClient

private func tempDir() -> String {
    NSTemporaryDirectory() + "standing-prompt-\(UUID().uuidString)"
}

private func config(description: String = "reviews code", daemonVersion: String = "1.0.46") -> [String: Any] {
    [
        "name": "agent", "displayName": "Agent", "description": description,
        "runtime": "codex", "model": "gpt-5", "sessionId": NSNull(),
        "serverUrl": "http://localhost", "authToken": "x",
        "runtimeContext": [
            "agentId": "a1", "serverId": "s1", "machineName": "m",
            "machineId": "mid", "daemonVersion": daemonVersion, "workspacePath": "/w",
        ],
    ]
}

private func hashOf(_ value: [String: Any]) -> String {
    StandingPromptRefresh.hash(description: nil, value)
}

private extension StandingPromptRefresh {
    static func hash(description: String?, _ value: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data()
        return hash(prompt: String(decoding: data, as: UTF8.self))
    }
}

@Test func volatileFieldsArePinned() {
    #expect(StandingPromptRefresh.volatileFields == ["runtimeContext.daemonVersion", "runtimeProfileControl"])
}

@Test func theHashIgnoresTheDaemonVersionAndReleaseNotice() {
    let base = hashOf(StandingPromptRefresh.stableConfig(config()))
    let newer = hashOf(StandingPromptRefresh.stableConfig(config(daemonVersion: "1.0.47")))
    #expect(newer == base, "a release alone is not a new prompt")

    var withNotice = config()
    withNotice["runtimeProfileControl"] = ["kind": "daemon_release_notice", "key": "k", "message": "Daemon v1.0.47 released"]
    #expect(hashOf(StandingPromptRefresh.stableConfig(withNotice)) == base, "nor is its notice")
    #expect(hashOf(StandingPromptRefresh.stableConfig(config(description: "reviews code and docs"))) != base, "a real change is")
}

@Test func planCoversFreshSelfRefreshingAndResumedSessions() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let ledger = StandingPromptLedger(agentsDir: dir, now: { 5_000 })
    func plan(_ resume: String?, _ hash: String, refreshes: Bool = false) -> StandingPromptRefresh.Plan {
        StandingPromptRefresh.plan(
            ledger: ledger, agentId: "a1", resumeSessionId: resume,
            refreshesOnResume: refreshes, promptHash: hash, nowMs: 9_000
        )
    }
    #expect(plan(nil, "h1") == .none)
    #expect(plan("s1", "h1", refreshes: true) == .none)
    #expect(plan("s1", "h1") == .baselineUnknown, "no record yet: no injection")
    try ledger.write(agentId: "a1", sessionId: "s1", promptHash: "h1")
    #expect(plan("s1", "h1") == .unchanged)
    #expect(plan("s1", "h2") == .inject(staleForMs: 4_000))
    #expect(plan("s2", "h2") == .baselineUnknown, "a record of another session says nothing about this one")

    let stored = try #require(
        try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: dir + "/a1/.raft/standing-prompt.json"))) as? [String: Any]
    )
    #expect(Set(stored.keys) == ["promptHash", "recordedAtMs", "sessionId", "version"])
}

@Test func anInjectionPutsTheFullCurrentPromptFirst() {
    let input = "New message received: hello"
    #expect(StandingPromptRefresh.apply(plan: .unchanged, standingPrompt: "PROMPT", prompt: input, promptSource: "wake").prompt == input)
    let applied = StandingPromptRefresh.apply(
        plan: .inject(staleForMs: 1), standingPrompt: "PROMPT V2", prompt: input, promptSource: "wake"
    )
    #expect(applied.promptSource == "wake_with_standing_prompt_update")
    #expect(applied.prompt.hasPrefix("<raft-standing-prompt-update>\n"))
    #expect(applied.prompt.contains("replace the earlier standing instructions"))
    #expect(applied.prompt.hasSuffix("PROMPT V2\n</raft-standing-prompt-update>\n\nNew message received: hello"))
}

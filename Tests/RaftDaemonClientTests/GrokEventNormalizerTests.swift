import Foundation
import RaftDaemonClient
import Testing

private func notification(_ sessionId: String, _ update: [String: Any]) -> [String: Any] {
    ["sessionId": sessionId, "update": update]
}

@Test func grokNormalizerSurfacesTextAndThoughtChunksForTheActiveSession() {
    let normalizer = GrokEventNormalizer()
    normalizer.adoptSession("session-1")
    #expect(normalizer.normalizeNotification(params: notification("session-1", [
        "sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "answer"],
    ])) == [.text(text: "answer", generation: nil, state: nil)])
    #expect(normalizer.normalizeNotification(params: notification("session-1", [
        "sessionUpdate": "agent_thought_chunk", "content": ["type": "text", "text": "reasoning"],
    ])) == [.thinking(text: "reasoning", generation: nil, state: nil)])
    #expect(normalizer.normalizeNotification(params: notification("other-session", [
        "sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "wrong session"],
    ])).isEmpty)
}

@Test func grokNormalizerJoinsToolDeltasAndEmitsEachCallAndOutputOnce() {
    let normalizer = GrokEventNormalizer()
    normalizer.adoptSession("session-1")
    _ = normalizer.beginPrompt()
    let firstDelta = normalizer.normalizeNotification(params: notification("session-1", [
        "sessionUpdate": "tool_call_delta_chunk", "tool_call_id": "tool-1", "tool_index": 0, "name": "shell",
    ]))
    guard case .internalProgress = firstDelta[0] else { Issue.record("expected progress"); return }
    let secondDelta = normalizer.normalizeNotification(params: notification("session-1", [
        "sessionUpdate": "tool_call_delta_chunk", "tool_index": 0, "arguments_delta": "{\"command\":\"pwd\"}",
    ]))
    guard case .internalProgress = secondDelta[0] else { Issue.record("expected progress"); return }

    let callParams = notification("session-1", [
        "sessionUpdate": "tool_call", "toolCallId": "tool-1", "title": "Run command",
        "_meta": ["x.ai/tool": ["name": "shell"]],
    ])
    let call = normalizer.normalizeNotification(params: callParams)
    #expect(call == [.toolCall(name: "shell", callId: "tool-1", input: ["command": "pwd"])])
    guard case .internalProgress = normalizer.normalizeNotification(params: callParams)[0] else { Issue.record("expected progress"); return }

    let completed = notification("session-1", [
        "sessionUpdate": "tool_call_update", "toolCallId": "tool-1", "status": "completed",
        "rawOutput": ["stdout": "/tmp"],
    ])
    #expect(normalizer.normalizeNotification(params: completed) == [
        .toolOutput(name: "shell", callId: "tool-1", ok: true, exitCode: nil),
    ])
    guard case .internalProgress = normalizer.normalizeNotification(params: completed)[0] else {
        Issue.record("expected deduplicated progress")
        return
    }
}

@Test func grokNormalizerDeduplicatesTerminalNotificationAndPromptResponse() {
    let normalizer = GrokEventNormalizer()
    normalizer.adoptSession("session-1")
    let generation = normalizer.beginPrompt()
    let terminal = normalizer.normalizeNotification(params: notification("session-1", [
        "sessionUpdate": "turn_completed", "prompt_id": "prompt-1", "stop_reason": "end_turn",
        "usage": [
            "inputTokens": 10, "outputTokens": 4, "totalTokens": 14, "cachedReadTokens": 2,
            "reasoningTokens": 1, "modelCalls": 2, "apiDurationMs": 125, "numTurns": 1,
        ],
    ]))
    #expect(terminal.count == 2)
    #expect(terminal[0] == .telemetry(source: "grok_acp", sessionId: "session-1", turnId: "prompt-1", attrs: [
        "input_tokens": 10, "output_tokens": 4, "total_tokens": 14, "cached_read_tokens": 2,
        "reasoning_tokens": 1, "model_calls": 2, "api_duration_ms": 125, "num_turns": 1,
    ]))
    #expect(terminal[1] == .turnEnd(sessionId: "session-1"))
    #expect(!normalizer.canSteerBusy)
    #expect(normalizer.finishPrompt(generation: generation, completion: (stopReason: "end_turn", promptId: "prompt-1", agentResult: nil, usage: nil)).isEmpty)
}

@Test func grokNormalizerDoesNotLetALateTerminalCompleteTheNextPrompt() {
    let normalizer = GrokEventNormalizer()
    normalizer.adoptSession("session-1")
    let first = normalizer.beginPrompt()
    #expect(normalizer.finishPrompt(generation: first, completion: (stopReason: "end_turn", promptId: "prompt-1", agentResult: nil, usage: nil)) == [
        .turnEnd(sessionId: "session-1"),
    ])
    let second = normalizer.beginPrompt()
    #expect(normalizer.canSteerBusy)
    #expect(normalizer.normalizeNotification(params: notification("session-1", [
        "sessionUpdate": "turn_completed", "prompt_id": "prompt-1", "stop_reason": "end_turn",
    ])).isEmpty)
    #expect(normalizer.canSteerBusy)
    #expect(normalizer.finishPrompt(generation: second, completion: (stopReason: "end_turn", promptId: "prompt-2", agentResult: nil, usage: nil)) == [
        .turnEnd(sessionId: "session-1"),
    ])
    #expect(!normalizer.canSteerBusy)
}

@Test func grokNormalizerKeepsAToolCompletionThatOutlivesItsTurnFromBecomingAToolEvent() {
    let normalizer = GrokEventNormalizer()
    normalizer.adoptSession("session-1")
    let generation = normalizer.beginPrompt()
    #expect(normalizer.normalizeNotification(params: notification("session-1", [
        "sessionUpdate": "tool_call", "toolCallId": "tool-bg", "_meta": ["x.ai/tool": ["name": "shell"]],
    ])) == [.toolCall(name: "shell", callId: "tool-bg", input: [:])])
    _ = normalizer.finishPrompt(generation: generation, completion: (stopReason: "end_turn", promptId: "prompt-1", agentResult: nil, usage: nil))
    let late = normalizer.normalizeNotification(params: notification("session-1", [
        "sessionUpdate": "tool_call_update", "toolCallId": "tool-bg", "status": "completed",
    ]))
    #expect(late.count == 1)
    guard case .internalProgress = late[0] else { Issue.record("late completion is progress"); return }

    #expect(normalizer.normalizeNotification(params: notification("session-1", [
        "sessionUpdate": "tool_call", "toolCallId": "tool-successor", "_meta": ["x.ai/tool": ["name": "shell"]],
    ])) == [.toolCall(name: "shell", callId: "tool-successor", input: [:])])
    #expect(normalizer.normalizeNotification(params: notification("session-1", [
        "sessionUpdate": "tool_call_update", "toolCallId": "tool-successor", "status": "completed",
    ])) == [.toolOutput(name: "shell", callId: "tool-successor", ok: true, exitCode: nil)])

    _ = normalizer.beginPrompt()
    guard case .toolOutput = normalizer.normalizeNotification(params: notification("session-1", [
        "sessionUpdate": "tool_call_update", "toolCallId": "tool-unannounced", "status": "failed",
    ]))[0] else { Issue.record("unannounced completion inside a turn is a tool event"); return }
}

@Test func grokNormalizerCompletesAnAutonomousSuccessorTurnWithItsOwnPromptId() {
    let normalizer = GrokEventNormalizer()
    normalizer.adoptSession("session-1")
    let initial = normalizer.beginPrompt()
    _ = normalizer.finishPrompt(generation: initial, completion: (stopReason: "end_turn", promptId: "prompt-1", agentResult: nil, usage: nil))
    #expect(!normalizer.canSteerBusy)
    let autonomous = notification("session-1", [
        "sessionUpdate": "turn_completed", "prompt_id": "task-completed-call-1", "stop_reason": "end_turn",
    ])
    #expect(normalizer.normalizeNotification(params: autonomous) == [.turnEnd(sessionId: "session-1")])
    #expect(normalizer.normalizeNotification(params: autonomous).isEmpty, "the autonomous terminal must be emitted exactly once")
}

@Test func grokNormalizerDoesNotInventATurnForAnUnknownOrdinaryTerminal() {
    let normalizer = GrokEventNormalizer()
    normalizer.adoptSession("session-1")
    let generation = normalizer.beginPrompt()
    _ = normalizer.finishPrompt(generation: generation, completion: (stopReason: "end_turn", promptId: "prompt-1", agentResult: nil, usage: nil))
    #expect(normalizer.normalizeNotification(params: notification("session-1", [
        "sessionUpdate": "turn_completed", "prompt_id": "unknown-late-prompt", "stop_reason": "end_turn",
    ])).isEmpty)
    #expect(!normalizer.canSteerBusy)
}

@Test func grokAutonomousSuccessorTerminalCannotCompleteANewerForegroundTurn() {
    let normalizer = GrokEventNormalizer()
    normalizer.adoptSession("session-1")
    let first = normalizer.beginPrompt()
    _ = normalizer.finishPrompt(generation: first, completion: (stopReason: "end_turn", promptId: "prompt-1", agentResult: nil, usage: nil))
    let foreground = normalizer.beginPrompt()
    let background = notification("session-1", [
        "sessionUpdate": "turn_completed", "prompt_id": "task-completed-call-1", "stop_reason": "end_turn",
    ])
    #expect(normalizer.normalizeNotification(params: background).isEmpty)
    #expect(normalizer.canSteerBusy)
    _ = normalizer.finishPrompt(generation: foreground, completion: (stopReason: "end_turn", promptId: "prompt-2", agentResult: nil, usage: nil))
    #expect(!normalizer.canSteerBusy)
    #expect(normalizer.normalizeNotification(params: background).isEmpty, "a suppressed background completion stays deduplicated")
}

@Test func grokNormalizerAttributesConcreteOutputToActiveAndCompletedGenerations() {
    let normalizer = GrokEventNormalizer()
    normalizer.adoptSession("session-1")
    let first = normalizer.beginPrompt()
    #expect(normalizer.normalizeNotification(params: notification("session-1", [
        "sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "active answer"],
    ])) == [.text(text: "active answer", generation: first, state: "active")])
    _ = normalizer.finishPrompt(generation: first, completion: (stopReason: "end_turn", promptId: "prompt-1", agentResult: nil, usage: nil))
    #expect(normalizer.normalizeNotification(params: notification("session-1", [
        "sessionUpdate": "agent_thought_chunk", "content": ["type": "text", "text": "late thought"],
    ])) == [.thinking(text: "late thought", generation: first, state: "completed")])
    let second = normalizer.beginPrompt()
    #expect(normalizer.normalizeNotification(params: notification("session-1", [
        "sessionUpdate": "agent_thought_chunk", "content": ["type": "text", "text": "next turn thought"],
    ])) == [.thinking(text: "next turn thought", generation: second, state: "active")])
}

@Test func grokNormalizerKeepsInteractionLifecycleInternalAndBoundsUnknownExtensions() {
    let normalizer = GrokEventNormalizer()
    normalizer.adoptSession("session-1")
    for (kind, expected) in [("pending_interaction", "pending_interaction"), ("interaction_resolved", "interaction_resolved")] {
        let events = normalizer.normalizeNotification(params: notification("session-1", ["sessionUpdate": kind, "tool_call_id": "tool-1"]))
        #expect(events.count == 1)
        guard case .internalProgress(let itemType, let payloadBytes) = events[0] else { Issue.record("expected progress"); return }
        #expect(itemType == expected)
        #expect(payloadBytes > 0)
    }
    let unknown = normalizer.normalizeNotification(params: ["sessionId": "session-1", "promptId": "prompt-1"], method: "_x.ai/session/prompt_complete")
    guard case .internalProgress(let itemType, let payloadBytes) = unknown[0] else { Issue.record("expected progress"); return }
    #expect(itemType == "_x.ai/session/prompt_complete")
    #expect(payloadBytes > 0)
}

@Test func grokToolEndOutcomeTreatsRanCommandExitCodesAsOk() {
    #expect(grokToolEndOutcome(status: "completed", rawOutput: ["stdout": ""]) == GrokToolOutcome(ok: true, exitCode: nil))
    #expect(grokToolEndOutcome(status: "failed", rawOutput: ["error": "denied"]) == GrokToolOutcome(ok: false, exitCode: nil))
    #expect(grokToolEndOutcome(status: "cancelled", rawOutput: nil) == GrokToolOutcome(ok: false, exitCode: nil))
    #expect(grokToolEndOutcome(status: "failed", rawOutput: ["exit_code": 2, "stdout": ""]) == GrokToolOutcome(ok: true, exitCode: 2))
}

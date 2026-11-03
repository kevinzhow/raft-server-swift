import Foundation
import RaftDaemonClient
import Testing

private func fullUsage() -> [String: Any] {
    [
        "input": 100, "output": 200, "cacheRead": 30, "cacheWrite": 40,
        "cacheWrite1h": 5, "reasoning": 12, "totalTokens": 300,
        "cost": ["input": 0.01, "output": 0.02, "cacheRead": 0.001, "cacheWrite": 0.002, "total": 0.033],
    ]
}

@Test func piExtractsFullUsageTokensAndNestedCost() {
    #expect(PiTokenUsage.extractUsageAttrs(fullUsage()) == [
        "input_tokens": 100, "output_tokens": 200, "cached_read_tokens": 30,
        "cache_write_tokens": 40, "cache_write_1h_tokens": 5, "reasoning_tokens": 12,
        "total_tokens": 300, "totalCostUsd": 0.033, "cost_input_usd": 0.01,
        "cost_output_usd": 0.02, "cost_cache_read_usd": 0.001, "cost_cache_write_usd": 0.002,
    ])
    #expect(PiTokenUsage.extractUsageAttrs(["input": 10, "totalTokens": 10]) == ["input_tokens": 10, "total_tokens": 10])
    #expect(PiTokenUsage.extractUsageAttrs(["output": 0, "cost": ["total": 0]]) == ["output_tokens": 0, "totalCostUsd": 0])
    #expect(PiTokenUsage.extractUsageAttrs([:]).isEmpty)
    #expect(PiTokenUsage.extractUsageAttrs(nil).isEmpty)
    #expect(PiTokenUsage.extractUsageAttrs(NSNull()).isEmpty)
    #expect(PiTokenUsage.extractUsageAttrs(["input": "100", "output": Double.nan, "totalTokens": NSNull()]).isEmpty)
    #expect(PiTokenUsage.extractUsageAttrs(["input": Double.infinity]).isEmpty)
    #expect(PiTokenUsage.extractUsageAttrs(["input": 7, "cost": "nope"]) == ["input_tokens": 7])
    #expect(PiTokenUsage.extractUsageAttrs(["input": 7, "cost": [1, 2]]) == ["input_tokens": 7])
    #expect(PiTokenUsage.extractUsageAttrs(["input": 1, "some_unknown": 42, "cost": ["total": 0.5, "weird": 9]]) == ["input_tokens": 1, "totalCostUsd": 0.5])
    #expect(PiTokenUsage.extractUsageAttrs([1, 2, 3]).isEmpty)
}

@Test func piBuildsPerTurnTelemetryOnlyWhenUsageIsPresent() {
    let event = PiTokenUsage.buildEvent(message: ["role": "assistant", "usage": fullUsage()], sessionId: "pi-1")
    #expect(event?.kind == "telemetry")
    #expect(event?.name == "token_usage")
    #expect(event?.source == "pi_message_end_usage")
    #expect(event?.usageKind == "per_turn")
    #expect(event?.sessionId == "pi-1")
    #expect(event?.attrs["total_tokens"] == 300 && event?.attrs["totalCostUsd"] == 0.033)

    #expect(PiTokenUsage.buildEvent(message: ["role": "assistant", "stopReason": "error"], sessionId: "pi-1") == nil)
    #expect(PiTokenUsage.buildEvent(message: ["role": "assistant", "usage": [:]], sessionId: "pi-1") == nil)
    #expect(PiTokenUsage.buildEvent(message: nil, sessionId: nil) == nil)
    #expect(PiTokenUsage.buildEvent(message: "not-an-object", sessionId: "pi-1") == nil)

    let zero = PiTokenUsage.buildEvent(message: ["usage": ["totalTokens": 0]], sessionId: "pi-1")
    #expect(zero?.kind == "telemetry")
    #expect(zero?.attrs == ["total_tokens": 0])
    #expect(PiTokenUsage.buildEvent(message: ["usage": ["input": 3]], sessionId: nil)?.sessionId == nil)
}

@Test func geminiExtractsOnlyTheConfirmedTotalTokensField() {
    #expect(GeminiTokenUsage.extractUsageAttrs(["total_tokens": 1000]) == ["total_tokens": 1000])
    #expect(GeminiTokenUsage.extractUsageAttrs(["total_tokens": 0]) == ["total_tokens": 0])
    #expect(GeminiTokenUsage.extractUsageAttrs([:]).isEmpty)
    #expect(GeminiTokenUsage.extractUsageAttrs(nil).isEmpty)
    #expect(GeminiTokenUsage.extractUsageAttrs(NSNull()).isEmpty)
    #expect(GeminiTokenUsage.extractUsageAttrs(["total_tokens": "1000"]).isEmpty)
    #expect(GeminiTokenUsage.extractUsageAttrs(["total_tokens": NSNull()]).isEmpty)
    #expect(GeminiTokenUsage.extractUsageAttrs(["total_tokens": Double.nan]).isEmpty)
    #expect(GeminiTokenUsage.extractUsageAttrs(["total_tokens": Double.infinity]).isEmpty)
    #expect(GeminiTokenUsage.extractUsageAttrs(["total_tokens": 5, "some_unknown_gemini_field": 42, "nested": ["x": 1]]) == ["total_tokens": 5])
    #expect(GeminiTokenUsage.extractUsageAttrs([1, 2, 3]).isEmpty)
}

@Test func geminiBuildsPerTurnTelemetryAndNormalizesNullSession() {
    let event = GeminiTokenUsage.buildEvent(stats: ["total_tokens": 1000], sessionId: "sess-1")
    #expect(event?.kind == "telemetry")
    #expect(event?.name == "token_usage")
    #expect(event?.source == "gemini_result_stats")
    #expect(event?.usageKind == "per_turn")
    #expect(event?.sessionId == "sess-1")
    #expect(event?.attrs == ["total_tokens": 1000])

    let zero = GeminiTokenUsage.buildEvent(stats: ["total_tokens": 0], sessionId: "sess-1")
    #expect(zero?.kind == "telemetry")
    #expect(zero?.attrs == ["total_tokens": 0])
    #expect(GeminiTokenUsage.buildEvent(stats: [:], sessionId: "sess-1") == nil)
    #expect(GeminiTokenUsage.buildEvent(stats: nil, sessionId: nil) == nil)
    #expect(GeminiTokenUsage.buildEvent(stats: ["total_tokens": "nope"], sessionId: "sess-1") == nil)
    #expect(GeminiTokenUsage.buildEvent(stats: ["total_tokens": 7], sessionId: nil)?.sessionId == nil)
}

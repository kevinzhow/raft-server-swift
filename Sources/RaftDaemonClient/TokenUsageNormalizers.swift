import Foundation

/// Token-usage telemetry extracted from a runtime's terminal event. Shared
/// discipline: typed extraction only (finite numbers), an explicit allowlist
/// (no raw passthrough), and mark-absent rather than zero-fill — an empty usage
/// yields no event, while a field present with value 0 is a real reported 0.
public struct RuntimeTokenUsageEvent: Equatable, Sendable {
    public var kind: String = "telemetry"
    public var name: String = "token_usage"
    public var source: String
    public var usageKind: String = "per_turn"
    public var sessionId: String?
    public var attrs: [String: Double]
}

private func finiteNumber(_ value: Any?) -> Double? {
    guard let value, !(value is Bool), !(value is NSNull) else { return nil }
    if let number = value as? NSNumber {
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }
    if let double = value as? Double {
        return double.isFinite ? double : nil
    }
    return nil
}

private func recordObject(_ value: Any?) -> [String: Any]? {
    guard let value, !(value is NSNull), let dict = value as? [String: Any] else { return nil }
    return dict
}

/// Pi (and builtin) `message_end` usage: pi-ai `Usage` with top-level token
/// counts and a nested per-category cost breakdown.
public enum PiTokenUsage {
    private static let tokenMappings: [(String, String)] = [
        ("input", "input_tokens"),
        ("output", "output_tokens"),
        ("cacheRead", "cached_read_tokens"),
        ("cacheWrite", "cache_write_tokens"),
        ("cacheWrite1h", "cache_write_1h_tokens"),
        ("reasoning", "reasoning_tokens"),
        ("totalTokens", "total_tokens"),
    ]
    private static let costMappings: [(String, String)] = [
        ("total", "totalCostUsd"),
        ("input", "cost_input_usd"),
        ("output", "cost_output_usd"),
        ("cacheRead", "cost_cache_read_usd"),
        ("cacheWrite", "cost_cache_write_usd"),
    ]

    public static func extractUsageAttrs(_ usage: Any?) -> [String: Double] {
        guard let source = recordObject(usage) else { return [:] }
        var attrs: [String: Double] = [:]
        for (wireKey, attrKey) in tokenMappings {
            if let candidate = finiteNumber(source[wireKey]) { attrs[attrKey] = candidate }
        }
        if let cost = recordObject(source["cost"]) {
            for (wireKey, attrKey) in costMappings {
                if let candidate = finiteNumber(cost[wireKey]) { attrs[attrKey] = candidate }
            }
        }
        return attrs
    }

    /// Build the per-turn `token_usage` telemetry event from a pi
    /// `message_end` event's `message.usage`; nil when no usage field is present.
    public static func buildEvent(message: Any?, sessionId: String?) -> RuntimeTokenUsageEvent? {
        guard let message = recordObject(message) else { return nil }
        let attrs = extractUsageAttrs(message["usage"])
        guard !attrs.isEmpty else { return nil }
        return RuntimeTokenUsageEvent(
            source: "pi_message_end_usage",
            sessionId: sessionId,
            attrs: attrs
        )
    }
}

/// Gemini CLI `result` event `stats`; only `total_tokens` is confirmed against
/// the runtime's event schema.
public enum GeminiTokenUsage {
    private static let mappings: [(String, String)] = [("total_tokens", "total_tokens")]

    public static func extractUsageAttrs(_ stats: Any?) -> [String: Double] {
        guard let source = recordObject(stats) else { return [:] }
        var attrs: [String: Double] = [:]
        for (wireKey, attrKey) in mappings {
            if let candidate = finiteNumber(source[wireKey]) { attrs[attrKey] = candidate }
        }
        return attrs
    }

    /// Build the per-turn `token_usage` telemetry event from a gemini `result`
    /// event's `stats`; nil when no usage field is present.
    public static func buildEvent(stats: Any?, sessionId: String?) -> RuntimeTokenUsageEvent? {
        let attrs = extractUsageAttrs(stats)
        guard !attrs.isEmpty else { return nil }
        return RuntimeTokenUsageEvent(
            source: "gemini_result_stats",
            sessionId: sessionId,
            attrs: attrs
        )
    }
}

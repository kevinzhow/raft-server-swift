import Foundation
import Synchronization

/// Tokens one turn used, split the way providers bill them: `input` is
/// uncached input only, `cacheRead`/`cacheWrite` are the cached parts, and
/// `output` includes reasoning. Unreported fields stay absent, never 0.
/// Ported from the upstream daemon turn-token accumulator.
public struct TurnTokenCounts: Sendable, Equatable {
    public var input: Int?
    public var output: Int?
    public var cacheRead: Int?
    public var cacheWrite: Int?
    public init(input: Int? = nil, output: Int? = nil, cacheRead: Int? = nil, cacheWrite: Int? = nil) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }
}

public final class TurnTokenAccumulator: Sendable {
    fileprivate struct State: Sendable {
        var added = TurnTokenCounts()
        var sessionBase: TurnTokenCounts?
        var sessionLatest: TurnTokenCounts?
    }

    fileprivate let state = Mutex(State())

    // Each public setter remains an independent replacement. Runtime folds and
    // count snapshots borrow the complete state rather than composing accessors.
    public var added: TurnTokenCounts {
        get { state.withLock { $0.added } }
        set { state.withLock { $0.added = newValue } }
    }

    public var sessionBase: TurnTokenCounts? {
        get { state.withLock { $0.sessionBase } }
        set { state.withLock { $0.sessionBase = newValue } }
    }

    public var sessionLatest: TurnTokenCounts? {
        get { state.withLock { $0.sessionLatest } }
        set { state.withLock { $0.sessionLatest = newValue } }
    }

    public init() {}
}

public enum RuntimeTurnTokens {
    static func tokenFields() -> [WritableKeyPath<TurnTokenCounts, Int?>] { [\.input, \.output, \.cacheRead, \.cacheWrite] }

    static func num(_ attrs: [String: Double], _ key: String) -> Int? {
        guard let value = attrs[key], value.isFinite else { return nil }
        return Int(value)
    }

    static func counts(input: Int?, output: Int?, cacheRead: Int?, cacheWrite: Int?) -> TurnTokenCounts {
        .init(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite)
    }

    /// Codex counts cached input inside `inputTokens`; split it out.
    static func codexCounts(_ attrs: [String: Double], prefix: String = "") -> TurnTokenCounts? {
        func key(_ name: String) -> String {
            guard !prefix.isEmpty else { return name }
            return prefix + name.prefix(1).uppercased() + name.dropFirst()
        }
        guard let input = num(attrs, key("inputTokens")),
              let cached = num(attrs, key("cachedInputTokens")),
              let output = num(attrs, key("outputTokens"))
        else { return nil }
        return counts(input: input - cached, output: output, cacheRead: cached, cacheWrite: nil)
    }

    static func add(_ into: inout TurnTokenCounts, _ next: TurnTokenCounts) {
        for field in tokenFields() {
            if let value = next[keyPath: field] {
                into[keyPath: field] = (into[keyPath: field] ?? 0) + value
            }
        }
    }

    /// Folds one `token_usage` report into the open turn; sources whose numbers
    /// do not mean the same thing (a bare total) are skipped rather than guessed.
    public static func note(_ acc: TurnTokenAccumulator, name: String, source: String, attrs: [String: Double]) {
        guard name == "token_usage" else { return }
        acc.state.withLock { state in
            switch source {
            case "claude_result_usage":
                add(&state.added, counts(
                    input: num(attrs, "inputTokens"), output: num(attrs, "outputTokens"),
                    cacheRead: num(attrs, "cachedInputTokens"), cacheWrite: num(attrs, "cacheCreationInputTokens")
                ))
            case "pi_message_end_usage", "kimi_turn_step_completed_usage":
                add(&state.added, counts(
                    input: num(attrs, "input_tokens"), output: num(attrs, "output_tokens"),
                    cacheRead: num(attrs, "cached_read_tokens"), cacheWrite: num(attrs, "cache_write_tokens")
                ))
            case "codex_thread_token_usage_updated":
                guard let total = codexCounts(attrs) else { return }
                if state.sessionBase == nil {
                    guard let last = codexCounts(attrs, prefix: "last") else { return }
                    var base = TurnTokenCounts()
                    for field in tokenFields() {
                        if let total = total[keyPath: field], let last = last[keyPath: field] {
                            base[keyPath: field] = total - last
                        }
                    }
                    state.sessionBase = base
                }
                state.sessionLatest = total
            default:
                return
            }
        }
    }

    public static func counts(for acc: TurnTokenAccumulator) -> TurnTokenCounts {
        acc.state.withLock { state in
            var result = state.added
            if let base = state.sessionBase, let latest = state.sessionLatest {
                var delta = TurnTokenCounts()
                for field in tokenFields() {
                    guard let baseValue = base[keyPath: field], let latestValue = latest[keyPath: field] else { continue }
                    // Totals that went backwards (a reset session) give no usable number.
                    if latestValue < baseValue { return state.added }
                    delta[keyPath: field] = latestValue - baseValue
                }
                add(&result, delta)
            }
            return result
        }
    }

    public static func traceAttrs(_ acc: TurnTokenAccumulator) -> [String: Int] {
        let tokens = counts(for: acc)
        var attrs: [String: Int] = [:]
        if let input = tokens.input { attrs["input_tokens"] = input }
        if let output = tokens.output { attrs["output_tokens"] = output }
        if let cacheRead = tokens.cacheRead { attrs["cache_read_tokens"] = cacheRead }
        if let cacheWrite = tokens.cacheWrite { attrs["cache_write_tokens"] = cacheWrite }
        return attrs
    }
}

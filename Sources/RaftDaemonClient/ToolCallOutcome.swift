import Foundation

/// Per-launch bookkeeping that turns a runtime's tool start/end events into the
/// outcome recorded on the "Tool finished" activity entry. Durations are taken
/// at the daemon because server receive times include network delay. Ported
/// from the upstream daemon helper.
public enum ToolCallOutcomeBookkeeping {
    /// Calls still open; a runtime that never ends a call must not grow this forever.
    public static let maxOpenToolCalls = 256

    public struct Outcome: Equatable, Sendable {
        public var callId: String?
        public var ok: Bool?
        public var durationMs: Int?
        public var exitCode: Int?

        public init(callId: String? = nil, ok: Bool? = nil, durationMs: Int? = nil, exitCode: Int? = nil) {
            self.callId = callId
            self.ok = ok
            self.durationMs = durationMs
            self.exitCode = exitCode
        }
    }

    public struct OpenCalls: Equatable, Sendable {
        public private(set) var order: [String] = []
        public private(set) var starts: [String: Int] = [:]

        public init() {}

        public var count: Int { starts.count }

        mutating func note(_ callId: String, nowMs: Int) {
            if starts[callId] != nil { order.removeAll { $0 == callId } }
            starts[callId] = nowMs
            order.append(callId)
        }

        mutating func forget(_ callId: String) -> Int? {
            let startedAt = starts[callId]
            starts[callId] = nil
            order.removeAll { $0 == callId }
            return startedAt
        }

        mutating func dropOldest() {
            guard let oldest = order.first else { return }
            order.removeFirst()
            starts[oldest] = nil
        }
    }

    public static func noteStart(_ calls: inout OpenCalls, callId: String?, nowMs: Int) {
        guard let callId else { return }
        calls.note(callId, nowMs: nowMs)
        while calls.count > maxOpenToolCalls {
            calls.dropOldest()
        }
    }

    /// The outcome of a finished call, or nil when the runtime reported nothing
    /// about it. The runtime's own duration wins over the daemon's measurement.
    public static func finish(
        _ calls: inout OpenCalls,
        callId: String?,
        ok: Bool?,
        durationMs: Int?,
        exitCode: Int?,
        nowMs: Int
    ) -> Outcome? {
        let startedAt = callId.flatMap { calls.forget($0) }
        let measured = validDuration(durationMs) ?? startedAt.flatMap { validDuration(nowMs - $0) }
        var outcome = Outcome(
            callId: callId,
            ok: ok,
            durationMs: measured,
            exitCode: exitCode
        )
        if outcome.callId == nil { outcome.callId = nil }
        let isEmpty = outcome.callId == nil && outcome.ok == nil && outcome.durationMs == nil && outcome.exitCode == nil
        return isEmpty ? nil : outcome
    }

    private static func validDuration(_ ms: Int?) -> Int? {
        guard let ms, ms >= 0 else { return nil }
        return ms
    }
}

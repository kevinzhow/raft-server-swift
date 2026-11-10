import Foundation
import Crypto
import RaftShared

struct AgentExecutionOutcomeFrame: Sendable {
    enum Event: Sendable {
        case lost(String)
        case marker(epoch: Int64, critical: Bool)
        case spawned(launch: String, process: String, superseded: [String], respawn: Bool)
        case exited(launch: String, process: String, spawnLaunch: String?)
        case rebound(launch: String, process: String)
        case notSpawned(launch: String, reason: String?)
        case terminalFailure(launch: String, session: String?, fingerprint: String)
        case turnCompleted(launch: String, session: String?, catchupBatchId: String?)
    }
    let agentId: String
    let daemonInstanceId: String?
    let clientSeq: Int64?
    let gapId: String?
    let fingerprint: String
    let event: Event

    var acknowledgement: AgentExecutionAcknowledgement {
        if let gapId { return .marker(agentId: agentId, gapId: gapId) }
        return .sequence(agentId: agentId, daemonInstanceId: daemonInstanceId!, clientSeq: clientSeq!)
    }

    static let families: Set<String> = [
        "agent:runtime:outcome", "agent:process_spawned", "agent:process_exited", "agent:start:outcome",
        "agent:runtime:outcome_gap", "agent:runtime:outcome_cross_instance_unknown"
    ]

    static func string(_ value: JSONValue?) -> String? {
        guard case .string(let text)? = value else { return nil }
        return text
    }
    static func id(_ value: JSONValue?) -> String? {
        guard let text = string(value), !text.isEmpty else { return nil }
        return text
    }
    static func dictionary(_ value: JSONValue?) -> [String: JSONValue]? {
        guard case .object(let members)? = value else { return nil }
        return members
    }
    static func count(_ value: JSONValue?) -> Int64? {
        switch value {
        case .integer(let number)? where number >= 0 && number <= 9_007_199_254_740_991: return number
        case .number(let number)? where number.isFinite && number >= 0 && number <= 9_007_199_254_740_991
            && number.rounded(.towardZero) == number: return Int64(number)
        default: return nil
        }
    }
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func object(_ payload: Data) -> [String: JSONValue]? {
        guard payload.count <= 1024 * 1024, supportsCanonicalNumbers(payload) else { return nil }
        return try? JSONDecoder().decode([String: JSONValue].self, from: payload)
    }

    /// The old Foundation decoder also admitted unsigned/decimal representations
    /// that JSONValue cannot retain losslessly. Hold those before assigning a
    /// fingerprint. Short floating lexemes must also render identically before
    /// and after typed decoding; strings are never scanned as numeric values.
    static func supportsCanonicalNumbers(_ payload: Data) -> Bool {
        let bytes = Array(payload)
        var index = 0
        var quoted = false
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
                index += 1
                continue
            }
            if byte == 34 { quoted = true; index += 1; continue }
            guard byte == 45 || (48...57).contains(byte) else { index += 1; continue }
            let beginning = index
            while index < bytes.count {
                let next = bytes[index]
                guard (48...57).contains(next) || [43, 45, 46, 69, 101].contains(next) else { break }
                index += 1
            }
            let token = String(decoding: bytes[beginning..<index], as: UTF8.self)
            if !token.contains(".") && !token.contains("e") && !token.contains("E") {
                guard Int64(token) != nil, token != "-0" else { return false }
            } else {
                // Do not silently round a long decimal through Double or erase
                // negative zero. This deliberately holds some valid JSON values.
                guard token.utf8.count <= 15, let number = Double(token), number.isFinite,
                      !(number == 0 && number.sign == .minus),
                      let decoded = try? JSONDecoder().decode(JSONValue.self, from: Data(token.utf8)),
                      LegacySortedJSON.render(decoded) == LegacySortedJSON.render(.number(number)) else { return false }
                let mantissa = token.split(whereSeparator: { $0 == "e" || $0 == "E" }).first ?? ""
                if number == 0 && mantissa.contains(where: { "123456789".contains($0) }) { return false }
            }
        }
        return true
    }

    static func parse(type: String, payload: Data) -> Self? {
        guard families.contains(type), let body = object(payload), string(body["type"]) == type,
              let agentId = id(body["agentId"]), let canonical = LegacySortedJSON.render(.object(body)) else { return nil }
        let fingerprint = digest(Data(canonical.utf8))
        if type == "agent:runtime:outcome_gap" || type == "agent:runtime:outcome_cross_instance_unknown" {
            guard let gapId = id(body["gapId"]) else { return nil }
            let epoch = count(body["takeoverEpoch"]) ?? 9_007_199_254_740_991
            var critical = true
            if type == "agent:runtime:outcome_gap", let counts = dictionary(body["counts"]) {
                let keys = ["e1", "spawned", "exited", "startOutcome"]
                let numbers = keys.compactMap { count(counts[$0]) }
                if numbers.count == keys.count, count(counts["turnCompleted"]) != nil { critical = numbers.contains { $0 > 0 } }
            }
            return Self(agentId: agentId, daemonInstanceId: nil, clientSeq: nil, gapId: gapId,
                        fingerprint: fingerprint, event: .marker(epoch: epoch, critical: critical))
        }
        guard let daemon = id(body["daemonInstanceId"]), let sequence = count(body["clientSeq"]) else { return nil }
        func frame(_ event: Event) -> Self {
            Self(agentId: agentId, daemonInstanceId: daemon, clientSeq: sequence, gapId: nil,
                 fingerprint: fingerprint, event: event)
        }
        func lost(_ reason: String) -> Self { frame(.lost(reason)) }
        switch type {
        case "agent:runtime:outcome":
            guard count(body["v"]) == 1 else { return lost("unknown_version") }
            guard let launch = id(body["launchId"]), let outcome = dictionary(body["outcome"]) else { return lost("malformed_outcome") }
            let session = string(body["sessionId"])
            switch string(outcome["kind"]) {
            case "terminal_failure":
                guard let signature = string(outcome["fingerprint"]), string(outcome["failureKind"]) != nil else { return lost("malformed_outcome") }
                return frame(.terminalFailure(launch: launch, session: session, fingerprint: digest(Data(signature.utf8))))
            case "turn_completed":
                if let batch = outcome["catchupBatchId"], id(batch) == nil { return lost("malformed_outcome") }
                return frame(.turnCompleted(launch: launch, session: session, catchupBatchId: id(outcome["catchupBatchId"])))
            default: return lost("unknown_outcome_kind")
            }
        case "agent:process_spawned":
            guard let launch = id(body["launchId"]), let process = id(body["processInstanceId"]) else { return lost("malformed_spawned") }
            var superseded: [String] = []
            if let raw = body["supersededLaunchIds"] {
                guard case .array(let values) = raw else { return lost("malformed_spawned") }
                let identifiers = values.compactMap { id($0) }
                guard identifiers.count == values.count else { return lost("malformed_spawned") }
                superseded = identifiers
            }
            return frame(.spawned(launch: launch, process: process, superseded: superseded, respawn: body["respawn"] == .bool(true)))
        case "agent:process_exited":
            guard let launch = id(body["launchId"]), let process = id(body["processInstanceId"]),
                  body["spawnLaunchId"] == .null || id(body["spawnLaunchId"]) != nil else { return lost("malformed_exited") }
            return frame(.exited(launch: launch, process: process, spawnLaunch: id(body["spawnLaunchId"])))
        case "agent:start:outcome":
            guard let launch = id(body["launchId"]), let result = dictionary(body["result"]) else { return lost("malformed_start_outcome") }
            if string(result["kind"]) == "rebound", let process = id(result["processInstanceId"]) { return frame(.rebound(launch: launch, process: process)) }
            if string(result["kind"]) == "not_spawned" {
                let known: Set<String> = ["start_rejected", "spawn_failed", "cancelled", "deferred", "admission_full",
                    "terminal_failure_needs_manual", "terminal_failure_outcome_storage_blocked", "spawn_error", "stale_dispatch"]
                let reason = string(result["reason"])
                return frame(.notSpawned(launch: launch, reason: reason.flatMap { known.contains($0) ? $0 : nil }))
            }
            return lost("malformed_start_outcome")
        default: return nil
        }
    }
}

/// Numeric encodings outside this checked subset must be held rather than
/// silently rounded into a different stored fingerprint or published value.
public enum AgentExecutionJSONNumberPolicy {
    public static func accepts(_ payload: Data) -> Bool {
        AgentExecutionOutcomeFrame.supportsCanonicalNumbers(payload)
    }
}

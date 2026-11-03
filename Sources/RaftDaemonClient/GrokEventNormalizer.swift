import Foundation

/// Grok Build (ACP over JSON-RPC) event normalizer: turns session notifications
/// into text/thinking/tool/telemetry/turn events for the daemon. Ported from the
/// upstream daemon normalizer, including the turn-generation bookkeeping that
/// keeps late or autonomous terminals from closing the wrong turn.
public enum GrokEvent: Equatable, Sendable {
    case text(text: String, generation: Int?, state: String?)
    case thinking(text: String, generation: Int?, state: String?)
    case internalProgress(itemType: String, payloadBytes: Int)
    case toolCall(name: String, callId: String?, input: [String: String])
    case toolOutput(name: String, callId: String, ok: Bool, exitCode: Int?)
    case error(message: String)
    case telemetry(source: String, sessionId: String?, turnId: String?, attrs: [String: Double])
    case turnEnd(sessionId: String?)
}

public final class GrokEventNormalizer {
    public static let autonomousSuccessorPromptPrefix = "task-completed-call-"
    private static let terminalToolStatuses: Set<String> = ["completed", "failed", "cancelled"]

    private var sessionIdValue: String?
    private var nextTurnGeneration = 0
    private var activeTurnGeneration: Int?
    private var lastCompletedTurnGeneration: Int?
    private var completedTurnGenerations: [Int] = []
    private var generationByPromptId: [String: Int] = [:]
    private var promptIdsByGeneration: [Int: [String]] = [:]
    private var completedAutonomousSuccessorPromptIds: [String] = []
    private var toolCalls: [String: ToolState] = [:]
    private var toolCallIdsByIndex: [Int: String] = [:]

    private struct ToolState {
        var name: String
        var arguments: String
        var callEmitted = false
        var outputEmitted = false
    }

    public init() {}

    public var sessionId: String? { sessionIdValue }
    public var canSteerBusy: Bool { activeTurnGeneration != nil }

    public func reset() {
        sessionIdValue = nil
        nextTurnGeneration = 0
        activeTurnGeneration = nil
        lastCompletedTurnGeneration = nil
        completedTurnGenerations = []
        generationByPromptId = [:]
        promptIdsByGeneration = [:]
        completedAutonomousSuccessorPromptIds = []
        toolCalls = [:]
        toolCallIdsByIndex = [:]
    }

    public func adoptSession(_ sessionId: String) {
        sessionIdValue = sessionId
    }

    public func beginPrompt() -> Int {
        nextTurnGeneration += 1
        activeTurnGeneration = nextTurnGeneration
        toolCalls = [:]
        toolCallIdsByIndex = [:]
        return nextTurnGeneration
    }

    public func abortPrompt(generation: Int) {
        if activeTurnGeneration == generation { activeTurnGeneration = nil }
        forgetPromptIdsForGeneration(generation)
    }

    // MARK: - notification normalization

    public func normalizeNotification(params: [String: Any], method: String? = nil) -> [GrokEvent] {
        let notificationSessionId = nonEmptyString(params["sessionId"])
        if let notificationSessionId, notificationSessionId != sessionIdValue {
            return []
        }
        guard let update = recordValue(params["update"]) else {
            return method.map { [.internalProgress(itemType: $0, payloadBytes: payloadBytes(params))] } ?? []
        }
        guard let updateKind = nonEmptyString(update["sessionUpdate"]) else {
            return [.internalProgress(itemType: method ?? "session/update", payloadBytes: payloadBytes(update))]
        }
        switch updateKind {
        case "agent_message_chunk":
            guard let content = recordValue(update["content"]), content["type"] as? String == "text",
                  let text = content["text"] as? String, !text.isEmpty
            else { return [.internalProgress(itemType: updateKind, payloadBytes: payloadBytes(update))] }
            let turn = runtimeTurnAttribution()
            return [.text(text: text, generation: turn?.generation, state: turn?.state)]
        case "agent_thought_chunk":
            guard let content = recordValue(update["content"]), content["type"] as? String == "text",
                  let text = content["text"] as? String, !text.isEmpty
            else { return [.internalProgress(itemType: updateKind, payloadBytes: payloadBytes(update))] }
            let turn = runtimeTurnAttribution()
            return [.thinking(text: text, generation: turn?.generation, state: turn?.state)]
        case "tool_call_delta_chunk":
            let index = (update["tool_index"] as? NSNumber)?.intValue
            let wireId = nonEmptyString(update["tool_call_id"])
            if let index, let wireId { toolCallIdsByIndex[index] = wireId }
            let toolCallId = wireId ?? index.flatMap { toolCallIdsByIndex[$0] }
            if let toolCallId {
                var state = toolCalls[toolCallId] ?? ToolState(name: toolName(update), arguments: "")
                state.name = toolName(update, fallback: state.name)
                if let delta = update["arguments_delta"] as? String { state.arguments += delta }
                toolCalls[toolCallId] = state
            }
            return [.internalProgress(itemType: updateKind, payloadBytes: payloadBytes(update))]
        case "tool_call":
            let id = nonEmptyString(update["toolCallId"]) ?? "anonymous-\(toolCalls.count + 1)"
            var state = toolCalls[id] ?? ToolState(name: toolName(update), arguments: "")
            state.name = toolName(update, fallback: state.name)
            toolCalls[id] = state
            if state.callEmitted { return [.internalProgress(itemType: updateKind, payloadBytes: payloadBytes(update))] }
            state.callEmitted = true
            toolCalls[id] = state
            var input: [String: String] = [:]
            if let raw = recordValue(update["rawInput"]) {
                for (key, value) in raw where value is String { input[key] = value as? String }
            } else if let parsed = parseAccumulatedArguments(state.arguments) {
                for (key, value) in parsed where value is String { input[key] = value as? String }
            }
            let callId = nonEmptyString(update["toolCallId"])
            return [.toolCall(name: state.name, callId: callId, input: input)]
        case "tool_call_update":
            let toolCallId = nonEmptyString(update["toolCallId"])
            let status = nonEmptyString(update["status"])
            guard let toolCallId, let status, Self.terminalToolStatuses.contains(status) else {
                return [.internalProgress(itemType: updateKind, payloadBytes: payloadBytes(update))]
            }
            if activeTurnGeneration == nil && toolCalls[toolCallId] == nil {
                return [.internalProgress(itemType: updateKind, payloadBytes: payloadBytes(update))]
            }
            var state = toolCalls[toolCallId] ?? ToolState(name: toolName(update), arguments: "")
            toolCalls[toolCallId] = state
            if state.outputEmitted { return [.internalProgress(itemType: updateKind, payloadBytes: payloadBytes(update))] }
            state.outputEmitted = true
            toolCalls[toolCallId] = state
            let outcome = grokToolEndOutcome(status: status, rawOutput: update["rawOutput"])
            return [.toolOutput(name: state.name, callId: toolCallId, ok: outcome.ok, exitCode: outcome.exitCode)]
        case "pending_interaction", "interaction_resolved":
            return [.internalProgress(itemType: updateKind, payloadBytes: payloadBytes(update))]
        case "turn_completed":
            let promptId = nonEmptyString(update["prompt_id"])
            if let promptId, promptId.hasPrefix(Self.autonomousSuccessorPromptPrefix) {
                if completedAutonomousSuccessorPromptIds.contains(promptId) { return [] }
                rememberAutonomousSuccessorCompletion(promptId)
                if activeTurnGeneration != nil { return [] }
            }
            let generation: Int?
            if let promptId {
                generation = generationByPromptId[promptId] ?? activeTurnGeneration ?? beginAutonomousSuccessorCompletion(promptId)
            } else {
                generation = activeTurnGeneration
            }
            return finishPrompt(generation: generation, completion: (
                stopReason: update["stop_reason"], promptId: promptId,
                agentResult: update["agent_result"], usage: update["usage"]
            ))
        default:
            return [.internalProgress(itemType: updateKind, payloadBytes: payloadBytes(update))]
        }
    }

    public func finishPrompt(
        generation: Int?,
        completion: (stopReason: Any?, promptId: String?, agentResult: Any?, usage: Any?)
    ) -> [GrokEvent] {
        guard let generation else { return [] }
        let promptId = nonEmptyString(completion.promptId)
        if let promptId { rememberPromptGeneration(promptId, generation: generation) }
        if completedTurnGenerations.contains(generation) { return [] }
        completedTurnGenerations.append(generation)
        lastCompletedTurnGeneration = generation
        if completedTurnGenerations.count > 32, let oldest = completedTurnGenerations.first {
            completedTurnGenerations.removeFirst()
            forgetPromptIdsForGeneration(oldest)
        }
        if activeTurnGeneration == generation { activeTurnGeneration = nil }
        let stopReason = nonEmptyString(completion.stopReason) ?? "unknown"
        let agentResult = nonEmptyString(completion.agentResult)
        var events: [GrokEvent] = []
        let usageAttrs = numericUsageAttrs(completion.usage)
        if !usageAttrs.isEmpty {
            events.append(.telemetry(source: "grok_acp", sessionId: sessionIdValue, turnId: promptId, attrs: usageAttrs))
        }
        if stopReason == "error" {
            events.append(.error(message: agentResult ?? "Grok Build turn failed"))
        } else if stopReason == "cancelled" {
            events.append(.error(message: agentResult ?? "Grok Build turn was cancelled"))
        }
        events.append(.turnEnd(sessionId: sessionIdValue))
        toolCalls = [:]
        toolCallIdsByIndex = [:]
        return events
    }

    // MARK: - helpers

    private func runtimeTurnAttribution() -> (generation: Int, state: String)? {
        if let activeTurnGeneration { return (activeTurnGeneration, "active") }
        if let lastCompletedTurnGeneration { return (lastCompletedTurnGeneration, "completed") }
        return nil
    }

    private func rememberPromptGeneration(_ promptId: String, generation: Int) {
        guard generationByPromptId[promptId] == nil else { return }
        generationByPromptId[promptId] = generation
        promptIdsByGeneration[generation, default: []].append(promptId)
    }

    private func beginAutonomousSuccessorCompletion(_ promptId: String) -> Int? {
        guard promptId.hasPrefix(Self.autonomousSuccessorPromptPrefix) else { return nil }
        nextTurnGeneration += 1
        rememberPromptGeneration(promptId, generation: nextTurnGeneration)
        return nextTurnGeneration
    }

    private func rememberAutonomousSuccessorCompletion(_ promptId: String) {
        completedAutonomousSuccessorPromptIds.append(promptId)
        if completedAutonomousSuccessorPromptIds.count > 32 {
            completedAutonomousSuccessorPromptIds.removeFirst()
        }
    }

    private func forgetPromptIdsForGeneration(_ generation: Int) {
        guard let promptIds = promptIdsByGeneration[generation] else { return }
        for promptId in promptIds where generationByPromptId[promptId] == generation {
            generationByPromptId[promptId] = nil
        }
        promptIdsByGeneration[generation] = nil
    }
}

public struct GrokToolOutcome: Equatable, Sendable {
    public var ok: Bool
    public var exitCode: Int?

    public init(ok: Bool, exitCode: Int? = nil) {
        self.ok = ok
        self.exitCode = exitCode
    }
}

/// ACP's terminal tool status: `completed` is successful; `failed`/`cancelled`
/// are not, unless the output carries the exit code of a command that ran.
public func grokToolEndOutcome(status: String, rawOutput: Any?) -> GrokToolOutcome {
    let output = recordValue(rawOutput) ?? [:]
    let exit = output["exit_code"] ?? output["exitCode"]
    if let number = exit as? NSNumber, number.doubleValue == number.doubleValue.rounded(), number.doubleValue >= 0 || true {
        return GrokToolOutcome(ok: true, exitCode: number.intValue)
    }
    return GrokToolOutcome(ok: status == "completed", exitCode: nil)
}

private func nonEmptyString(_ value: Any?) -> String? {
    guard let string = value as? String else { return nil }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : string
}

private func recordValue(_ value: Any?) -> [String: Any]? {
    guard let dict = value as? [String: Any] else { return nil }
    return dict
}

private func payloadBytes(_ value: Any) -> Int {
    guard let data = try? JSONSerialization.data(withJSONObject: value) else { return 0 }
    return data.count
}

private func toolName(_ update: [String: Any], fallback: String = "tool") -> String {
    if let meta = recordValue(update["_meta"]), let tool = recordValue(meta["x.ai/tool"]), let name = nonEmptyString(tool["name"]) {
        return name
    }
    return nonEmptyString(update["name"]) ?? nonEmptyString(update["title"]) ?? fallback
}

private func parseAccumulatedArguments(_ value: String) -> [String: Any]? {
    guard !value.isEmpty, let data = value.data(using: .utf8) else { return [:] }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private func numericUsageAttrs(_ value: Any?) -> [String: Double] {
    guard let source = recordValue(value) else { return [:] }
    let mappings: [(String, String)] = [
        ("inputTokens", "input_tokens"), ("outputTokens", "output_tokens"),
        ("totalTokens", "total_tokens"), ("cachedReadTokens", "cached_read_tokens"),
        ("reasoningTokens", "reasoning_tokens"), ("modelCalls", "model_calls"),
        ("apiDurationMs", "api_duration_ms"), ("numTurns", "num_turns"),
    ]
    var attrs: [String: Double] = [:]
    for (wireKey, attrKey) in mappings {
        if let number = source[wireKey] as? NSNumber, !(source[wireKey] is Bool) {
            attrs[attrKey] = number.doubleValue
        }
    }
    return attrs
}

import Foundation
import Crypto

/// Provider runtime error diagnostics: classify a provider/runtime error into
/// the closed class/reason/action vocabulary, scrub credentials and paths,
/// bound the excerpt, and project activity diagnostics. Ported from the
/// upstream daemon diagnostics module.
public enum RuntimeErrorDiagnostics {
    public static let maxExcerptChars = 4096
    public static let maxVisibleCrashDetailChars = 512

    public struct Envelope: Sendable, Equatable {
        public var turnOutcome = "failed"
        public var turnSubtype = "runtime_error"
        public var turnReason: String
        public var errorClass: String
        public var errorAction: String
        public var actionRequired: Bool
        public var fingerprint: String
        public var messagePresent: Bool
        public var messageLengthBucket: String
        public var messageTruncated: Bool
        public var httpStatus: Int?
        public var estimatedTokens: Int?
        public var budgetTokens: Int?
        public var contextLimitTokens: Int?
        public var requestedTokens: Int?
        public var messageTokens: Int?
        public var completionTokens: Int?
        public var overageTokens: Int?
        public var inputModel: String?
        public var excerpt: String
    }

    public struct ActivityDiagnostic: Sendable, Equatable {
        public var errorClass: String
        public var errorReason: String
        public var fingerprint: String
        public var reasonProvenance: String
        public var nativeReasonPresent: Bool?
        public var requiredAction: String?
        public init(
            errorClass: String, errorReason: String, fingerprint: String,
            reasonProvenance: String = "runtime_error_event",
            nativeReasonPresent: Bool? = nil, requiredAction: String? = nil
        ) {
            self.errorClass = errorClass
            self.errorReason = errorReason
            self.fingerprint = fingerprint
            self.reasonProvenance = reasonProvenance
            self.nativeReasonPresent = nativeReasonPresent
            self.requiredAction = requiredAction
        }
    }

    static let authPatterns: [String] = [
        "(?i)access token could not be refreshed",
        "(?i)\\btoken_(?:revoked|invalidated)\\b",
        "(?i)refresh token was already used",
        "(?i)access token.*invalidated",
        "(?i)authentication token has been invalidated",
        "(?i)logged out or signed in to another account",
        "(?i)not logged in",
        "(?i)not signed in",
        "(?i)login required",
        "(?i)log in first",
        "(?i)please log in",
        "(?i)authentication failed",
        "(?i)auth(?:entication)? failed",
        "(?i)authentication timed out",
        "(?i)missing (?:api )?token",
        "(?i)no (?:api )?token",
        "(?i)missing credentials",
        "(?i)credentials? not found",
        "(?i)invalid api key",
        "(?i)api key (?:is )?not set",
    ]
    static let billingPatterns: [String] = [
        "(?i)\\bpayment required\\b",
        "(?i)\\b(?:usage|credit|account)\\s+balance\\b[^.]*\\b(?:exhausted|depleted|insufficient|too low)\\b",
        "(?i)\\binsufficient\\s+(?:balance|credits?|funds)\\b",
        "(?i)\\b(?:out of|run out of|no remaining)\\s+credits?\\b",
    ]
    static let planAccessPatterns: [String] = [
        "(?i)\\b(?:subscription|plan|tier)\\b[^.\\n]{0,80}\\b(?:does not|doesn't|do not|don't|not)\\b[^.\\n]{0,40}\\b(?:include|allow|support|grant)\\b[^.\\n]{0,40}\\b(?:access|model)\\b",
        "(?i)\\b(?:model|access)\\b[^.\\n]{0,80}\\b(?:not|isn't|is not)\\b[^.\\n]{0,20}\\b(?:included|available|enabled|allowed)\\b[^.\\n]{0,40}\\b(?:subscription|plan|tier)\\b",
    ]
    static let transientLimitPatterns: [String] = [
        "(?i)\\brate.?limit", "(?i)\\btoo many requests\\b", "(?i)\\bconcurrenc(?:y|ies)\\b",
        "(?i)\\bretry(?:ing)?\\b", "(?i)\\btry again\\b", "(?i)\\blater\\b", "(?i)\\bresets?\\b",
        "(?i)\\bper (?:second|minute|hour|day)\\b", "\\b[RT]PM\\b", "(?i)\\bat the moment\\b",
        "(?i)\\bright now\\b", "(?i)\\bat capacity\\b",
    ]
    static let launcherPatterns: [String] = [
        "(?i)\\bunknown command\\b[\\s\\S]*\\b(?:codex|gemini|opencode)\\.(?:js|mjs|cjs)\\b",
    ]

    public static func runtimeDisplayName(_ runtimeId: String) -> String {
        switch runtimeId {
        case "antigravity": return "Antigravity CLI"
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        case "gemini": return "Gemini CLI"
        case "grok": return "Grok Build"
        case "kimi": return "Kimi"
        case "kimi-sdk": return "Kimi SDK"
        case "cursor": return "Cursor"
        case "copilot": return "Copilot"
        case "opencode": return "OpenCode"
        case "pi": return "Pi"
        case "builtin": return "Built-in Pi"
        default: return "This runtime"
        }
    }

    static func matches(_ text: String, _ patterns: [String]) -> Bool {
        patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    static func firstCapture(_ text: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    public static func scrub(_ value: String) -> String {
        var scrubbed = value
        scrubbed = replaceRegex(scrubbed, "(?i)\\bBearer\\s+[A-Za-z0-9._~+/=-]{8,}", "Bearer [REDACTED_TOKEN]")
        scrubbed = replaceRegex(scrubbed, "\\b(?:sk|sk-ant|sk-proj|xox[baprs]?)-[A-Za-z0-9_-]{8,}\\b", "[REDACTED_TOKEN]")
        scrubbed = replaceRegex(scrubbed, "\\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}\\b", "[REDACTED_EMAIL]")
        scrubbed = replaceURLQueries(scrubbed)
        scrubbed = replaceRegex(scrubbed, "/Users/[^\\s\"'<>:]+(?:/[^\\s\"'<>:]+)*", "[REDACTED_PATH]")
        scrubbed = replaceRegex(scrubbed, "/home/[^\\s\"'<>:]+(?:/[^\\s\"'<>:]+)*", "[REDACTED_PATH]")
        scrubbed = replaceRegex(scrubbed, "[A-Za-z]:\\\\Users\\\\[^\\s\"'<>:]+(?:\\\\[^\\s\"'<>:]+)*", "[REDACTED_PATH]")
        // Secret-shaped env/field assignments: keep the key, redact the value.
        scrubbed = replaceRegex(
            scrubbed,
            "\\b([A-Za-z0-9._-]*(?:API[_-]?KEY|SECRET|TOKEN|PASSWORD|PASSWD|ACCESS[_-]?KEY|PRIVATE[_-]?KEY|PRIVKEY|CREDENTIAL)[A-Za-z0-9._-]*)\\s*(?:=|:)\\s*(\"[^\"]*\"|'[^']*'|[^\\s;,\"'<>]+)",
            "$1=[REDACTED_TOKEN]", caseInsensitive: true
        )
        scrubbed = replaceRegex(scrubbed, "\\b(?:password|passwd|secret|token)\\s*[:=]\\s*(\"[^\"]*\"|'[^']*'|[^\\s;,]+)", "[REDACTED_TOKEN]", caseInsensitive: true)
        scrubbed = replaceRegex(scrubbed, "\\b(?:gh[pousr]_|github_pat_)[A-Za-z0-9_]+\\b", "[REDACTED_TOKEN]")
        return scrubbed
    }

    static func replaceURLQueries(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "https?://[^\\s\"'<>]+") else { return text }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)).reversed()
        var result = text
        for match in matches {
            guard let range = Range(match.range, in: result) else { continue }
            let value = String(result[range])
            var redacted = value
            if let queryIndex = value.firstIndex(of: "?") {
                redacted = String(value[..<queryIndex]) + "?[REDACTED_QUERY]"
            }
            result.replaceSubrange(range, with: redacted)
        }
        return result
    }

    static func replaceRegex(_ text: String, _ pattern: String, _ template: String, caseInsensitive: Bool = false) -> String {
        var options: String.CompareOptions = [.regularExpression]
        if caseInsensitive { options.insert(.caseInsensitive) }
        return text.replacingOccurrences(of: pattern, with: template, options: options)
    }

    public static func boundedVisibleCrashDetail(_ raw: String) -> String {
        let scrubbed = scrub(raw)
        return scrubbed.count <= maxVisibleCrashDetailChars ? scrubbed : String(scrubbed.prefix(maxVisibleCrashDetailChars))
    }

    public static func extractHttpStatus(_ message: String) -> Int? {
        for pattern in [
            "(?i)\\b(?:HTTP|status(?:\\s+code)?|API\\s+Error)[:\\s]+([45]\\d{2})\\b",
            "(?i)\\b([45]\\d{2})\\s+(?:Bad Request|Unauthorized|Forbidden|Not Found|Conflict|Too Many Requests|Internal Server Error|Service Unavailable)\\b",
            "\\b([45]\\d{2})\\s*:",
        ] {
            if let value = firstCapture(message, pattern), let status = Int(value) { return status }
        }
        return nil
    }

    static func isPlanAccess(_ text: String) -> Bool {
        if matches(text, transientLimitPatterns) { return false }
        return matches(text, planAccessPatterns)
    }

    public static func isPlanAccessErrorText(_ message: String) -> Bool {
        isPlanAccess(message)
    }

    public static func isBillingErrorText(_ message: String) -> Bool {
        classifyError(message, httpStatus: extractHttpStatus(message)) == "BillingError"
    }

    public static func isInputTooLargeErrorText(_ message: String) -> Bool {
        classifyError(message, httpStatus: extractHttpStatus(message)) == "InputTooLargeError"
    }

    static func classifyError(_ message: String, httpStatus: Int?) -> String {
        if matches(message, launcherPatterns) { return "LauncherError" }
        let explicit = firstCapture(message, "\\b([A-Z][A-Za-z0-9_]*(?:Error|Exception))\\b")
        if let explicit, explicit.range(of: "InputTooLargeError", options: .caseInsensitive) != nil {
            return "InputTooLargeError"
        }
        if let explicit, ["AbortError", "OperationAbortedError"].contains(where: { $0.caseInsensitiveCompare(explicit) == .orderedSame }) {
            return "OperationAbortedError"
        }
        if message.range(of: "(?i)^\\s*(?:this\\s+)?operation was aborted\\.?\\s*$", options: .regularExpression) != nil {
            return "OperationAbortedError"
        }
        if message.range(of: "(?i)\\bINPUT_TOO_LARGE\\b", options: .regularExpression) != nil
            || message.range(of: "(?i)\\binput too large\\b", options: .regularExpression) != nil
            || message.range(of: "(?i)\\bexceeds the maximum allowed\\b", options: .regularExpression) != nil
            || (message.range(of: "(?i)\\bmaximum context length is [\\d,]+ tokens?\\b", options: .regularExpression) != nil
                && message.range(of: "(?i)\\byou requested [\\d,]+ tokens?\\b", options: .regularExpression) != nil) {
            return "InputTooLargeError"
        }
        if httpStatus == 402 || matches(message, billingPatterns) { return "BillingError" }
        if isPlanAccess(message) { return "ModelConfigError" }
        if let explicit { return explicit }
        if let httpStatus {
            switch httpStatus {
            case 429: return "RateLimitError"
            case 401: return "AuthError"
            case 403: return matches(message, authPatterns) ? "AuthError" : "ProviderApiError"
            case 404: return "NotFoundError"
            case 500...: return "ProviderServerError"
            default: return "ProviderApiError"
            }
        }
        if matches(message, authPatterns) { return "AuthError" }
        if message.range(of: "(?i)\\bmodel\\b.*\\bnot supported\\b", options: .regularExpression) != nil
            || message.range(of: "(?i)\\bunsupported\\b.*\\bmodel\\b", options: .regularExpression) != nil
            || message.range(of: "(?i)\\bmodel\\b.*\\bnot available\\b", options: .regularExpression) != nil {
            return "ModelConfigError"
        }
        if message.range(of: "(?i)\\b(?:ETIMEDOUT|timeout|timed out)\\b", options: .regularExpression) != nil {
            return "TimeoutError"
        }
        if message.range(of: "(?i)\\b(?:ECONNRESET|EPIPE|ECONNREFUSED|ENOTFOUND|EAI_AGAIN)\\b", options: .regularExpression) != nil
            || message.range(of: "(?i)\\bUnable to connect to API\\b", options: .regularExpression) != nil {
            return "ProviderConnectionError"
        }
        if message.range(of: "stream closed before response\\.completed|error decoding response body", options: .regularExpression) != nil {
            return "ProviderStreamError"
        }
        if message.range(of: "(?i)\\b(?:selected\\s+)?model\\s+is\\s+at\\s+capacity\\b", options: .regularExpression) != nil {
            return "RateLimitError"
        }
        if message.range(of: "(?i)\\brate.?limit|too many requests\\b", options: .regularExpression) != nil {
            return "RateLimitError"
        }
        if message.range(of: "(?i)\\bnot found\\b", options: .regularExpression) != nil {
            return "NotFoundError"
        }
        return "RuntimeError"
    }

    public static func reason(for errorClass: String) -> String {
        switch errorClass {
        case "ProviderConnectionError": return "provider_connection_error"
        case "TimeoutError": return "provider_timeout"
        case "ProviderStreamError": return "provider_stream_error"
        case "RateLimitError": return "rate_limited"
        case "AuthError": return "auth_failed"
        case "LauncherError": return "launcher_error"
        case "NotFoundError": return "not_found"
        case "ModelConfigError": return "model_config_error"
        case "InputTooLargeError": return "input_too_large"
        case "ProviderServerError": return "provider_server_error"
        case "ProviderApiError": return "provider_api_error"
        case "OperationAbortedError": return "operation_aborted"
        case "BillingError": return "billing_exhausted"
        default: return "unclassified_runtime_error"
        }
    }

    public static func action(for errorClass: String, message: String) -> String {
        if errorClass == "AuthError" { return "user_reauth" }
        if errorClass == "ModelConfigError", isPlanAccess(message) { return "user_model_access" }
        return "none"
    }

    static func integers(_ message: String, patterns: [String]) -> Int? {
        for pattern in patterns {
            if let raw = firstCapture(message, pattern) {
                let digits = raw.replacingOccurrences(of: ",", with: "")
                if let value = Int(digits) { return value }
            }
        }
        return nil
    }

    static func fingerprint(_ value: String) -> String {
        let normalized = value.lowercased()
            .replacingOccurrences(of: "[0-9a-f]{12,}", with: "<hex>", options: .regularExpression)
            .replacingOccurrences(of: "\\b\\d+\\b", with: "<num>", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    static func bucketLength(_ length: Int) -> String {
        if length == 0 { return "0" }
        if length < 1024 { return "<1k" }
        if length < 4096 { return "1k-4k" }
        if length < 16384 { return "4k-16k" }
        return "16k+"
    }

    public static func buildEnvelope(_ message: String) -> Envelope {
        let rawMessage = message
        let scrubbed = scrub(rawMessage)
        let truncated = scrubbed.count > maxExcerptChars
        let excerpt = truncated ? String(scrubbed.prefix(maxExcerptChars)) : scrubbed
        let httpStatus = extractHttpStatus(rawMessage)
        let errorClass = classifyError(rawMessage, httpStatus: httpStatus)
        let errorReason = reason(for: errorClass)
        let errorAction = action(for: errorClass, message: rawMessage)
        var attrs = Envelope(
            turnReason: errorReason, errorClass: errorClass, errorAction: errorAction,
            actionRequired: errorAction != "none", fingerprint: fingerprint(scrubbed),
            messagePresent: !rawMessage.isEmpty, messageLengthBucket: bucketLength(rawMessage.count),
            messageTruncated: truncated, httpStatus: httpStatus, excerpt: excerpt
        )
        if errorClass == "InputTooLargeError" {
            attrs.estimatedTokens = integers(rawMessage, patterns: ["(?i)\\bestimated\\s+([\\d,]+)\\s+tokens?\\b"])
            attrs.budgetTokens = integers(rawMessage, patterns: ["(?i)\\bbudget\\s+([\\d,]+)\\b"])
            attrs.contextLimitTokens = integers(rawMessage, patterns: [
                "(?i)\\bcontext limit\\s+([\\d,]+)\\b",
                "(?i)\\bmaximum allowed[^()]*\\(([\\d,]+)\\)",
                "(?i)\\bmaximum context length is\\s+([\\d,]+)\\s+tokens?\\b",
            ])
            attrs.requestedTokens = integers(rawMessage, patterns: ["(?i)\\byou requested\\s+([\\d,]+)\\s+tokens?\\b"])
            attrs.messageTokens = integers(rawMessage, patterns: ["\\(([\\d,]+)\\s+in the messages?\\b"])
            attrs.completionTokens = integers(rawMessage, patterns: ["(?i)\\b([\\d,]+)\\s+in the completion\\b"])
            if let contextLimit = attrs.contextLimitTokens, let requested = attrs.requestedTokens, requested > contextLimit {
                attrs.overageTokens = requested - contextLimit
            }
            attrs.inputModel = firstCapture(rawMessage, "(?i)\\bmodel\\s+([A-Za-z0-9._:/+-]+)\\b")
        }
        return attrs
    }

    static func normalizedClass(_ value: String?) -> String {
        guard let value else { return "RuntimeError" }
        switch value {
        case "InputTooLargeError", "RateLimitError", "AuthError", "LauncherError", "NotFoundError",
             "ModelConfigError", "TimeoutError", "ProviderConnectionError", "ProviderStreamError",
             "ProviderServerError", "ProviderApiError", "OperationAbortedError", "BillingError":
            return value
        default:
            return "RuntimeError"
        }
    }

    static func normalizedReason(_ value: String?) -> String {
        guard let value else { return "unclassified_runtime_error" }
        switch value {
        case "input_too_large", "rate_limited", "auth_failed", "launcher_error", "not_found",
             "model_config_error", "provider_timeout", "provider_connection_error", "provider_stream_error",
             "provider_server_error", "provider_api_error", "operation_aborted", "billing_exhausted":
            return value
        default:
            return "unclassified_runtime_error"
        }
    }

    public static func buildActivityDiagnostic(
        _ message: String, nativeReasonPresent: Bool? = nil,
        reasonProvenance: String? = nil, errorClass: String? = nil
    ) -> ActivityDiagnostic {
        let envelope = buildEnvelope(message)
        let resolvedClass = errorClass ?? normalizedClass(envelope.errorClass)
        let requiredAction = action(for: resolvedClass, message: message)
        let resolvedReason = errorClass != nil ? reason(for: errorClass!) : normalizedReason(envelope.turnReason)
        return ActivityDiagnostic(
            errorClass: resolvedClass, errorReason: resolvedReason,
            fingerprint: envelope.fingerprint,
            reasonProvenance: reasonProvenance ?? "runtime_error_event",
            nativeReasonPresent: nativeReasonPresent,
            requiredAction: requiredAction != "none" ? requiredAction : nil
        )
    }

    public static func formatLoginRequired(_ runtimeId: String) -> String {
        if runtimeId == "builtin" {
            return "Built-in provider authentication failed. Check this agent's provider API key and region/provider selection, then retry starting this agent."
        }
        if runtimeId == "pi" {
            return "Pi's model provider rejected the API key, or no key is set for it on this machine. Check the API key for this agent's provider, then retry starting this agent."
        }
        let label = runtimeDisplayName(runtimeId)
        return "\(label) is not logged in on this machine. Please log in to \(label) locally, then retry starting this agent."
    }

    public static func formatStartTimeout(_ runtimeId: String) -> String {
        let label = runtimeDisplayName(runtimeId)
        return "\(label) did not finish starting on this machine. Check that \(label) is installed, logged in, and can run non-interactively, then retry starting this agent."
    }

    public static func formatResetSessionGuidance() -> String {
        "To start a new session, someone who can manage this agent can open Restart / Reset and choose Reset Session & Restart "
            + "(shown as Reset Model for members). This stops current work and clears the runtime conversation context, "
            + "while keeping Raft messages and workspace files, including MEMORY.md."
    }

    public static func needsResetSessionGuidance(_ runtimeId: String) -> Bool {
        ["grok", "pi", "builtin"].contains(runtimeId)
    }

    public static func formatInputTooLarge(_ runtimeId: String) -> String {
        let label = runtimeDisplayName(runtimeId)
        if needsResetSessionGuidance(runtimeId) {
            return "\(label) reported input that is too large for the selected model. Restart keeps the existing session. "
                + "\(formatResetSessionGuidance()) "
                + "If the error persists in a new session, reduce the prompt or configured startup context."
        }
        return "\(label) reported input that is too large for the selected model. Reduce the current prompt or injected startup context. For a resumed session, compact it or start a new session before retrying."
    }

    public static func formatBillingExhausted(_ runtimeId: String) -> String {
        let label = runtimeDisplayName(runtimeId)
        return "\(label) reported that the provider's billing or credit balance is exhausted. Raft stopped retrying because retries cannot succeed until the balance is restored. Messages that were waiting are kept and will be delivered when the agent starts again. Add credits or switch this agent to another model or provider, then restart the agent."
    }

    public static func formatPlanAccess(_ runtimeId: String, model: String? = nil) -> String {
        let label = runtimeDisplayName(runtimeId)
        let trimmed = model?.trimmingCharacters(in: .whitespaces) ?? ""
        let modelLabel = trimmed.isEmpty ? "" : " (\(trimmed))"
        return "\(label) reported that the provider plan for this agent does not include access to the configured model\(modelLabel). Raft stopped retrying because retries cannot succeed until the model or the plan changes. Switch this agent to a model the plan includes, or upgrade the plan, then retry starting this agent."
    }
}

import Foundation
import Testing
import RaftDaemonClient

private func envelope(_ message: String) -> RuntimeErrorDiagnostics.Envelope {
    RuntimeErrorDiagnostics.buildEnvelope(message)
}

@Test func classifiesAndBoundsProviderErrors() {
    let value = envelope("API Error: 400 Bad Request: Improperly formed request in /Users/alice/project/session.jsonl")
    #expect(value.errorClass == "ProviderApiError")
    #expect(value.httpStatus == 400)
    #expect(value.messagePresent)
    #expect(value.messageLengthBucket == "<1k")
    #expect(!value.messageTruncated)
    #expect(!value.fingerprint.isEmpty)
    #expect(value.excerpt == "API Error: 400 Bad Request: Improperly formed request in [REDACTED_PATH]")
}

@Test func keepsGeneric403ResponsesOutOfUserReauth() {
    for message in ["API Error: 403 Request not allowed", "unexpected status 403 Forbidden"] {
        let value = envelope(message)
        #expect(value.errorClass == "ProviderApiError")
        #expect(value.turnReason == "provider_api_error")
        #expect(value.httpStatus == 403)
        #expect(value.errorAction == "none")
        #expect(!value.actionRequired)
    }
}

@Test func reserves403UserReauthForExplicitAuthEvidence() {
    for message in ["API Error: 403 Forbidden: invalid api key", "API Error: 403 Authentication failed: please log in"] {
        let value = envelope(message)
        #expect(value.errorClass == "AuthError")
        #expect(value.turnReason == "auth_failed")
        #expect(value.httpStatus == 403)
        #expect(value.errorAction == "user_reauth")
        #expect(value.actionRequired)
    }
}

@Test func redactsSecretsAndTruncatesLongMessages() {
    let value = envelope([
        "ProviderModelNotFoundError: failed with Bearer abcdefghijklmnopqrstuvwxyz",
        "key sk-ant-1234567890abcdef",
        "email user@example.com",
        "url https://example.com/v1?api_key=secret",
        "body",
        String(repeating: "x", count: 5000),
    ].joined(separator: " "))
    #expect(value.errorClass == "ProviderModelNotFoundError")
    #expect(value.turnReason == "unclassified_runtime_error")
    #expect(value.messageLengthBucket == "4k-16k")
    #expect(value.messageTruncated)
    #expect(value.excerpt.count == 4096)
    #expect(!value.excerpt.contains("abcdefghijklmnopqrstuvwxyz"))
    #expect(!value.excerpt.contains("sk-ant-1234567890abcdef"))
    #expect(!value.excerpt.contains("user@example.com"))
    #expect(value.excerpt.contains("Bearer [REDACTED_TOKEN]"))
    #expect(value.excerpt.contains("[REDACTED_EMAIL]"))
    #expect(value.excerpt.contains("[REDACTED_QUERY]"))
}

@Test func detoxesPoisonedStderr() {
    let ghpToken = "gh" + "p_abcdefghijklmnopqrstuvwxyz0123456789"
    let poisoned = [
        "Error: ANTHROPIC_API_KEY=sk-ant-api03-this-is-a-long-secret-value-1234567890",
        "AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        "OPENAI_API_KEY=sk-abcdef0123456789abcdef0123456789",
        ghpToken,
        "github" + "_pat_11ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmNO",
        "connection password=hunter2 sentinel",
        "NODE_ENV=production must survive",
        "API Error: 500 Internal Server Error upstream",
    ].joined(separator: "\n")
    let value = envelope(poisoned)
    let excerpt = value.excerpt
    #expect(!excerpt.contains("sk-ant-api03-this-is-a-long-secret-value-1234567890"))
    #expect(!excerpt.contains("wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"))
    #expect(!excerpt.contains("sk-abcdef0123456789abcdef0123456789"))
    #expect(!excerpt.contains(ghpToken))
    #expect(!excerpt.contains("11ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmNO"))
    #expect(!excerpt.contains("hunter2"))
    #expect(excerpt.range(of: "ANTHROPIC_API_KEY\\s*=\\s*\\[REDACTED_TOKEN\\]", options: .regularExpression) != nil)
    #expect(excerpt.range(of: "AWS_SECRET_ACCESS_KEY\\s*=\\s*\\[REDACTED_TOKEN\\]", options: .regularExpression) != nil)
    #expect(excerpt.range(of: "OPENAI_API_KEY\\s*=\\s*\\[REDACTED_TOKEN\\]", options: .regularExpression) != nil)
    #expect(excerpt.contains("NODE_ENV=production"))
    #expect(!excerpt.contains("ghp_"))
    #expect(!excerpt.contains("github_pat_"))
    #expect(value.errorClass == "ProviderServerError")
    #expect(value.httpStatus == 500)
}

@Test func classifiesProviderStreamFailures() {
    let closed = envelope("stream closed before response.completed")
    #expect(closed.errorClass == "ProviderStreamError")
    #expect(closed.turnReason == "provider_stream_error")
    let decoding = envelope("error decoding response body")
    #expect(decoding.errorClass == "ProviderStreamError")
}

@Test func activityDiagnosticPreservesExactCompactionFailureClasses() {
    let providerFailure = RuntimeErrorDiagnostics.buildActivityDiagnostic("Compaction failed: 503: synthetic upstream unavailable")
    #expect(providerFailure.errorClass == "ProviderServerError")
    #expect(providerFailure.errorReason == "provider_server_error")
    #expect(providerFailure.fingerprint.range(of: "^[0-9a-f]{16}$", options: .regularExpression) != nil)
    #expect(!String(describing: providerFailure).contains("synthetic upstream"))
    let aborted = RuntimeErrorDiagnostics.buildActivityDiagnostic("This operation was aborted")
    #expect(aborted.errorClass == "OperationAbortedError")
    #expect(aborted.errorReason == "operation_aborted")
}

@Test func activityDiagnosticReportsOwnerActionInTheSameTerms() {
    let credential = RuntimeErrorDiagnostics.buildActivityDiagnostic("Authentication failed: missing API token")
    #expect(credential.errorClass == "AuthError")
    #expect(credential.requiredAction == "user_reauth")
    #expect(envelope("Authentication failed: missing API token").errorAction == credential.requiredAction)
    for text in ["Selected model is at capacity. Please try a different model.", "Compaction failed: 503: synthetic upstream unavailable"] {
        #expect(RuntimeErrorDiagnostics.buildActivityDiagnostic(text).requiredAction == nil)
    }
}

@Test func treatsProviderCapacityAsRecoverableRateLimiting() {
    let capacity = envelope("Selected model is at capacity. Please try a different model.")
    #expect(capacity.errorClass == "RateLimitError")
    #expect(capacity.turnReason == "rate_limited")
    #expect(!capacity.actionRequired)
    let credential = envelope("Authentication failed: missing API token")
    #expect(credential.errorClass == "AuthError")
    #expect(credential.actionRequired)
}

@Test func classifiesLocalStartupPayloadAndObservedProviderLimits() {
    let local = envelope("INPUT_TOO_LARGE: Claude daemon-owned startup payload is too large before command launch (estimated 1052777 tokens, budget 968000, context limit 1000000, model claude-fable-5).")
    #expect(local.errorClass == "InputTooLargeError")
    #expect(local.turnReason == "input_too_large")
    #expect(!local.actionRequired)
    #expect(local.estimatedTokens == 1_052_777)
    #expect(local.budgetTokens == 968_000)
    #expect(local.contextLimitTokens == 1_000_000)
    #expect(local.inputModel == "claude-fable-5")

    let provider = envelope("API Error: 400 Invalid request: Input too large: estimated 1052777 tokens exceeds the maximum allowed for model claude-fable-5 (1000000).")
    #expect(provider.errorClass == "InputTooLargeError")
    #expect(provider.httpStatus == 400)
    #expect(provider.estimatedTokens == 1_052_777)
    #expect(provider.contextLimitTokens == 1_000_000)
    #expect(provider.inputModel == "claude-fable-5")
}

@Test func classifiesAnthropicMaximumContextAndExtractsTokenAccounting() {
    let value = envelope("API Error: 400 {\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"This model's maximum context length is 1,048,565 tokens. However, you requested 1,048,925 tokens (1,016,925 in the messages, 32,000 in the completion). Please reduce the length of the messages or completion.\"}}")
    #expect(value.errorClass == "InputTooLargeError")
    #expect(value.turnReason == "input_too_large")
    #expect(value.httpStatus == 400)
    #expect(value.errorAction == "none")
    #expect(value.contextLimitTokens == 1_048_565)
    #expect(value.requestedTokens == 1_048_925)
    #expect(value.messageTokens == 1_016_925)
    #expect(value.completionTokens == 32_000)
    #expect(value.overageTokens == 360)
}

@Test func classifiesCodexOAuthInvalidationAsAuthErrors() {
    for message in [
        "Your access token could not be refreshed because your refresh token was already used. Please log out and sign in again.",
        "unexpected status 401: Your authentication token has been invalidated.",
        "codex_models_manager::manager failed against chatgpt.com: token_revoked",
    ] {
        let value = envelope(message)
        #expect(value.errorClass == "AuthError")
        #expect(value.turnReason == "auth_failed")
        #expect(value.errorAction == "user_reauth")
        #expect(value.actionRequired)
    }
}

@Test func keepsCodexLauncherFailuresOutOfAuthRequiredProjection() {
    let message = #"unknown command 'C:\Users\bot\AppData\Roaming\npm\node_modules\@openai\codex\bin\codex.js': Failed to authenticate because the access token could not be refreshed"#
    let value = envelope(message)
    #expect(value.errorClass == "LauncherError")
    #expect(value.turnReason == "launcher_error")
    #expect(value.errorAction == "none")
    #expect(!value.actionRequired)
    let activity = RuntimeErrorDiagnostics.buildActivityDiagnostic(message)
    #expect(activity == .init(
        errorClass: "LauncherError", errorReason: "launcher_error",
        fingerprint: value.fingerprint, reasonProvenance: "runtime_error_event",
        nativeReasonPresent: nil, requiredAction: nil
    ))
}

@Test func classifiesCodexModelAccountIncompatibility() {
    let value = envelope("The 'gpt-5.3-codex' model is not supported when using Codex with a ChatGPT account.")
    #expect(value.errorClass == "ModelConfigError")
    #expect(value.turnReason == "model_config_error")
    #expect(value.errorAction == "none")
    #expect(!value.actionRequired)
}

@Test func classifiesLoginRequiredRuntimeFailuresAsAuthAction() {
    for message in [
        "Antigravity CLI is not logged in. Please log in first.",
        "Authentication failed: missing API token",
        "API Error: 401 Unauthorized",
    ] {
        let value = envelope(message)
        #expect(value.errorClass == "AuthError")
        #expect(value.turnReason == "auth_failed")
        #expect(value.errorAction == "user_reauth")
        #expect(value.actionRequired)
    }
}

@Test func classifiesProviderConnectionFailures() {
    let reset = envelope("API Error: Unable to connect to API (ECONNRESET)")
    #expect(reset.errorClass == "ProviderConnectionError")
    #expect(reset.turnOutcome == "failed")
    #expect(reset.turnSubtype == "runtime_error")
    #expect(reset.turnReason == "provider_connection_error")
    let refused = envelope("API Error: request failed with ECONNREFUSED")
    #expect(refused.errorClass == "ProviderConnectionError")
}

@Test func classifiesProviderTimeoutCodes() {
    let value = envelope("API Error: model request failed with ETIMEDOUT")
    #expect(value.errorClass == "TimeoutError")
    #expect(value.turnReason == "provider_timeout")
}

@Test func loginRequiredMessageGivesActionOrientedCopy() {
    #expect(RuntimeErrorDiagnostics.formatLoginRequired("antigravity") == "Antigravity CLI is not logged in on this machine. Please log in to Antigravity CLI locally, then retry starting this agent.")
    #expect(RuntimeErrorDiagnostics.formatLoginRequired("claude") == "Claude Code is not logged in on this machine. Please log in to Claude Code locally, then retry starting this agent.")
    #expect(RuntimeErrorDiagnostics.formatLoginRequired("pi") == "Pi's model provider rejected the API key, or no key is set for it on this machine. Check the API key for this agent's provider, then retry starting this agent.")
    #expect(RuntimeErrorDiagnostics.formatLoginRequired("builtin") == "Built-in provider authentication failed. Check this agent's provider API key and region/provider selection, then retry starting this agent.")
}

@Test func startTimeoutMessageGivesBoundedStartupGuidance() {
    #expect(RuntimeErrorDiagnostics.formatStartTimeout("gemini") == "Gemini CLI did not finish starting on this machine. Check that Gemini CLI is installed, logged in, and can run non-interactively, then retry starting this agent.")
}

@Test func grokInputTooLargeMessageNamesTheNewSessionControl() {
    let message = RuntimeErrorDiagnostics.formatInputTooLarge("grok")
    #expect(message == "Grok Build reported input that is too large for the selected model. Restart keeps the existing session. To start a new session, someone who can manage this agent can open Restart / Reset and choose Reset Session & Restart (shown as Reset Model for members). This stops current work and clears the runtime conversation context, while keeping Raft messages and workspace files, including MEMORY.md. If the error persists in a new session, reduce the prompt or configured startup context.")
    #expect(message.range(of: "(?i)compact") == nil)
    #expect(message.hasPrefix("Grok Build reported input that is too large for the selected model."))
    #expect(message.contains("Restart keeps the existing session."))
    #expect(message.contains("open Restart / Reset and choose Reset Session & Restart (shown as Reset Model for members)"))
    #expect(message.contains("keeping Raft messages and workspace files, including MEMORY.md"))
}

@Test func piAndBuiltinAlsoNameResetSessionRestart() {
    for (runtime, label) in [("pi", "Pi"), ("builtin", "Built-in Pi")] {
        let message = RuntimeErrorDiagnostics.formatInputTooLarge(runtime)
        #expect(message.range(of: "(?i)compact") == nil, "\(runtime)")
        #expect(message.hasPrefix("\(label) reported input that is too large for the selected model. Restart keeps the existing session. "), "\(message)")
        #expect(message.contains("open Restart / Reset and choose Reset Session & Restart (shown as Reset Model for members)"))
    }
}

@Test func otherRuntimesKeepGenericInputTooLargeText() {
    for runtime in ["claude", "codex", "kimi", "gemini", "opencode"] {
        let message = RuntimeErrorDiagnostics.formatInputTooLarge(runtime)
        #expect(message.hasSuffix("For a resumed session, compact it or start a new session before retrying."), "\(runtime)")
        #expect(!message.contains("Reset Session & Restart"))
    }
}

@Test func inputTooLargeMessageGivesBoundedActionGuidance() {
    #expect(RuntimeErrorDiagnostics.formatInputTooLarge("claude") == "Claude Code reported input that is too large for the selected model. Reduce the current prompt or injected startup context. For a resumed session, compact it or start a new session before retrying.")
}

@Test func classifiesBillingExhaustionAsBillingError() {
    for message in [
        "402 Grok Build usage balance exhausted", "HTTP 402: usage balance exhausted",
        "API Error: 402 Payment Required", "Request failed: insufficient credits for this request",
        "Your credit balance is too low to access the API",
    ] {
        let value = envelope(message)
        #expect(value.errorClass == "BillingError", "\(message)")
        #expect(value.turnReason == "billing_exhausted")
        #expect(!value.actionRequired)
        #expect(RuntimeErrorDiagnostics.buildActivityDiagnostic(message).errorReason == "billing_exhausted")
    }
}

@Test func billingClassificationLeavesQuotaAndRateLimitWordingAlone() {
    #expect(envelope("You've hit your usage limit. Upgrade your plan or try again later.").errorClass != "BillingError")
    #expect(envelope("API Error: 429 Too Many Requests").errorClass == "RateLimitError")
    #expect(envelope("API Error: 400 Bad Request: bad input").errorClass == "ProviderApiError")
}

@Test func billingExhaustedMessageNamesBillingAndKeepsWaitingMessages() {
    let message = RuntimeErrorDiagnostics.formatBillingExhausted("grok")
    #expect(message.contains("billing or credit balance is exhausted"))
    #expect(message.contains("kept and will be delivered"))
    #expect(message.range(of: "(?i)too large") == nil)
}

@Test func planWithoutModelIsActionRequiredAndPlain429sAndTimeoutsAreNot() {
    for message in [
        "429: {\"code\":\"1311\",\"message\":\"Your current subscription plan does not yet include access to GLM-5.3-Highspeed\"}",
        "HTTP 403: Your plan does not include the model gpt-5-pro",
        "Model claude-opus-5-5 is not available on your current subscription tier",
    ] {
        let value = envelope(message)
        #expect(RuntimeErrorDiagnostics.isPlanAccessErrorText(message), "\(message)")
        #expect(value.errorClass == "ModelConfigError", "\(message)")
        #expect(value.errorAction == "user_model_access", "\(message)")
        #expect(value.actionRequired, "\(message)")
        #expect(RuntimeErrorDiagnostics.buildActivityDiagnostic(message).errorReason == "model_config_error")
    }
    #expect(envelope("429: {\"code\":\"1311\",\"message\":\"Your current subscription plan does not yet include access to GLM-5.3-Highspeed\"}").httpStatus == 429)
    for message in [
        "API Error: 429 Too Many Requests", "429: rate limit exceeded, retry after 30s",
        "429: {\"code\":\"1302\",\"message\":\"High concurrency usage, please try again later\"}",
        "The selected model is at capacity, please try again later",
    ] {
        let value = envelope(message)
        #expect(!RuntimeErrorDiagnostics.isPlanAccessErrorText(message), "\(message)")
        #expect(value.errorClass == "RateLimitError", "\(message)")
        #expect(value.errorAction == "none")
        #expect(!value.actionRequired)
    }
    for message in [
        "429 Your current plan does not support more requests to this model right now, please retry later",
        "429 Too many requests: concurrency for this model is not available on the free tier at the moment, retry in 30s",
        "Rate limit exceeded for model gpt-5: requests are not allowed on your plan until the window resets",
    ] {
        let value = envelope(message)
        #expect(!RuntimeErrorDiagnostics.isPlanAccessErrorText(message), "\(message)")
        #expect(value.errorClass != "ModelConfigError", "\(message)")
        #expect(value.errorAction == "none")
        #expect(!value.actionRequired)
    }
    #expect(envelope("429 Too many requests: concurrency for this model is not available on the free tier at the moment, retry in 30s").errorClass == "RateLimitError")
    for message in ["Request timed out.", "ETIMEDOUT", "request timeout after 60000ms"] {
        let value = envelope(message)
        #expect(!RuntimeErrorDiagnostics.isPlanAccessErrorText(message))
        #expect(value.errorClass == "TimeoutError", "\(message)")
        #expect(value.errorAction == "none")
    }
    #expect(envelope("Authentication failed: missing API token").errorAction == "user_reauth")
    #expect(!envelope("You've hit your usage limit. Upgrade your plan or try again later.").actionRequired)
    let unsupported = envelope("model gpt-99 is not supported by this runtime")
    #expect(unsupported.errorClass == "ModelConfigError")
    #expect(!unsupported.actionRequired)
}

@Test func planAccessMessageNamesThePlanAndModel() {
    let message = RuntimeErrorDiagnostics.formatPlanAccess("builtin", model: "glm-5.3-highspeed")
    #expect(message.contains("provider plan for this agent does not include access to the configured model (glm-5.3-highspeed)"))
    #expect(message.contains("Switch this agent to a model the plan includes, or upgrade the plan, then retry starting this agent."))
    #expect(message.range(of: "(?i)log in") == nil)
    #expect(!RuntimeErrorDiagnostics.formatPlanAccess("codex", model: nil).contains("()"))
}

@Test func inputAndBillingPredicatesMatchClassification() {
    #expect(RuntimeErrorDiagnostics.isInputTooLargeErrorText("INPUT_TOO_LARGE: payload too big"))
    #expect(!RuntimeErrorDiagnostics.isInputTooLargeErrorText("API Error: 429 Too Many Requests"))
    #expect(RuntimeErrorDiagnostics.isBillingErrorText("API Error: 402 Payment Required"))
    #expect(!RuntimeErrorDiagnostics.isBillingErrorText("You've hit your usage limit. Upgrade your plan or try again later."))
}

@Test func boundedVisibleCrashDetailScrubsAndCaps() {
    let detail = RuntimeErrorDiagnostics.boundedVisibleCrashDetail("Bearer abcdefghijklmnopqrstuvwxyz " + String(repeating: "y", count: 1000))
    #expect(!detail.contains("abcdefghijklmnopqrstuvwxyz"))
    #expect(detail.count <= RuntimeErrorDiagnostics.maxVisibleCrashDetailChars)
}

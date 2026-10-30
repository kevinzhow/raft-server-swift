import Foundation

/// Failure projection from `packages/daemon/src/proxyFailureTrace.ts`.
/// The trace keeps a route family and a canned excerpt. It does not keep
/// the pathname query, the error text, or any lifecycle identifier.

public struct DaemonProxyFailureInput: Sendable {
    public var method: String
    public var pathname: String
    public var errorName: String
    public var errorMessage: String
    public var errorCause: String?
    public var causeCode: String?
    public var failureClass: String?
    public var lifecycleInvalidContext: String?
    public var responseStarted: Bool?
    public var responseComplete: Bool?
    public var responseStatusCode: Int?
    public var responseCode: String?

    public init(
        method: String,
        pathname: String,
        errorName: String,
        errorMessage: String,
        errorCause: String? = nil,
        causeCode: String? = nil,
        failureClass: String? = nil,
        lifecycleInvalidContext: String? = nil,
        responseStarted: Bool? = nil,
        responseComplete: Bool? = nil,
        responseStatusCode: Int? = nil,
        responseCode: String? = nil
    ) {
        self.method = method
        self.pathname = pathname
        self.errorName = errorName
        self.errorMessage = errorMessage
        self.errorCause = errorCause
        self.causeCode = causeCode
        self.failureClass = failureClass
        self.lifecycleInvalidContext = lifecycleInvalidContext
        self.responseStarted = responseStarted
        self.responseComplete = responseComplete
        self.responseStatusCode = responseStatusCode
        self.responseCode = responseCode
    }
}

public enum DaemonProxyAttr: Equatable, Sendable {
    case string(String)
    case bool(Bool)
    case int(Int)
}

public struct DaemonProxyTransportError: Sendable {
    public var normalizedCode: String
    public var upstreamLayer: String

    public init(normalizedCode: String, upstreamLayer: String) {
        self.normalizedCode = normalizedCode
        self.upstreamLayer = upstreamLayer
    }
}

public enum DaemonProxyFailure {
    public static func traceAttributes(_ input: DaemonProxyFailureInput) -> [String: DaemonProxyAttr] {
        let reason = failureReason(input)
        var attributes: [String: DaemonProxyAttr] = [
            "route_family": .string(routeFamily(for: input.pathname)),
            "method": .string(boundedMethod(input.method)),
            "outcome": .string("error"),
            "reason": .string(reason),
            "error_class": .string(boundedErrorClass(input.errorName)),
            "error_excerpt": .string(cannedExcerpt(reason)),
        ]
        if let failureClass = input.failureClass, !failureClass.isEmpty {
            attributes["failure_class"] = .string(failureClass)
        }
        if let responseStarted = input.responseStarted {
            attributes["response_started"] = .bool(responseStarted)
        }
        if let responseComplete = input.responseComplete {
            attributes["response_complete"] = .bool(responseComplete)
        }
        if let causeCode = input.causeCode, !causeCode.isEmpty {
            attributes["cause_code"] = .string(causeCode)
        }
        if let responseStatusCode = input.responseStatusCode {
            attributes["response_status_code"] = .int(responseStatusCode)
        }
        attributes["response_code_present"] = .bool(input.responseCode.map { !$0.isEmpty } ?? false)
        return attributes
    }

    public static func transportExcerpt(_ input: DaemonProxyTransportError) -> String {
        if input.normalizedCode == "local_daemon_state_invalid" {
            return "Local daemon lifecycle state rejected the proxy request"
        }
        if input.normalizedCode == "local_post_response_failure" {
            return "Local daemon failed after the upstream response completed"
        }
        if input.normalizedCode == "server_5xx" {
            return "Upstream server returned a 5xx response"
        }
        switch input.upstreamLayer {
        case "dns": return "Upstream DNS resolution failed"
        case "tcp": return "Upstream TCP connection failed"
        case "tls": return "Upstream TLS negotiation failed"
        case "read_timeout": return "Upstream response timed out"
        case "proxy_connect": return "Upstream proxy connection failed"
        case "fly_edge": return "Upstream edge transport failed"
        case "body_decode_failure": return "Upstream response body could not be decoded"
        case "http_status": return "Upstream HTTP request failed"
        default: return "Proxy transport failed with an unclassified cause"
        }
    }

    public static func jsonText(_ attributes: [String: DaemonProxyAttr]) -> String {
        let keys = [
            "route_family", "method", "outcome", "reason", "error_class", "error_excerpt",
            "failure_class", "response_started", "response_complete", "cause_code",
            "response_status_code", "response_code_present",
        ]
        var parts: [String] = []
        for key in keys {
            guard let value = attributes[key] else { continue }
            parts.append("\(jsonString(key)):\(jsonAttr(value))")
        }
        return "{\(parts.joined(separator: ","))}"
    }
}

public func routeFamily(for pathname: String) -> String {
    if pathname == "/internal/agent-api/runtime-version" { return "runtime-version" }
    if pathname == "/internal/agent-api/v2/send" || pathname == "/internal/agent-api/send" { return "agent-api/send" }
    if pathname == "/internal/agent-api/events" || pathname == "/internal/agent-api/receive-ack" { return "agent-api/events" }
    if pathname == "/internal/agent-api/inbox" || pathname.hasPrefix("/internal/agent-api/inbox/") { return "agent-api/inbox" }
    if pathname == "/internal/agent-api/tasks/claim" { return "tasks/claim" }
    if pathname == "/internal/agent-api/tasks/update-status" { return "tasks/update" }
    if pathname == "/internal/agent-api/tasks" || pathname.hasPrefix("/internal/agent-api/tasks/") { return "tasks" }
    if pathname.firstMatch(of: /^\/internal\/agent-api\/attachments\/[^\/]+\/comments/) != nil {
        return "agent-api/attachments/comments"
    }
    if pathname.hasPrefix("/internal/agent-api/attachments/") { return "agent-api/attachments" }
    if pathname.wholeMatch(of: /^\/internal\/agent-api\/messages\/[^\/]+\/resolve$/) != nil { return "agent-api/messages/resolve" }
    if pathname.wholeMatch(of: /^\/internal\/agent-api\/messages\/[^\/]+\/reactions$/) != nil {
        return "agent-api/messages/reactions"
    }
    if pathname == "/internal/agent-api/server" { return "server" }
    if pathname.hasPrefix("/internal/agent-api/history") || pathname.hasPrefix("/internal/agent-api/search") {
        return "agent-api/events"
    }
    if pathname.hasPrefix("/internal/agent-api/channel-members") { return "channel-members" }
    if pathname.hasPrefix("/internal/agent-api/knowledge") { return "knowledge" }
    if pathname == "/internal/agent-api/profile" || pathname.hasPrefix("/internal/agent-api/profile/") { return "profile" }
    if pathname == "/internal/agent-api/integrations" || pathname.hasPrefix("/internal/agent-api/integrations/") {
        return "integrations"
    }
    if pathname == "/internal/agent-api/upload" { return "attachments/upload" }
    if pathname == "/internal/agent-api/resolve-channel" { return "resolve-channel" }
    if pathname == "/internal/agent-api/threads" { return "threads" }
    if pathname == "/internal/agent-api/threads/unfollow" { return "threads/unfollow" }
    if pathname == "/internal/agent-api/prepare-action" { return "action/prepare" }
    if pathname == "/internal/agent-api/reminders" || pathname.hasPrefix("/internal/agent-api/reminders/") { return "reminders" }
    if pathname.wholeMatch(of: /^\/internal\/agent-api\/channels\/[^\/]+\/join$/) != nil { return "channels/join" }
    if pathname.wholeMatch(of: /^\/internal\/agent-api\/channels\/[^\/]+\/leave$/) != nil { return "channels/leave" }
    return "unknown"
}

private func failureReason(_ input: DaemonProxyFailureInput) -> String {
    if let context = input.lifecycleInvalidContext, !context.isEmpty { return "local_daemon_state_invalid" }
    if input.failureClass == "post_response_local" { return "local_post_response" }
    let causeCode = (input.causeCode ?? "").uppercased()
    let text = "\(input.errorCause ?? "") \(input.errorMessage)".lowercased()
    if text.wholeMatch(of: /(?s).*?(?:enotfound|eai_again|\bdns\b).*/) != nil { return "dns" }
    if text.wholeMatch(of: /(?s).*?(?:econnrefused|econnreset|epipe|und_err_socket|\bsocket\b|other side closed|terminated).*/) != nil {
        return "tcp"
    }
    if text.wholeMatch(of: /(?s).*?(?:certificate|\btls\b).*/) != nil { return "tls" }
    if causeCode == "UND_ERR_HEADERS_TIMEOUT" || causeCode == "UND_ERR_BODY_TIMEOUT" { return "read_timeout" }
    if text.wholeMatch(of: /(?s).*?\bproxy\b.*/) != nil { return "proxy_connect" }
    if text.wholeMatch(of: /(?s).*?\bfly\b.*/) != nil { return "fly_edge" }
    return "unknown"
}

private func boundedErrorClass(_ value: String) -> String {
    if value == "TypeError" || value == "AbortError" || value == "Error" { return value }
    return "OtherError"
}

private func boundedMethod(_ value: String) -> String {
    let method = value.uppercased()
    if ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"].contains(method) { return method }
    return "OTHER"
}

private func cannedExcerpt(_ reason: String) -> String {
    switch reason {
    case "local_daemon_state_invalid": "Local daemon lifecycle state rejected the proxy request"
    case "local_post_response": "Local daemon failed after the upstream response completed"
    case "dns": "Upstream DNS resolution failed"
    case "tcp": "Upstream TCP connection failed"
    case "tls": "Upstream TLS negotiation failed"
    case "read_timeout": "Upstream response timed out"
    case "proxy_connect": "Upstream proxy connection failed"
    case "fly_edge": "Upstream edge transport failed"
    default: "Proxy request failed with an unclassified cause"
    }
}

private func jsonAttr(_ value: DaemonProxyAttr) -> String {
    switch value {
    case .string(let text): jsonString(text)
    case .bool(let flag): flag ? "true" : "false"
    case .int(let number): String(number)
    }
}

private func jsonString(_ value: String) -> String {
    var out = "\""
    for scalar in value.unicodeScalars {
        switch scalar {
        case "\\": out += "\\\\"
        case "\"": out += "\\\""
        default: out.unicodeScalars.append(scalar)
        }
    }
    out += "\""
    return out
}

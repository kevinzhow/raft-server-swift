import Testing
@testable import RaftDaemonClient

private func text(_ attributes: [String: DaemonProxyAttr]) -> String {
    DaemonProxyFailure.jsonText(attributes)
}

@Test func proxyFailureProjectionIsRouteClassedAndContentFree() {
    let attributes = DaemonProxyFailure.traceAttributes(DaemonProxyFailureInput(
        method: "GET",
        pathname: "/internal/agent-api/tasks",
        errorName: "TypeError",
        errorMessage: "fetch https://private.example/tasks?channel=secret failed for /Users/alice",
        errorCause: "UND_ERR_SOCKET other side closed secret@example.test"
    ))
    #expect(attributes["route_family"] == .string("tasks"))
    #expect(attributes["method"] == .string("GET"))
    #expect(attributes["outcome"] == .string("error"))
    #expect(attributes["reason"] == .string("tcp"))
    #expect(attributes["error_class"] == .string("TypeError"))
    #expect(attributes["error_excerpt"] == .string("Upstream TCP connection failed"))
    #expect(attributes["response_code_present"] == .bool(false))
    let encoded = text(attributes)
    #expect(encoded.contains("private") == false)
    #expect(encoded.contains("secret") == false)
    #expect(encoded.contains("Users") == false)
    #expect(encoded.contains("example.test") == false)
    #expect(encoded.contains("channel") == false)
    #expect(encoded.contains("status") == false)
}

@Test func transportTracesReplaceTheOriginalMessage() {
    let excerpt = DaemonProxyFailure.transportExcerpt(DaemonProxyTransportError(
        normalizedCode: "transport_failure",
        upstreamLayer: "read_timeout"
    ))
    #expect(excerpt == "Upstream response timed out")
    #expect(excerpt.contains("secret") == false)
    #expect(excerpt.contains("Users") == false)
    #expect(excerpt.contains("https") == false)
}

@Test func onlyExplicitUndiciReadTimeoutsAreReadTimeout() {
    let bare = DaemonProxyFailure.traceAttributes(DaemonProxyFailureInput(
        method: "GET",
        pathname: "/internal/agent-api/tasks",
        errorName: "TypeError",
        errorMessage: "request timeout while waiting for upstream",
        errorCause: "ETIMEDOUT",
        causeCode: "ETIMEDOUT"
    ))
    #expect(bare["reason"] == .string("unknown"))

    let headers = DaemonProxyFailure.traceAttributes(DaemonProxyFailureInput(
        method: "GET",
        pathname: "/internal/agent-api/tasks",
        errorName: "TypeError",
        errorMessage: "fetch failed",
        errorCause: "Headers Timeout Error",
        causeCode: "UND_ERR_HEADERS_TIMEOUT"
    ))
    #expect(headers["reason"] == .string("read_timeout"))

    let body = DaemonProxyFailure.traceAttributes(DaemonProxyFailureInput(
        method: "GET",
        pathname: "/internal/agent-api/tasks",
        errorName: "TypeError",
        errorMessage: "fetch failed",
        errorCause: "Body Timeout Error",
        causeCode: "UND_ERR_BODY_TIMEOUT"
    ))
    #expect(body["reason"] == .string("read_timeout"))
}

@Test func localLifecycleFailureDropsTheAgentIdAndContext() {
    let attributes = DaemonProxyFailure.traceAttributes(DaemonProxyFailureInput(
        method: "GET",
        pathname: "/internal/agent-api/events",
        errorName: "Error",
        errorMessage: "private invariant detail",
        lifecycleInvalidContext: "visible-consume",
        responseStatusCode: 409,
        responseCode: "agent_lifecycle_state_invalid"
    ))
    #expect(attributes["reason"] == .string("local_daemon_state_invalid"))
    #expect(attributes["response_status_code"] == .int(409))
    #expect(attributes["response_code_present"] == .bool(true))
    let encoded = text(attributes)
    #expect(encoded.contains("agent-secret") == false)
    #expect(encoded.contains("visible-consume") == false)
}

@Test func hostileMethodAndErrorNameAreBounded() {
    let attributes = DaemonProxyFailure.traceAttributes(DaemonProxyFailureInput(
        method: "SECRET-METHOD",
        pathname: "/internal/agent-api/tasks",
        errorName: "private-user-class",
        errorMessage: "private-user-value"
    ))
    #expect(attributes["method"] == .string("OTHER"))
    #expect(attributes["error_class"] == .string("OtherError"))
    let encoded = text(attributes)
    #expect(encoded.contains("SECRET") == false)
    #expect(encoded.contains("private-user") == false)
}

@Test func postResponseLocalFaultHasItsOwnExcerpt() {
    let attributes = DaemonProxyFailure.traceAttributes(DaemonProxyFailureInput(
        method: "GET",
        pathname: "/internal/agent-api/events",
        errorName: "Error",
        errorMessage: "AgentVisibleDeliveryLedger target mismatch",
        causeCode: "LOCAL_POST_RESPONSE_FAILURE",
        failureClass: "post_response_local",
        responseStarted: true,
        responseComplete: true
    ))
    #expect(attributes["reason"] == .string("local_post_response"))
    #expect(attributes["error_excerpt"] == .string("Local daemon failed after the upstream response completed"))
    #expect(attributes["failure_class"] == .string("post_response_local"))

    let excerpt = DaemonProxyFailure.transportExcerpt(DaemonProxyTransportError(
        normalizedCode: "local_post_response_failure",
        upstreamLayer: "unknown"
    ))
    #expect(excerpt == "Local daemon failed after the upstream response completed")
    #expect(excerpt.contains("secret") == false)
    #expect(excerpt.contains("Ledger") == false)
}

@Test func transportTracesGivePostResponseLocalFaultsTheirOwnExcerpt() {
    let excerpt = DaemonProxyFailure.transportExcerpt(DaemonProxyTransportError(
        normalizedCode: "local_post_response_failure",
        upstreamLayer: "unknown"
    ))
    #expect(excerpt == "Local daemon failed after the upstream response completed")
    #expect(!excerpt.contains("secret"))
    #expect(!excerpt.contains("Ledger"))
}

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import RaftDaemonClient

private func json(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

private func options(timeoutMs: Int = 60_000, warn: @escaping @Sendable (String) -> Void = { _ in }) -> ChatBridgeRequestOptions {
    ChatBridgeRequestOptions(toolName: "test_tool", target: "target-1", timeoutMs: timeoutMs, warn: warn)
}

@Test func executeJSONReturnsParsedJSON() async throws {
    let result = try await ChatBridgeRequest.executeJSON(
        url: "https://example.test/api", options: options()
    ) { _ in (200, json(["ok": true, "value": 42])) }
    #expect(result.status == 200)
    let object = try #require(result.data as? [String: Any])
    #expect(object["ok"] as? Bool == true)
    #expect(object["value"] as? Int == 42)
}

@Test func executeJSONAbortsLocallyAndLogsAStructuredTimeout() async {
    final class Warnings: @unchecked Sendable { var messages: [String] = [] }
    let warnings = Warnings()
    do {
        _ = try await ChatBridgeRequest.executeJSON(
            url: "https://example.test/slow", options: options(timeoutMs: 10) { warnings.messages.append($0) }
        ) { _ in
            try await Task.sleep(nanoseconds: 100_000_000)
            return (200, json([:]))
        }
        Issue.record("expected timeout")
    } catch let error as ChatBridgeToolTimeoutError {
        #expect(error.toolName == "test_tool")
        #expect(error.timeoutMs == 10)
        let message = warnings.messages.first ?? ""
        #expect(message.contains("[ChatBridgeTimeout]"))
        #expect(message.contains("tool=test_tool"))
        #expect(message.contains("outcome=timeout"))
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

@Test func executeResponseReturnsTheRawResponse() async throws {
    let body = Data("binary-bytes".utf8)
    let result = try await ChatBridgeRequest.executeResponse(
        url: "https://example.test/file", options: options()
    ) { _ in (200, body) }
    #expect(result.status == 200)
    #expect(result.body == body)
}

@Test func executeResponseAbortsLocallyAndLogsAStructuredTimeout() async {
    do {
        _ = try await ChatBridgeRequest.executeResponse(
            url: "https://example.test/slow-file", options: options(timeoutMs: 10)
        ) { _ in
            try await Task.sleep(nanoseconds: 100_000_000)
            return (200, Data())
        }
        Issue.record("expected timeout")
    } catch let error as ChatBridgeToolTimeoutError {
        #expect(error.timeoutMs == 10)
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

@Test func executeJSONReportsANonJSONErrorByHTTPStatus() async {
    do {
        _ = try await ChatBridgeRequest.executeJSON(
            url: "https://example.test/upload", options: options()
        ) { _ in (413, Data("<html>too large</html>".utf8)) }
        Issue.record("expected status error")
    } catch let error as HttpStatusError {
        #expect(error.status == 413)
        #expect(error.serverError == nil)
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

@Test func executeJSONKeepsAJSONErrorBodyMessageBesideTheStatus() async {
    do {
        _ = try await ChatBridgeRequest.executeJSON(
            url: "https://example.test/fail", options: options()
        ) { _ in (400, json(["error": "bad request detail"])) }
        Issue.record("expected status error")
    } catch let error as HttpStatusError {
        #expect(error.status == 400)
        #expect(error.serverError == "bad request detail")
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

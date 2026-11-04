import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Shared chat-bridge HTTP executor: JSON requests and raw-response requests
/// with a local timeout that aborts and logs a structured timeout, and an
/// HTTP-status error raised from the STATUS before parsing the body (so an HTML
/// error page is never reported as a parse failure). Ported from the upstream
/// daemon helper.
public let defaultChatBridgeToolTimeoutMs = 60_000

public final class ChatBridgeToolTimeoutError: Error, @unchecked Sendable, CustomStringConvertible {
    public let toolName: String
    public let target: String?
    public let timeoutMs: Int
    public let durationMs: Int
    public let description: String
    public init(toolName: String, target: String?, timeoutMs: Int, durationMs: Int) {
        self.toolName = toolName
        self.target = target
        self.timeoutMs = timeoutMs
        self.durationMs = durationMs
        self.description = "\(toolName) timed out after \(timeoutMs)ms" + (target.map { " (target: \($0))" } ?? "")
    }
}

public struct ChatBridgeRequestOptions: Sendable {
    public var toolName: String
    public var target: String?
    public var timeoutMs: Int
    public var warn: @Sendable (String) -> Void
    public var now: @Sendable () -> Int
    public init(
        toolName: String, target: String? = nil,
        timeoutMs: Int = defaultChatBridgeToolTimeoutMs,
        warn: @escaping @Sendable (String) -> Void = { _ in },
        now: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.toolName = toolName
        self.target = target
        self.timeoutMs = timeoutMs
        self.warn = warn
        self.now = now
    }
}

public enum ChatBridgeRequest {
    public typealias Send = @Sendable (URLRequest) async throws -> (status: Int, body: Data)

    enum Outcome: Sendable {
        case response(status: Int, body: Data)
        case timedOut
    }

    static func race(_ task: Task<(status: Int, body: Data), Error>, timeoutMs: Int) async -> Outcome {
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            func take() -> Bool {
                lock.lock(); defer { lock.unlock() }
                if done { return false }
                done = true
                return true
            }
        }
        let once = Once()
        return await withCheckedContinuation { continuation in
            Task {
                do {
                    let value = try await task.value
                    if once.take() { continuation.resume(returning: .response(status: value.status, body: value.body)) }
                } catch {
                    if once.take() { continuation.resume(returning: .response(status: -1, body: Data())) }
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeoutMs)) * 1_000_000)
                if once.take() {
                    task.cancel()
                    continuation.resume(returning: .timedOut)
                }
            }
        }
    }

    static func readErrorBodyMessage(_ body: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let message = object["error"] as? String
        else { return nil }
        return String(message.prefix(300))
    }

    /// Returns parsed JSON for a successful request; a non-2xx status is an
    /// `HttpStatusError` carrying the status and any JSON `error` message.
    public static func executeJSON(
        url: String,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        options: ChatBridgeRequestOptions,
        send: @escaping Send
    ) async throws -> (status: Int, data: Any, durationMs: Int) {
        let startedAt = options.now()
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = body
        let sendFn = send
        let task = Task { try await sendFn(request) }
        let outcome = await race(task, timeoutMs: options.timeoutMs)
        let durationMs = options.now() - startedAt
        switch outcome {
        case .timedOut:
            options.warn("[ChatBridgeTimeout] tool=\(options.toolName) target=\(options.target ?? "-") duration_ms=\(durationMs) timeout_ms=\(options.timeoutMs) outcome=timeout")
            throw ChatBridgeToolTimeoutError(
                toolName: options.toolName, target: options.target,
                timeoutMs: options.timeoutMs, durationMs: durationMs
            )
        case .response(let status, let data):
            guard (200..<300).contains(status) else {
                let error = HttpStatusError(
                    toolName: options.toolName, status: status, serverError: readErrorBodyMessage(data)
                )
                options.warn("[ChatBridgeError] tool=\(options.toolName) target=\(options.target ?? "-") duration_ms=\(durationMs) outcome=error error=HttpStatusError: \(status)")
                throw error
            }
            guard let parsed = try? JSONSerialization.jsonObject(with: data) else {
                throw NSError(domain: "ChatBridgeRequest", code: 1)
            }
            return (status, parsed, durationMs)
        }
    }

    /// Returns the raw response for binary/file flows.
    public static func executeResponse(
        url: String,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        options: ChatBridgeRequestOptions,
        send: @escaping Send
    ) async throws -> (status: Int, body: Data, durationMs: Int) {
        let startedAt = options.now()
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = body
        let sendFn = send
        let task = Task { try await sendFn(request) }
        let outcome = await race(task, timeoutMs: options.timeoutMs)
        let durationMs = options.now() - startedAt
        switch outcome {
        case .timedOut:
            options.warn("[ChatBridgeTimeout] tool=\(options.toolName) target=\(options.target ?? "-") duration_ms=\(durationMs) timeout_ms=\(options.timeoutMs) outcome=timeout")
            throw ChatBridgeToolTimeoutError(
                toolName: options.toolName, target: options.target,
                timeoutMs: options.timeoutMs, durationMs: durationMs
            )
        case .response(let status, let body):
            return (status, body, durationMs)
        }
    }
}

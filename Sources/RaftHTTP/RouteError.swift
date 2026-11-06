import Foundation

/// JSON error boundary from `packages/server/src/routes/errorResponse.ts`.
///
/// An uncaught route failure becomes 500 `internal_server_error` with
/// `X-Slock-Error-Id`. The body is the fixed sentence, never the thrown
/// message. A `RisingWaveOverloadedError` anywhere in the first five causes
/// is 503 `rw_overloaded` with `Retry-After: 2` instead. A route that already
/// wrote its own status is left alone.

public struct RisingWaveOverloadedError: Error, Equatable, Sendable {
    public var detail: String

    public init(_ detail: String) {
        self.detail = detail
    }
}

/// One link in the `cause` chain `findRisingWaveOverload` walks.
public struct CausalRouteError: Error, Sendable {
    public var message: String
    public var cause: (any Error)?

    public init(_ message: String, cause: (any Error)? = nil) {
        self.message = message
        self.cause = cause
    }
}

/// Thrown status the global handler does not rewrite: 400...499 pass through,
/// and an explicit 500...599 is kept as the HTTP status of the sanitized body.
public struct RouteStatusError: Error, Equatable, Sendable {
    public var status: Int
    public var message: String

    public init(status: Int, message: String) {
        self.status = status
        self.message = message
    }
}

public enum JsonServerError {
    public static let overloadRetryAfterSeconds = 2

    public static func findRisingWaveOverload(_ error: any Error) -> RisingWaveOverloadedError? {
        var current: (any Error)? = error
        for _ in 0..<5 {
            guard let item = current else { return nil }
            if let overload = item as? RisingWaveOverloadedError { return overload }
            if let causal = item as? CausalRouteError {
                current = causal.cause
                continue
            }
            return nil
        }
        return nil
    }

    public static func respondToRisingWaveOverload(_ error: any Error) -> HTTPReply? {
        guard findRisingWaveOverload(error) != nil else { return nil }
        let body = "{\"error\":\"Temporarily overloaded, retry shortly\",\"code\":\"rw_overloaded\",\"retryable\":true}"
        return jsonReply(status: 503, body: body, extraHeaders: [
            "Retry-After": String(overloadRetryAfterSeconds),
        ])
    }

    public static func send(
        error: String,
        code: String? = nil,
        status: Int = 500,
        err: any Error,
        correlationId: String = UUID().uuidString.lowercased()
    ) -> HTTPReply {
        if let overload = respondToRisingWaveOverload(err) { return overload }
        var body = "{\"error\":\(jsonString(error))"
        if let code {
            body += ",\"code\":\(jsonString(code))"
        }
        body += ",\"correlationId\":\(jsonString(correlationId))}"
        return jsonReply(status: status, body: body, extraHeaders: [
            "X-Slock-Error-Id": correlationId,
        ])
    }

    public enum Disposition: Equatable, Sendable {
        case passthrough
        case reply(HTTPReply)
    }

    public static func global(_ error: any Error, correlationId: String = UUID().uuidString.lowercased()) -> Disposition {
        if let overload = respondToRisingWaveOverload(error) { return .reply(overload) }
        if let statusError = error as? RouteStatusError,
           statusError.status >= 400, statusError.status < 500 {
            return .passthrough
        }
        let status: Int
        if let statusError = error as? RouteStatusError,
           statusError.status >= 500, statusError.status < 600 {
            status = statusError.status
        } else {
            status = 500
        }
        return .reply(send(
            error: "Internal server error",
            code: "internal_server_error",
            status: status,
            err: error,
            correlationId: correlationId
        ))
    }

    private static func jsonReply(status: Int, body: String, extraHeaders: [String: String]) -> HTTPReply {
        var headers = [
            "X-Robots-Tag": AppFallback.robotsTag,
            "Content-Type": AppFallback.jsonContentType,
            "Content-Length": String(Data(body.utf8).count),
        ]
        for (name, value) in extraHeaders {
            headers[name] = value
        }
        return HTTPReply(status: status, headers: headers, body: body)
    }
}

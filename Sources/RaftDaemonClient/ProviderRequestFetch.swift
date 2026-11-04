import Foundation

/// Passive HTTP request facts for provider calls (request-status diagnostics).
/// The transport still owns cancellation, errors and retries; the observer sees
/// only waiting/headers/failure phases, never the request or response body, and
/// a throwing observer cannot alter the provider call. Ported from the upstream
/// daemon helper.
public struct ProviderRequestActivity: Sendable, Equatable {
    public var schemaVersion: Int = 1
    public var requestId: String
    public var provider: String
    public var startedAt: String
    public var phase: String
    public var observedAt: String
    public var httpStatus: Int?
}

public struct ProviderRequest: Sendable, Equatable {
    public var url: String
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    public var cancelled: Bool
    public init(url: String, method: String = "GET", headers: [String: String] = [:], body: Data? = nil, cancelled: Bool = false) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.cancelled = cancelled
    }
}

public final class ProviderHTTPResponse: @unchecked Sendable {
    public let status: Int
    public let ok: Bool
    public let url: String
    public let redirected: Bool
    public let headers: [String: String]
    public var body: Data?

    public init(status: Int, url: String, redirected: Bool = false, headers: [String: String] = [:], body: Data? = nil) {
        self.status = status
        self.ok = (200..<300).contains(status)
        self.url = url
        self.redirected = redirected
        self.headers = headers
        self.body = body
    }

    public var bodyLocked: Bool { false }

    public func text() -> String { String(decoding: body ?? Data(), as: UTF8.self) }

    /// An unlocked, independently consumable copy.
    public func clone() -> ProviderHTTPResponse {
        ProviderHTTPResponse(status: status, url: url, redirected: redirected, headers: headers, body: body)
    }
}

public enum ProviderRequestFetch {
    public typealias Send = @Sendable (ProviderRequest) async throws -> ProviderHTTPResponse
    public typealias Observer = (ProviderRequestActivity) throws -> Void

    static func normalizeProvider(_ provider: String) -> String {
        provider.range(of: #"^[a-z0-9_-]{1,64}$"#, options: .regularExpression) != nil ? provider : "custom"
    }

    static func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    /// Sends the request untouched and reports waiting, then headers (responding
    /// or failed); cancellation rethrows as cancelled. Returns the transport's
    /// own response so identity, metadata and body ownership stay intact.
    public static func fetch(
        _ request: ProviderRequest,
        provider: String,
        observe: Observer? = nil,
        send: Send
    ) async throws -> ProviderHTTPResponse {
        let startedAt = isoNow()
        let requestId = "pr_" + UUID().uuidString.lowercased()
        let normalized = normalizeProvider(provider)
        func report(_ phase: String, _ status: Int? = nil) {
            guard let observe else { return }
            var activity = ProviderRequestActivity(
                requestId: requestId, provider: normalized, startedAt: startedAt,
                phase: phase, observedAt: isoNow()
            )
            if let status { activity.httpStatus = status }
            do { try observe(activity) } catch { /* an unavailable sink must not alter the request */ }
        }
        report("waiting")
        do {
            let response = try await send(request)
            report(response.ok ? "responding" : "failed", response.status)
            return response
        } catch {
            report(request.cancelled ? "cancelled" : "failed")
            throw error
        }
    }
}

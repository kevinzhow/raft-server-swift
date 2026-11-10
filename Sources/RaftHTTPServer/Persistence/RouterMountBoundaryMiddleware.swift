import Foundation
import RaftHTTP
import Vapor

/// Reject aliases that Vapor can dispatch past a raw Node-style mount policy.
/// The matched route, already attached by DefaultResponder, is authoritative.
/// Only its leading constants are checked; dynamic IDs and later literals keep
/// their original routing behavior. The request URL and parameters are untouched.
enum RouterMountBoundaryPolicy {
    static func rejects(path: String, constantPrefix: [String]) -> Bool {
        guard let first = constantPrefix.first?.lowercased(), first == "api" || first == "internal" else { return false }
        var raw = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if path.hasPrefix("/") { raw.removeFirst() }
        guard raw.count >= constantPrefix.count else { return true }
        return zip(raw, constantPrefix).contains { pair in pair.0.lowercased() != pair.1.lowercased() }
    }

    /// A classifier input only: never assign this string to Request.url.
    /// Read actual parameters exactly as exposed by the pinned SDK. Escape
    /// percent and slash before joining; this helper never decodes their text.
    /// Unsupported component kinds have no safe scalar representation.
    static func admissionPath(for request: Request) -> String? {
        guard let route = request.route else { return nil }
        var parts: [String] = []
        for component in route.path {
            let value: String
            switch component {
            case .constant(let literal):
                if literal.isEmpty { continue }
                guard !literal.contains("/") else { return nil }
                value = literal
            case .parameter(let name):
                guard let actual = request.parameters.get(name), !actual.isEmpty else { return nil }
                value = actual
            case .anything, .catchall, .partialParameter:
                return nil
            }
            parts.append(value.replacingOccurrences(of: "%", with: "%25")
                .replacingOccurrences(of: "/", with: "%2F"))
        }
        return "/" + parts.joined(separator: "/")
    }
}

struct RouterMountBoundaryMiddleware: Middleware {
    func respond(to request: Request, chainingTo next: any Responder) async throws -> Response {
        // Preflight retains the existing CORS path and skips business admission.
        guard request.method != .options, let route = request.route else {
            return try await next.respond(to: request)
        }
        var prefix: [String] = []
        for component in route.path {
            guard case .constant(let literal) = component else { break }
            // DefaultResponder also omits empty registered constants.
            if !literal.isEmpty { prefix.append(literal) }
        }
        guard RouterMountBoundaryPolicy.rejects(path: request.url.path, constantPrefix: prefix) else {
            return try await next.respond(to: request)
        }
        var response = RaftHTTPServer.respond(status: 404, rawJSON: OrderedJSON.object([
            OrderedJSONField("error", "Not found"),
            OrderedJSONField("code", "not_found"),
            OrderedJSONField("path", request.url.path),
        ]).render())
        if request.method == .head {
            let length = response.headers[.contentLength]
            response.body = .init(string: "")
            response.headers[.contentLength] = length
        }
        return response
    }
}

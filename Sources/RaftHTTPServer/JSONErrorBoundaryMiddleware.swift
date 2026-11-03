import Foundation
import HTTPTypes
import Vapor

/// Global JSON error boundary: an uncaught 5xx route failure becomes a
/// sanitized JSON body with a correlation id that also rides
/// `x-slock-error-id`; explicit typed route responses are never rewritten.
/// Ported from the upstream server error boundary (the RisingWave overload
/// mapping has no counterpart in this port).
public struct JSONErrorBoundaryMiddleware: Middleware {
    public static let errorHeader = HTTPField.Name("x-slock-error-id")!

    public init() {}

    public func respond(to request: Request, chainingTo next: any Responder) async throws -> Response {
        do {
            return try await next.respond(to: request)
        } catch {
            let correlationId = UUID().uuidString.lowercased()
            var headers = HTTPFields()
            headers[Self.errorHeader] = correlationId
            headers[.contentType] = "application/json"
            let body = #"{"error":"Internal server error","code":"internal_server_error","correlationId":"\#(correlationId)"}"#
            return Response(status: .internalServerError, headers: headers, body: .init(string: body))
        }
    }
}

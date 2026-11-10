import Foundation
import RaftHTTP
import Vapor

/// The outermost business boundary returns a response only after PG commit and
/// publication. HTTP refusals can consume durable nonces, so response status does
/// not determine rollback. Intent failures must mark the transaction rollback-only.
struct BusinessPersistenceMiddleware: Middleware {
    let runtime: BusinessPersistenceRuntime

    static func isMachineQuery(_ path: String) -> Bool {
        // DefaultResponder splits before decoding each component exactly once,
        // keeping the original component when percent decoding fails. Decoding
        // the full path first would incorrectly reinterpret an encoded slash.
        let p = path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        if p.count == 4 || p.count == 5 {
            return p[0] == "api" && p[1] == "agents" && p[3] == "workspace-files" && (p.count == 4 || p[4] == "read")
        }
        if p.count == 6 && p[0] == "api" && p[1] == "servers" && p[3] == "machines" && p[5] == "workspaces" { return true }
        guard p.count >= 7, p[0] == "api", p[1] == "servers", p[3] == "machines" else { return false }
        if p.count == 7 && p[5] == "runtime-models" { return true }
        if p.count == 9 && p[5] == "runtime-form-definitions" && p[7] == "option-sources" { return true }
        return p.count == 10 && p[5] == "runtime-forms" && p[6] == "v2" && p[8] == "option-sources"
    }

    func respond(to request: Request, chainingTo next: any Responder) async throws -> Response {
        // Version is liveness only. Health performs its explicit runtime/PG/Redis
        // probe and remains callable when business admission has failed closed.
        if request.method == .get && ["/api/version", "/health", "/livez"].contains(request.url.path) {
            return try await next.respond(to: request)
        }
        // Only these read-only machine RPC routes own explicit short
        // committed boundaries in their typed services. Awaiting a daemon under
        // the outer FIFO writer would prevent earlier ready/catalog commits.
        do {
            // Vapor forwards HEAD to these GET handlers without changing the
            // request method. Both methods need the same short UoW boundaries.
            if (request.method == .get || request.method == .head) && Self.isMachineQuery(request.url.path) {
                return try await next.respond(to: request)
            }
            return try await runtime.execute {
                try await next.respond(to: request)
            }
        } catch {
            // Never leak a driver error, URL or token, and never return the
            // handler's successful body after a failed/unknown SQL commit.
            return try await RaftHTTPServer.respond(
                status: 503,
                headers: .exact(["Content-Type": "application/json", "Cache-Control": "no-store"])
            ) { BusinessPersistenceUnavailableBody() }
        }
    }
}

private struct BusinessPersistenceUnavailableBody: Encodable, Sendable {
    let error = "Business persistence unavailable"
}

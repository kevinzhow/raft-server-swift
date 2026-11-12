import Foundation
import RaftHTTP
import Vapor

/// The exact business-persistence 503 shared by the legacy writer boundary and
/// the bounded admission middlewares. HEAD keeps the GET body length.
enum BusinessPersistenceUnavailableResponse {
    static func make(request: Request) async throws -> Response {
        var response = try await RaftHTTPServer.respond(
            status: 503,
            headers: .exact(["Content-Type": "application/json", "Cache-Control": "no-store"])
        ) {
            BusinessPersistenceUnavailableBody()
        }
        if request.method == .head {
            let length = response.headers[.contentLength]
            response.body = .init(string: "")
            response.headers[.contentLength] = length
        }
        return response
    }
}

private struct BusinessPersistenceUnavailableBody: Encodable, Sendable {
    let error = "Business persistence unavailable"
}

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
        do {
            // Only these read-only machine RPC routes own explicit short
            // committed boundaries in their typed services. Awaiting a daemon under
            // the outer FIFO writer would prevent earlier ready/catalog commits.
            // Vapor forwards HEAD to these GET handlers without changing the
            // request method. Both methods need the same short UoW boundaries.
            if (request.method == .get || request.method == .head) && Self.isMachineQuery(request.url.path) {
                return try await next.respond(to: request)
            }
            // The selected attachment body plane keeps storage/multipart I/O out of
            // the global writer. It gets a request-scoped port and no outer
            // `runtime.execute`; admission and row writes use short phases.
            if AttachmentBodyPlanePolicy.matches(method: request.method, path: request.url.path) {
                return try await AttachmentTransactionScope.$bounded.withValue(true) {
                    try await AttachmentTransactionScope.$port.withValue(
                        RuntimeAttachmentTransactionPort(runtime: runtime)
                    ) {
                        // Transfer preparation (multipart collection, object I/O
                        // and response building) has its own four-operation
                        // budget, independent of the business writer FIFO.
                        try await AttachmentTransferBudget.shared.withPermit {
                            try await next.respond(to: request)
                        }
                    }
                }
            }
            return try await runtime.execute {
                try await next.respond(to: request)
            }
        } catch {
            // Never leak a driver error, URL or token, and never return the
            // handler's successful body after a failed/unknown SQL commit.
            return try await BusinessPersistenceUnavailableResponse.make(request: request)
        }
    }
}

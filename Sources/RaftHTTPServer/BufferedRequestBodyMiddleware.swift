import Vapor

/// The route surface reads `request.body.string` synchronously. Vapor hands
/// handlers a lazy body stream, so without this middleware every real-process
/// POST would see an empty body while `app.testing` pre-collects it.
struct BufferedRequestBodyMiddleware: Middleware {
    func respond(to request: Request, chainingTo next: any Responder) async throws -> Response {
        if request.method != .get && request.method != .head {
            _ = try await request.body.collect()
        }
        return try await next.respond(to: request)
    }
}

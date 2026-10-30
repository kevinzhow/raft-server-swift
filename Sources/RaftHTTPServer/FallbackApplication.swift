import NIOCore
import NIOHTTP1
import RaftHTTP
import Vapor

/// Vapor 4 mount for the read-only responses in `AppFallback`.
///
/// The middleware answers every request, so Vapor's router and its default
/// error page never choose the status or the body. `/daemon/connect` stays on
/// the SwiftNIO listener. This process does not start the livez probe; the
/// executable does that after `configure`.

public struct FallbackServices: Sendable {
    public var nodeEnv: String
    public var tracker: DbLivenessTracker
    public var pingDatabase: @Sendable () async throws -> Void

    public init(
        nodeEnv: String,
        tracker: DbLivenessTracker,
        pingDatabase: @escaping @Sendable () async throws -> Void
    ) {
        self.nodeEnv = nodeEnv
        self.tracker = tracker
        self.pingDatabase = pingDatabase
    }
}

public func configure(_ app: Application, services: FallbackServices) {
    var middleware = Middlewares()
    middleware.use(FallbackMiddleware())
    app.middleware = middleware
    app.storage[FallbackServicesKey.self] = services
}

private struct FallbackServicesKey: StorageKey {
    typealias Value = FallbackServices
}

private let noopPing: @Sendable () async throws -> Void = {}

private struct FallbackMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let services = request.application.storage[FallbackServicesKey.self]
        let reply = await AppFallback.respond(
            method: request.method.rawValue,
            target: requestTarget(request.url),
            nodeEnv: services?.nodeEnv ?? "development",
            tracker: services?.tracker ?? DbLivenessTracker(ping: noopPing),
            pingDatabase: services?.pingDatabase ?? noopPing
        )
        return vaporResponse(reply)
    }
}

private func requestTarget(_ url: URI) -> String {
    guard let query = url.query, !query.isEmpty else { return url.path }
    return "\(url.path)?\(query)"
}

private func vaporResponse(_ reply: HTTPReply) -> Response {
    var headers = HTTPHeaders()
    headers.replaceOrAdd(name: "X-Robots-Tag", value: reply.value(for: "X-Robots-Tag") ?? AppFallback.robotsTag)
    if let type = reply.value(for: "Content-Type") {
        headers.replaceOrAdd(name: .contentType, value: type)
    }
    let response = Response(
        status: HTTPResponseStatus(statusCode: reply.status),
        headers: headers,
        body: .init(string: reply.body)
    )
    if let length = reply.value(for: "Content-Length") {
        response.headers.replaceOrAdd(name: .contentLength, value: length)
    }
    return response
}

import Logging
import RaftHTTP
import RaftHTTPServer
import Vapor

private struct DatabaseNotConnected: Error {}

@main
enum Entrypoint {
    static func main() async throws {
        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)
        let app = try await Application.make(env)
        let nodeEnv = ProcessInfo.processInfo.environment["NODE_ENV"] ?? "development"
        let ping: @Sendable () async throws -> Void = { throw DatabaseNotConnected() }
        let tracker = DbLivenessTracker(ping: ping)
        configure(
            app,
            services: FallbackServices(nodeEnv: nodeEnv, tracker: tracker, pingDatabase: ping)
        )
        await tracker.start()
        do {
            try await app.execute()
            try await app.asyncShutdown()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }
}

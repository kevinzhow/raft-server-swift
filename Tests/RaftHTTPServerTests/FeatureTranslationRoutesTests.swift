import Foundation
import HTTPTypes
import RaftHTTP
import Testing
import Vapor
import VaporTesting
@testable import RaftHTTPServer

/// `POST /api/message-translations:batch` and its anonymous
/// `POST /api/public/servers/:slug/message-translations:batch` sibling used to
/// be registered inline in `configure`. The extracted `TranslationFeature`
/// collection must register exactly those two method/path pairs, and nothing
/// else, when booted on a bare application.
private func translationRouteKey(_ route: Route) -> String {
    let path = route.path.map { "\($0)" }.joined(separator: "/")
    return "\(route.method.rawValue) /\(path)"
}

@Test func translationFeatureRegistersAuthenticatedAndPublicBatchRoutes() async throws {
    let services = FallbackServices(
        nodeEnv: "test",
        tracker: DbLivenessTracker(ping: {}),
        pingDatabase: {}
    )
    try await withApp { app in
        try await app.register(collection: TranslationFeature(services: services))
        let routes = app.routes.all.map(translationRouteKey).sorted()
        #expect(routes == [
            "POST /api/message-translations:batch",
            "POST /api/public/servers/:slug/message-translations:batch",
        ])
    }
}

import Foundation
import RaftHTTP
import Testing
import Vapor
import VaporTesting
@testable import RaftHTTPServer

/// `GET /api/public/servers/:slug` and its three anonymous read children used to
/// be registered inline in `configure`. The extracted `PublicFeature` collection
/// must register exactly those four method/path pairs, nothing else.
private func publicRouteKey(_ route: Route) -> String {
    let path = route.path.map { "\($0)" }.joined(separator: "/")
    return "\(route.method.rawValue) /\(path)"
}

@Test func publicFeatureRegistersFourPublicServerReadRoutes() async throws {
    let services = FallbackServices(
        nodeEnv: "test",
        tracker: DbLivenessTracker(ping: {}),
        pingDatabase: {}
    )
    try await withApp { app in
        try await PublicFeature(services: services).boot(routes: app)
        let routes = app.routes.all.map(publicRouteKey).sorted()
        #expect(routes == [
            "GET /api/public/servers/:slug",
            "GET /api/public/servers/:slug/attachments/:attachmentId",
            "GET /api/public/servers/:slug/channels/:channelId/messages",
            "GET /api/public/servers/:slug/threads/:threadChannelId/messages",
        ])
    }
}

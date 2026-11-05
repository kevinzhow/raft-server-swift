import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

/// The feedback slice must expose its five upstream route pairs without the
/// full `configure(_:services:)` mount. This locks the collection's own
/// registration contract; end-to-end behavior stays with the existing
/// product-feedback route tests once the Lead mounts it.
@Suite
struct FeatureFeedbackRoutesTests {
    @Test func featureFeedbackRoutesAreRegisteredOnABareApplication() async throws {
        let services = FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {}
        )

        try await withApp { app in
            try await app.register(collection: FeedbackFeature(services: services))

            let registered = Set(app.routes.all.map { "\($0.method.rawValue) \($0.path.string)" })
            let expected: [(HTTPRequest.Method, String)] = [
                (.post, "api/app-installation/agent-reminder-messages"),
                (.post, "api/product-feedback/tickets/:ticketId/close"),
                (.post, "api/product-feedback/tickets/:ticketId/comments"),
                (.get, "api/product-feedback/tickets"),
                (.post, "api/product-feedback"),
            ]

            for (method, path) in expected {
                #expect(registered.contains("\(method.rawValue) \(path)"))
            }
            #expect(app.routes.all.count == expected.count)
        }
    }
}

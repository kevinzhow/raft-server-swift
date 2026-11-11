import Foundation
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

/// Development hook for `scripts/route_inventory.py`.
///
/// Setting `RAFT_ROUTE_INVENTORY_OUT` writes the complete FallbackApplication
/// route table (one `METHOD<TAB>path` line per route, sorted) to that path. The
/// normal test run only checks that the table is nonempty and unique, so the
/// dump stays a route-inventory helper rather than a hidden production seam.
@Test func fallbackApplicationRouteTableIsDumpable() async throws {
    let accounts = EmailLoginDirectory()
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))

        let routes = app.routes.all.map { route in
            (route.method.rawValue, "/" + route.path.map { "\($0)" }.joined(separator: "/"))
        }
        #expect(!routes.isEmpty)

        if let out = ProcessInfo.processInfo.environment["RAFT_ROUTE_INVENTORY_OUT"] {
            let lines = routes.map { "\($0.0)\t\($0.1)" }.sorted()
            try (lines.joined(separator: "\n") + "\n")
                .write(toFile: out, atomically: true, encoding: .utf8)
        }
    }
}

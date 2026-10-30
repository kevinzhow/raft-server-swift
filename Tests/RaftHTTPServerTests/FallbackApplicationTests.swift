import NIOHTTP1
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private func bodyText(_ response: TestingHTTPResponse) -> String {
    response.body.getString(at: response.body.readerIndex, length: response.body.readableBytes) ?? ""
}

private func services(nodeEnv: String, ping: @escaping @Sendable () async throws -> Void) -> FallbackServices {
    FallbackServices(nodeEnv: nodeEnv, tracker: DbLivenessTracker(ping: {}), pingDatabase: ping)
}

@Test func vaporServesTheAppFallbackContract() async throws {
    try await withApp { app in
        configure(app, services: services(nodeEnv: "test", ping: {}))

        try await app.testing().test(.GET, "/") { res async in
            #expect(res.status == .notFound)
            #expect(res.headers.first(name: "content-type")?.contains("application/json") == true)
            #expect(res.headers.first(name: "x-robots-tag") == "noindex, nofollow")
            #expect(bodyText(res) == "{\"error\":\"Not found\",\"code\":\"not_found\",\"path\":\"/\"}")
        }

        try await app.testing().test(.GET, "/not-a-real-path") { res async in
            #expect(bodyText(res) == "{\"error\":\"Not found\",\"code\":\"not_found\",\"path\":\"/not-a-real-path\"}")
        }

        try await app.testing().test(.GET, "/api/not-a-real-path") { res async in
            #expect(bodyText(res) == "{\"error\":\"Not found\",\"code\":\"not_found\",\"path\":\"/api/not-a-real-path\"}")
        }

        try await app.testing().test(.GET, "/livez") { res async in
            #expect(res.status == .ok)
            #expect(bodyText(res) == "{\"status\":\"ok\",\"ok\":true,\"db\":\"unmonitored\",\"msSinceDbSuccess\":null}")
        }

        try await app.testing().test(.GET, "/health") { res async in
            #expect(res.status == .ok)
            #expect(res.headers.first(name: "x-robots-tag") == "noindex, nofollow")
            #expect(bodyText(res) == "{\"status\":\"ok\"}")
        }

        try await app.testing().test(.GET, "/robots.txt") { res async in
            #expect(res.status == .ok)
            #expect(res.headers.first(name: "content-type")?.contains("text/plain") == true)
            #expect(res.headers.first(name: "x-robots-tag") == "noindex, nofollow")
            #expect(bodyText(res) == AppFallback.robotsBody)
        }

        for (method, path) in [
            (HTTPMethod.POST, "/__playwright/scenarios"),
            (.DELETE, "/__playwright/scenarios/not-owned"),
            (.POST, "/__playwright/scenarios/not-owned/thread-window"),
        ] {
            try await app.testing().test(method, path) { res async in
                #expect(res.status == .notFound)
                #expect(bodyText(res).contains("\"code\":\"not_found\""))
            }
        }
    }
}

@Test func vaporHealthFailureStaysDatabaseUnreachable() async throws {
    try await withApp { app in
        configure(app, services: services(nodeEnv: "test", ping: { throw CancellationError() }))
        try await app.testing().test(.GET, "/health") { res async in
            #expect(res.status == .serviceUnavailable)
            #expect(bodyText(res) == "{\"status\":\"error\",\"detail\":\"database unreachable\"}")
        }
    }
}

@Test func vaporLivezIsUnavailableWhileProductionIsUnmonitored() async throws {
    try await withApp { app in
        configure(app, services: services(nodeEnv: "production", ping: {}))
        try await app.testing().test(.GET, "/livez") { res async in
            #expect(res.status == .serviceUnavailable)
            #expect(bodyText(res).contains("\"db\":\"unmonitored\""))
        }
    }
}

@Test func vaporHeadKeepsTheGetContentLength() async throws {
    try await withApp { app in
        configure(app, services: services(nodeEnv: "test", ping: {}))
        try await app.testing().test(.HEAD, "/health") { res async in
            #expect(res.status == .ok)
            #expect(bodyText(res).isEmpty)
            #expect(res.headers.first(name: .contentLength) == "15")
        }
    }
}

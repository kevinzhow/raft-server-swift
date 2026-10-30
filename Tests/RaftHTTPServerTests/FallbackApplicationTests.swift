import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private func bodyText(_ response: ClientResponse) -> String {
    response.body.string ?? ""
}

private func services(nodeEnv: String, ping: @escaping @Sendable () async throws -> Void) -> FallbackServices {
    FallbackServices(nodeEnv: nodeEnv, tracker: DbLivenessTracker(ping: {}), pingDatabase: ping)
}

@Test func vaporServesTheAppFallbackContract() async throws {
    try await withApp { app in
        configure(app, services: services(nodeEnv: "test", ping: {}))

        try await app.testing { client in
            let root = try await client.get("/")
            #expect(root.status == .notFound)
            #expect(root.headers[.contentType]?.contains("application/json") == true)
            #expect(root.headers[HTTPField.Name("X-Robots-Tag")!] == "noindex, nofollow")
            #expect(bodyText(root) == "{\"error\":\"Not found\",\"code\":\"not_found\",\"path\":\"/\"}")

            let missing = try await client.get("/not-a-real-path")
            #expect(bodyText(missing) == "{\"error\":\"Not found\",\"code\":\"not_found\",\"path\":\"/not-a-real-path\"}")

            let api = try await client.get("/api/not-a-real-path")
            #expect(bodyText(api) == "{\"error\":\"Not found\",\"code\":\"not_found\",\"path\":\"/api/not-a-real-path\"}")

            let livez = try await client.get("/livez")
            #expect(livez.status == .ok)
            #expect(bodyText(livez) == "{\"status\":\"ok\",\"ok\":true,\"db\":\"unmonitored\",\"msSinceDbSuccess\":null}")

            let health = try await client.get("/health")
            #expect(health.status == .ok)
            #expect(health.headers[HTTPField.Name("X-Robots-Tag")!] == "noindex, nofollow")
            #expect(bodyText(health) == "{\"status\":\"ok\"}")

            let robots = try await client.get("/robots.txt")
            #expect(robots.status == .ok)
            #expect(robots.headers[.contentType]?.contains("text/plain") == true)
            #expect(robots.headers[HTTPField.Name("X-Robots-Tag")!] == "noindex, nofollow")
            #expect(bodyText(robots) == AppFallback.robotsBody)

            for (method, path) in [
                (HTTPRequest.Method.post, "/__playwright/scenarios"),
                (.delete, "/__playwright/scenarios/not-owned"),
                (.post, "/__playwright/scenarios/not-owned/thread-window"),
            ] {
                let res = try await client.send(method, to: URI(string: path))
                #expect(res.status == .notFound)
                #expect(bodyText(res).contains("\"code\":\"not_found\""))
            }
        }
    }
}

@Test func vaporHealthFailureStaysDatabaseUnreachable() async throws {
    try await withApp { app in
        configure(app, services: services(nodeEnv: "test", ping: { throw CancellationError() }))
        try await app.testing { client in
            let res = try await client.get("/health")
            #expect(res.status == .serviceUnavailable)
            #expect(bodyText(res) == "{\"status\":\"error\",\"detail\":\"database unreachable\"}")
        }
    }
}

@Test func vaporLivezIsUnavailableWhileProductionIsUnmonitored() async throws {
    try await withApp { app in
        configure(app, services: services(nodeEnv: "production", ping: {}))
        try await app.testing { client in
            let res = try await client.get("/livez")
            #expect(res.status == .serviceUnavailable)
            #expect(bodyText(res).contains("\"db\":\"unmonitored\""))
        }
    }
}

@Test func vaporVersionRouteAnswersBeforeTheJSON404() async throws {
    let environment = [
        "RAFT_RELEASE_SHA": "ABCDEF1234567890ABCDEF1234567890ABCDEF12",
        "RAFT_BUILD_AT": "2026-07-13T04:52:55Z",
        "RAFT_RELEASE_BRANCH": "staging",
    ]
    let body = "{\"version\":\"1.21.23\",\"sha\":\"abcdef1234567890abcdef1234567890abcdef12\",\"builtAt\":\"2026-07-13T04:52:55Z\",\"branch\":\"staging\"}"
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            releaseEnvironment: environment
        ))
        try await app.testing { client in
            let version = try await client.get("/api/version")
            #expect(version.status == .ok)
            #expect(version.headers[.contentType]?.contains("application/json") == true)
            #expect(version.headers[HTTPField.Name("X-Robots-Tag")!] == "noindex, nofollow")
            #expect(bodyText(version) == body)

            let queried = try await client.get("/api/version?x=1")
            #expect(bodyText(queried) == body)

            let head = try await client.send(.head, to: "/api/version")
            #expect(head.status == .ok)
            #expect(bodyText(head).isEmpty)
            #expect(head.headers[.contentLength] == String(body.utf8.count))

            let posted = try await client.post("/api/version")
            #expect(posted.status == .notFound)
            #expect(bodyText(posted) == "{\"error\":\"Not found\",\"code\":\"not_found\",\"path\":\"/api/version\"}")

            let other = try await client.get("/api/not-a-real-path")
            #expect(bodyText(other) == "{\"error\":\"Not found\",\"code\":\"not_found\",\"path\":\"/api/not-a-real-path\"}")
        }
    }
}

@Test func vaporVersionWithoutReleaseIdentityIs503() async throws {
    try await withApp { app in
        configure(app, services: services(nodeEnv: "test", ping: {}))
        try await app.testing { client in
            let res = try await client.get("/api/version")
            #expect(res.status == .serviceUnavailable)
            #expect(bodyText(res) == "{\"error\":\"Build identity unavailable\",\"code\":\"build_identity_unavailable\",\"detail\":\"RAFT_RELEASE_SHA is missing or disagrees with its legacy alias\",\"sha\":null,\"builtAt\":null,\"branch\":null}")
        }
    }
}

@Test func vaporPreflightCachesForTwoHours() async throws {
    try await withApp { app in
        configure(app, services: services(nodeEnv: "test", ping: {}))
        try await app.testing { client in
            let res = try await client.send(.options, headers: [
                .origin: "http://localhost:5173",
                HTTPField.Name("Access-Control-Request-Method")!: "GET",
                HTTPField.Name("Access-Control-Request-Headers")!: "authorization,x-server-id",
            ], to: "/api/servers")
            #expect(res.status == .noContent)
            #expect(res.headers[.origin] == nil)
            #expect(res.headers[HTTPField.Name("Access-Control-Allow-Origin")!] == "http://localhost:5173")
            #expect(res.headers[HTTPField.Name("Access-Control-Max-Age")!] == "7200")
            #expect(bodyText(res).isEmpty)
        }
    }
}

@Test func vaporHeadKeepsTheGetContentLength() async throws {
    try await withApp { app in
        configure(app, services: services(nodeEnv: "test", ping: {}))
        try await app.testing { client in
            let res = try await client.send(.head, to: "/health")
            #expect(res.status == .ok)
            #expect(bodyText(res).isEmpty)
            #expect(res.headers[.contentLength] == "15")
        }
    }
}

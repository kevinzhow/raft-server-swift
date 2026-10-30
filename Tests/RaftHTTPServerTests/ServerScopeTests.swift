import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private func bodyText(_ response: ClientResponse) -> String {
    response.body.string ?? ""
}

private let leakMarkers = [
    "invalid input syntax for type uuid",
    "Failed query",
    "params:",
    "23505",
    "23503",
    "42P01",
    "22P02",
    "internal_server_error",
]

private func assertNoLeak(_ body: String) {
    let lowered = body.lowercased()
    for marker in leakMarkers {
        #expect(lowered.contains(marker.lowercased()) == false)
    }
    #expect(body.range(of: #"(?i)\b(select|insert|update|delete)\b[\s\S]*\bfrom\b\s+"[a-z_]+""#, options: .regularExpression) == nil)
}

@Test func malformedServerIdIsAClean404() async throws {
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}))
        try await app.testing { client in
            let response = try await client.get("/api/servers/not-a-uuid/members", headers: [
                .authorization: "Bearer token",
                HTTPField.Name("X-Server-Id")!: "not-a-uuid",
            ])
            #expect(response.status == .notFound)
            #expect(bodyText(response) == "{\"error\":\"Server not found\"}")
            assertNoLeak(bodyText(response))
        }
    }
}

@Test func mismatchedServerHeaderStaysATyped4xx() async throws {
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}))
        try await app.testing { client in
            let mismatched = try await client.get("/api/servers/path-value/members", headers: [
                .authorization: "Bearer token",
                HTTPField.Name("X-Server-Id")!: "header-value",
            ])
            let code = mismatched.status.code
            #expect(code >= 400 && code < 500)
            #expect(bodyText(mismatched).contains("internal_server_error") == false)
            assertNoLeak(bodyText(mismatched))

            let pathId = "11111111-1111-4111-8111-111111111111"
            let headerId = "22222222-2222-4222-8222-222222222222"
            let typed = try await client.get("/api/servers/\(pathId)/members", headers: [
                .authorization: "Bearer token",
                HTTPField.Name("X-Server-Id")!: headerId,
            ])
            #expect(typed.status == .badRequest)
            #expect(bodyText(typed) == "{\"error\":\"X-Server-Id must match server id in URL\"}")
            assertNoLeak(bodyText(typed))
        }
    }
}

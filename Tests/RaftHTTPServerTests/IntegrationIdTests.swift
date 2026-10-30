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
]

private func assertNoLeak(_ body: String) {
    let lowered = body.lowercased()
    for marker in leakMarkers {
        #expect(lowered.contains(marker.lowercased()) == false)
    }
    #expect(body.range(of: #"(?i)\b(select|insert|update|delete)\b[\s\S]*\bfrom\b\s+"[a-z_]+""#, options: .regularExpression) == nil)
}

private func encodeURIComponent(_ value: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-_.!~*'()")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}

@Test func malformedIntegrationIdsAreClean404s() async throws {
    let swallowed = encodeURIComponent("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee这条你是不是没收到")
    let headers: HTTPFields = [
        .authorization: "Bearer token",
        HTTPField.Name("X-Server-Id")!: "33333333-3333-4333-8333-333333333333",
    ]
    let cases: [(path: (String) -> String, error: String)] = [
        ({ "/api/mcp/agents/\($0)" }, "Agent not found"),
        ({ "/api/integrations/agents/\($0)" }, "Agent not found"),
        ({ "/api/integrations/clients/\($0)/app-notifications" }, "App not found"),
        ({ "/api/integrations/clients/\($0)/share-link" }, "App not found"),
        ({ "/api/integrations/marketplace/\($0)/install/app-notifications" }, "App not found"),
    ]
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {}
        ))
        try await app.testing { client in
            for bad in ["not-a-uuid", swallowed] {
                for item in cases {
                    let response = try await client.get(URI(string: item.path(bad)), headers: headers)
                    #expect(response.status == .notFound)
                    #expect(bodyText(response) == "{\"error\":\"\(item.error)\"}")
                    #expect(response.headers[HTTPField.Name("X-Robots-Tag")!] == "noindex, nofollow")
                    assertNoLeak(bodyText(response))
                }
            }

            let id = "22222222-2222-4222-8222-222222222222"
            let mcp = try await client.get("/api/mcp/agents/\(id)", headers: headers)
            #expect(mcp.status == .notFound)
            #expect(bodyText(mcp) == "{\"error\":\"Agent not found\",\"code\":\"managed_mcp_agent_not_found\"}")
            assertNoLeak(bodyText(mcp))

            let share = try await client.get("/api/integrations/clients/\(id)/share-link", headers: headers)
            #expect(share.status == .notFound)
            #expect(bodyText(share) == "{\"error\":\"OAuth client share link not found\"}")

            let installed = try await client.get(
                "/api/integrations/marketplace/\(id)/install/app-notifications",
                headers: headers
            )
            #expect(installed.status == .notFound)
            #expect(bodyText(installed) == "{\"error\":\"Active app installation not found\"}")
        }
    }
}

import TestSupport
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

private let serverId = "33333333-3333-4333-8333-333333333333"

@Test func malformedMemberProfileIdIsAClean404() async throws {
    let swallowed = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee" + "这条你是不是没收到"
    // The pinned `/:id` lockdown runs before the handler, so the reader needs a
    // live membership to reach the profile's own member-id guard.
    let accounts = publicServerAuthAccounts([("member-profile-reader", "token")])
    accounts.oauth.addOwnedServer(
        id: serverId, slug: "member-profile", name: "Member Profile",
        ownerId: "member-profile-reader"
    )
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let headers: HTTPFields = [
                .authorization: "Bearer token",
                HTTPField.Name("X-Server-Id")!: serverId,
            ]
            for memberId in ["not-a-uuid", encodeURIComponent(swallowed)] {
                let response = try await client.get(
                    URI(string: "/api/servers/\(serverId)/members/\(memberId)/profile"),
                    headers: headers
                )
                #expect(response.status == .notFound)
                #expect(bodyText(response) == "{\"error\":\"Member not found\"}")
                #expect(response.headers[HTTPField.Name("X-Robots-Tag")!] == "noindex, nofollow")
                assertNoLeak(bodyText(response))
            }

            let mismatched = try await client.get(
                URI(string: "/api/servers/\(serverId)/members/not-a-uuid/profile"),
                headers: [
                    .authorization: "Bearer token",
                    HTTPField.Name("X-Server-Id")!: "22222222-2222-4222-8222-222222222222",
                ]
            )
            #expect(mismatched.status == .badRequest)
            #expect(bodyText(mismatched) == "{\"error\":\"X-Server-Id must match server id in URL\"}")
            assertNoLeak(bodyText(mismatched))
        }
    }
}

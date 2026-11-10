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

private let authHeaders: HTTPFields = [
    .authorization: "Bearer token",
    HTTPField.Name("X-Server-Id")!: "33333333-3333-4333-8333-333333333333",
]

@Test func malformedChannelMessageIdIsAClean404() async throws {
    let accounts = publicServerAuthAccounts([(userId: "11111111-1111-4111-8111-111111111111", token: "token")])
    accounts.oauth.addOwnedServer(id: "33333333-3333-4333-8333-333333333333", slug: "malformed-channel-read", name: "Malformed Channel Read", ownerId: "11111111-1111-4111-8111-111111111111")
    let messageId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    let swallowed = messageId + "这条你是不是没收到"
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            for path in [
                "/api/messages/channel/not-a-uuid",
                "/api/messages/channel/\(encodeURIComponent(swallowed))",
            ] {
                let response = try await client.get(URI(string: path), headers: authHeaders)
                #expect(response.status == .notFound)
                #expect(bodyText(response) == "{\"error\":\"Channel not found\"}")
                #expect(response.headers[HTTPField.Name("X-Robots-Tag")!] == "noindex, nofollow")
                assertNoLeak(bodyText(response))
            }

            let unknown = try await client.get(
                "/api/messages/channel/22222222-2222-4222-8222-222222222222",
                headers: authHeaders
            )
            #expect(unknown.status == .notFound)
            #expect(bodyText(unknown) == "{\"error\":\"Channel not found or not visible\"}")
            assertNoLeak(bodyText(unknown))
        }
    }
}

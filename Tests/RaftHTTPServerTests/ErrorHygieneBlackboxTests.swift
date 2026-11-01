import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct HygieneFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let serverSlug: String
    let channelId: String
    let messageId: String
    let token: String
}

private func makeHygieneFixture(suffix: String) async throws -> HygieneFixture {
    let accounts = EmailLoginDirectory()
    let number = Int(suffix) ?? 0
    let serverId = String(format: "33333333-3333-4333-8333-%012d", 910_000 + number)
    let ownerId = String(format: "11111111-1111-4111-8111-%012d", 910_000 + number)
    let email = "hygiene-\(suffix)@slock.test"
    accounts.addAccount(id: ownerId, email: email, password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    let slug = "hygiene-\(suffix)"
    accounts.oauth.addOwnedServer(id: serverId, slug: slug, name: "Hygiene Ids", ownerId: ownerId)
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "hygiene-ids-\(suffix)", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "hygiene-ids-\(suffix)")
    accounts.oauth.addChannelHuman(channelId: channel, userId: ownerId)
    let messageId = accounts.addChannelMessageForTesting(channelId: channel, content: "hello", senderId: ownerId)
    return HygieneFixture(
        accounts: accounts,
        serverId: serverId,
        serverSlug: slug,
        channelId: channel,
        messageId: messageId,
        token: ""
    )
}

private func hygieneLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
}

private let hygieneLeakMarkers = [
    "invalid input syntax for type uuid",
    "Failed query",
    "params:",
    "23505",
    "23503",
    "42P01",
    "22P02",
]

private func assertHygieneNoLeak(_ body: String, _ context: String) {
    let lowered = body.lowercased()
    for marker in hygieneLeakMarkers {
        #expect(!lowered.contains(marker.lowercased()), "\(context) leaked \(marker): \(body)")
    }
    #expect(body.range(of: #"(?i)\b(select|insert|update|delete)\b[\s\S]*\bfrom\b\s+"[a-z_]+""#, options: .regularExpression) == nil)
}

@Test func malformedServerIdAndMismatchedHeaderStayTyped4xx() async throws {
    let fixture = try await makeHygieneFixture(suffix: "941")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let token = try await hygieneLogin(client, email: "hygiene-941@slock.test")

            var malformedHeaders = HTTPFields()
            malformedHeaders[.authorization] = "Bearer \(token)"
            malformedHeaders[HTTPField.Name("X-Server-Id")!] = "not-a-uuid"
            let malformed = try await client.get(URI(string: "/api/servers/not-a-uuid/members"), headers: malformedHeaders)
            #expect(malformed.status == .notFound)
            #expect(try JSONSerialization.jsonObject(with: Data((malformed.body.string ?? "").utf8)) as? [String: Any] != nil)
            let malformedBody = (try? JSONSerialization.jsonObject(with: Data((malformed.body.string ?? "").utf8))) as? [String: Any]
            #expect(malformedBody?["error"] as? String == "Server not found")
            assertHygieneNoLeak(malformed.body.string ?? "", "malformed server id")

            var mismatchHeaders = HTTPFields()
            mismatchHeaders[.authorization] = "Bearer \(token)"
            mismatchHeaders[HTTPField.Name("X-Server-Id")!] = "header-value"
            let mismatch = try await client.get(URI(string: "/api/servers/path-value/members"), headers: mismatchHeaders)
            #expect(mismatch.status.code >= 400 && mismatch.status.code < 500)
            #expect(!(mismatch.body.string ?? "").contains("internal_server_error"))
            assertHygieneNoLeak(mismatch.body.string ?? "", "mismatched header")
        }
    }
}

@Test func malformedPathAndQueryIDsOnIDKeyedRoutesAreClean4xx() async throws {
    let fixture = try await makeHygieneFixture(suffix: "942")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let token = try await hygieneLogin(client, email: "hygiene-942@slock.test")
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = fixture.serverId

            let cjk = "\(fixture.messageId)这条你是不是没收到"
            let encodedCJK = cjk.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? cjk
            let malformed = ["not-a-uuid", encodedCJK]
            let cases: [(String, Int)] = [
                ("/api/messages/context/", 400),
                ("/api/messages/channel/", 404),
                ("/api/servers/\(fixture.serverId)/members/", 404),
                ("/api/public/servers/\(fixture.serverSlug)/channels/", 404),
                ("/api/public/servers/\(fixture.serverSlug)/threads/", 404),
                ("/api/mcp/agents/", 404),
                ("/api/integrations/agents/", 404),
                ("/api/integrations/clients/", 404),
            ]
            for (prefix, status) in cases {
                for bad in malformed {
                    let suffix: String
                    if prefix.hasSuffix("members/") {
                        suffix = "\(bad)/profile"
                    } else if prefix.hasSuffix("clients/") {
                        suffix = "\(bad)/app-notifications"
                    } else {
                        suffix = bad
                    }
                    let response = try await client.get(URI(string: prefix + suffix), headers: headers)
                    #expect(response.status.code == status, "\(prefix + suffix): \(response.body.string ?? "")")
                    assertHygieneNoLeak(response.body.string ?? "", prefix + suffix)
                }
            }

            let badQuery = try await client.get(
                URI(string: "/api/messages/context/\(fixture.messageId)?channelId=not-a-uuid"),
                headers: headers
            )
            #expect(badQuery.status == .badRequest)
            assertHygieneNoLeak(badQuery.body.string ?? "", "bad context channel")

            let shortId = try await client.get(
                URI(string: "/api/messages/context/\(String(fixture.messageId.prefix(8)))?channelId=\(fixture.channelId)"),
                headers: headers
            )
            #expect(shortId.status == .ok)
        }
    }
}

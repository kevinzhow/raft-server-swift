import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private func lookupBody(_ response: ClientResponse) throws -> [String: Any] {
    let data = Data((response.body.string ?? "").utf8)
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

@Test func clientLookupReturnsTheRegisteredAppForTheSelectedServer() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111214"
    let outsiderId = "11111111-1111-4111-8111-111111111215"
    let serverA = "33333333-3333-4333-8333-333333333408"
    let serverB = "33333333-3333-4333-8333-333333333409"
    accounts.addAccount(id: ownerId, email: "oauth-lookup-214@slock.test", password: "password123")
    accounts.addAccount(id: outsiderId, email: "oauth-outsider-215@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.markEmailVerified(userId: outsiderId)
    accounts.oauth.addOwnedServer(id: serverA, slug: "oauth-lookup-a-214", name: "OAuth Lookup A", ownerId: ownerId)
    accounts.oauth.addOwnedServer(id: serverB, slug: "oauth-lookup-b-214", name: "OAuth Lookup B", ownerId: ownerId)
    _ = try accounts.oauth.createClient(
        serverId: serverA,
        createdByUserId: ownerId,
        name: "Actual Daily App",
        clientId: "oauth-lookup-214",
        description: "Registered for this server",
        homepageUrl: "https://daily.example.test",
        returnUrl: "https://daily.example.test/login/slock/callback"
    )

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func login(_ email: String) async throws -> String {
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                    request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
                }
                #expect(response.status == .ok)
                return try lookupBody(response)["accessToken"] as? String ?? ""
            }

            let ownerToken = try await login("oauth-lookup-214@slock.test")
            let outsiderToken = try await login("oauth-outsider-215@slock.test")

            func lookup(_ token: String, _ serverId: String) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(token)"
                return try await client.send(
                    .get,
                    headers: headers,
                    to: "/api/oauth/clients/lookup?client_id=oauth-lookup-214&server_id=\(serverId)"
                )
            }

            let found = try await lookup(ownerToken, serverA)
            #expect(found.status == .ok)
            let body = try lookupBody(found)
            #expect(body["clientId"] as? String == "oauth-lookup-214")
            #expect(body["name"] as? String == "Actual Daily App")
            #expect(body["description"] as? String == "Registered for this server")
            #expect(body["homepageUrl"] as? String == "https://daily.example.test")
            #expect(body["returnUrl"] as? String == "https://daily.example.test/login/slock/callback")
            #expect(body["logoUrl"] == nil || body["logoUrl"] is NSNull)
            #expect(body["clientSecret"] == nil)

            #expect(try await lookup(ownerToken, serverB).status == .notFound)

            let nonMember = try await lookup(outsiderToken, serverA)
            #expect(nonMember.status == .notFound)
            let nonMemberBody = try lookupBody(nonMember)
            #expect(nonMemberBody["error"] as? String == "OAuth client not found for server")
            #expect(nonMemberBody["name"] == nil)
            #expect(nonMemberBody["returnUrl"] == nil)
        }
    }
}

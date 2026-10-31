import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func installedAppProjectionFailsClosedUntilReferencesAreEnabled() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111361"
    let memberId = "11111111-1111-4111-8111-111111111362"
    let serverId = "33333333-3333-4333-8333-333333333509"
    accounts.addAccount(id: ownerId, email: "apps-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "apps-member@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "apps", name: "Apps", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")

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
                return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            }
            func headers(_ token: String) -> HTTPFields {
                var fields = HTTPFields()
                fields[.authorization] = "Bearer \(token)"
                fields[HTTPField.Name("X-Server-Id")!] = serverId
                return fields
            }
            func apps(_ token: String) async throws -> ClientResponse {
                try await client.send(.get, headers: headers(token), to: "/api/servers/\(serverId)/apps")
            }
            let ownerToken = try await login("apps-owner@slock.test")
            let memberToken = try await login("apps-member@slock.test")

            #expect(try await apps(ownerToken).status == .notFound)
            accounts.enableComposerResourceReferences(serverId: serverId, enabled: true)
            let response = try await apps(memberToken)
            #expect(response.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
            let appsList = body?["apps"] as? [[String: Any]] ?? []
            #expect(appsList.compactMap { $0["appId"] as? String } == ["system.cleaner", "system.reminder"])
            #expect(appsList.first { $0["appId"] as? String == "system.cleaner" }?["displayName"] as? String == "Memory Cleaner")
            #expect(!appsList.contains { $0["appId"] as? String == "system.canary" })
        }
    }
}

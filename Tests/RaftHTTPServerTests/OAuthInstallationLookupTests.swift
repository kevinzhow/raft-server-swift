import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private func lookupObject(_ response: ClientResponse) throws -> [String: Any] {
    let data = Data((response.body.string ?? "").utf8)
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

@Test func installationLookupFindsOnlyTheAuthenticatedAppsActiveInstall() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111201"
    let publisherServerId = "33333333-3333-4333-8333-333333333393"
    let targetServerId = "33333333-3333-4333-8333-333333333394"
    accounts.addAccount(id: userId, email: "oauth-lookup-201@slock.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    accounts.oauth.addOwnedServer(id: publisherServerId, slug: "oauth-lookup-publisher-201", name: "OAuth Lookup Publisher", ownerId: userId)
    accounts.oauth.addOwnedServer(id: targetServerId, slug: "oauth-lookup-target-201", name: "OAuth Lookup Target", ownerId: userId)
    let created = try accounts.oauth.createClient(
        serverId: publisherServerId,
        createdByUserId: userId,
        name: "OAuth Installation Discovery Client",
        clientId: "oauth-discovery-201",
        appType: "third_party_global"
    )
    let installationId = accounts.oauth.installClient(
        serverId: targetServerId,
        clientRecordId: created.id,
        installedByUserId: userId,
        groups: ["server"]
    )

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let pair = Data("\(created.clientId):\(created.clientSecret)".utf8).base64EncodedString()
            var headers = HTTPFields()
            headers[.authorization] = "Basic \(pair)"
            headers[.contentType] = "application/json"
            let discovered = try await client.send(.post, headers: headers, to: "/api/oauth/installations/lookup") { request in
                request.body = .init(string: "{\"server_id\":\"\(targetServerId)\"}")
            }
            #expect(discovered.status == .ok)
            #expect(discovered.headers[HTTPField.Name("Cache-Control")!] == "private, no-store")
            let body = try lookupObject(discovered)
            #expect(body["installation_id"] as? String == installationId)
            #expect(body["server_id"] as? String == targetServerId)
            let setup = body["setup"] as? [String: Any]
            #expect(setup?["status"] as? String == "not_required")
            #expect(setup?["url"] == nil || setup?["url"] is NSNull)
            #expect(setup?["description"] == nil || setup?["description"] is NSNull)
            #expect(setup?["completedAt"] == nil || setup?["completedAt"] is NSNull)
            #expect((setup?["revision"] as? NSNumber)?.intValue == 1)

            let scoped = try await client.send(.post, headers: headers, to: "/oidc/\(targetServerId)/api/oauth/installations/lookup") { request in
                request.body = .init(string: "{\"server_id\":\"\(targetServerId)\"}")
            }
            #expect(scoped.status == .notFound)
        }
    }
}

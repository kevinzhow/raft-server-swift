import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private func lookupObject(_ response: ClientResponse) throws -> [String: Any] {
    let data = Data((response.body.string ?? "").utf8)
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

@Test func installationLookupFindsOnlyTheAuthenticatedAppsActiveInstall() async throws {
    let scene = OAuthScene()
    let userId = "11111111-1111-4111-8111-111111111201"
    let publisherServerId = "33333333-3333-4333-8333-333333333393"
    let targetServerId = "33333333-3333-4333-8333-333333333394"
    scene.auth.addAccount(id: userId, email: "oauth-lookup-201@slock.test", password: "password123")
    scene.auth.markEmailVerified(userId: userId)
    scene.oauth.addOwnedServer(id: publisherServerId, slug: "oauth-lookup-publisher-201", name: "OAuth Lookup Publisher", ownerId: userId)
    scene.oauth.addOwnedServer(id: targetServerId, slug: "oauth-lookup-target-201", name: "OAuth Lookup Target", ownerId: userId)
    let created = try scene.oauth.createClient(
        serverId: publisherServerId,
        createdByUserId: userId,
        name: "OAuth Installation Discovery Client",
        clientId: "oauth-discovery-201",
        appType: "third_party_global"
    )
    let installationId = scene.oauth.installClient(
        serverId: targetServerId,
        clientRecordId: created.id,
        installedByUserId: userId,
        groups: ["server"]
    )

    try await withApp { app in
        configureOAuthScene(app, scene: scene)
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

@Test func installationLookupHidesOtherClientsAndInactiveInstalls() async throws {
    let scene = OAuthScene()
    let userId = "11111111-1111-4111-8111-111111111202"
    let publisherServerId = "33333333-3333-4333-8333-333333333395"
    let targetServerId = "33333333-3333-4333-8333-333333333396"
    let otherServerId = "33333333-3333-4333-8333-333333333397"
    scene.auth.addAccount(id: userId, email: "oauth-lookup-202@slock.test", password: "password123")
    scene.auth.markEmailVerified(userId: userId)
    scene.oauth.addOwnedServer(id: publisherServerId, slug: "oauth-lookup-publisher-202", name: "OAuth Lookup Publisher", ownerId: userId)
    scene.oauth.addOwnedServer(id: targetServerId, slug: "oauth-lookup-target-202", name: "OAuth Lookup Target", ownerId: userId)
    scene.oauth.addOwnedServer(id: otherServerId, slug: "oauth-lookup-other-202", name: "OAuth Lookup Other", ownerId: userId)
    let primary = try scene.oauth.createClient(
        serverId: publisherServerId,
        createdByUserId: userId,
        name: "OAuth Lookup Primary",
        clientId: "oauth-lookup-primary-202",
        appType: "third_party_global"
    )
    let other = try scene.oauth.createClient(
        serverId: publisherServerId,
        createdByUserId: userId,
        name: "OAuth Lookup Other",
        clientId: "oauth-lookup-other-202",
        appType: "third_party_global"
    )
    let serverLocal = try scene.oauth.createClient(
        serverId: targetServerId,
        createdByUserId: userId,
        name: "OAuth Lookup Server Local",
        clientId: "oauth-lookup-local-202",
        appType: "server_local"
    )
    let installationId = scene.oauth.installClient(
        serverId: targetServerId,
        clientRecordId: primary.id,
        installedByUserId: userId,
        groups: ["server"]
    )
    _ = scene.oauth.installClient(
        serverId: targetServerId,
        clientRecordId: serverLocal.id,
        installedByUserId: userId,
        groups: []
    )

    try await withApp { app in
        configureOAuthScene(app, scene: scene)
        try await app.testing { client in
            func lookup(
                _ clientId: String,
                _ secret: String,
                serverId: String,
                extra: String = ""
            ) async throws -> ClientResponse {
                let pair = Data("\(clientId):\(secret)".utf8).base64EncodedString()
                var headers = HTTPFields()
                headers[.authorization] = "Basic \(pair)"
                headers[.contentType] = "application/json"
                return try await client.send(.post, headers: headers, to: "/api/oauth/installations/lookup") { request in
                    request.body = .init(string: "{\"server_id\":\"\(serverId)\"\(extra)}")
                }
            }

            let crossServer = try await lookup(primary.clientId, primary.clientSecret, serverId: otherServerId)
            #expect(crossServer.status == .notFound)
            #expect(try lookupObject(crossServer)["error"] as? String == "Active installation not found")

            let crossClient = try await lookup(
                other.clientId,
                other.clientSecret,
                serverId: targetServerId,
                extra: ",\"client_id\":\"\(primary.clientId)\""
            )
            #expect(crossClient.status == .notFound)
            #expect(try lookupObject(crossClient)["error"] as? String == "Active installation not found")

            scene.oauth.setInstallationStatus(id: installationId, status: "suspended")
            let suspended = try await lookup(primary.clientId, primary.clientSecret, serverId: targetServerId)
            #expect(suspended.status == .notFound)
            #expect(try lookupObject(suspended)["error"] as? String == "Active installation not found")

            scene.oauth.setInstallationStatus(id: installationId, status: "active")
            scene.oauth.setClientEnabled(clientRecordId: primary.id, enabled: false)
            let disabledApp = try await lookup(primary.clientId, primary.clientSecret, serverId: targetServerId)
            #expect(disabledApp.status == .unauthorized)

            scene.oauth.setClientEnabled(clientRecordId: primary.id, enabled: true)
            scene.oauth.setClientEnabled(clientRecordId: serverLocal.id, enabled: false)
            let disabledServerLocal = try await lookup(serverLocal.clientId, serverLocal.clientSecret, serverId: targetServerId)
            #expect(disabledServerLocal.status == .notFound)
            #expect(try lookupObject(disabledServerLocal)["error"] as? String == "Active installation not found")

            let malformed = try await lookup(primary.clientId, primary.clientSecret, serverId: "not-a-server-id")
            #expect(malformed.status == .badRequest)
            #expect(try lookupObject(malformed)["error"] as? String == "server_id must be a Server ID")
        }
    }
}

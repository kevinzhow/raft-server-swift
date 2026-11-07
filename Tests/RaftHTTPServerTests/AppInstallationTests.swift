import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import TestSupport
import Testing
import Vapor
import VaporTesting

private func bodyObject(_ response: ClientResponse) throws -> [String: Any] {
    let data = Data((response.body.string ?? "").utf8)
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

@Test func appInstallationProjectionSeparatesUserAndInstallationCredentials() async throws {
    let scene = InstallationScene()
    let userId = "11111111-1111-4111-8111-111111111199"
    let serverId = "33333333-3333-4333-8333-333333333391"
    scene.auth.addAccount(id: userId, email: "app-installation-199@slock.test", password: "password123")
    scene.auth.markEmailVerified(userId: userId)
    scene.installations.seedServer(id: serverId, slug: "app-installation-199", name: "App Installation Projection", ownerId: userId)
    let created = try scene.installations.seedApp(
        serverId: serverId,
        createdByUserId: userId,
        name: "App Installation Projection Client",
        clientId: "app-installation-199",
        appType: "third_party_global"
    )
    let installationId = scene.installations.seedActiveInstallation(
        serverId: serverId,
        clientRecordId: created.id,
        installedByUserId: userId,
        groups: ["server"]
    )

    try await withInstallationSceneApp(scene) { client in
        var loginHeaders = HTTPFields()
        loginHeaders[.contentType] = "application/json"
        let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
            request.body = .init(string: "{\"email\":\"app-installation-199@slock.test\",\"password\":\"password123\"}")
        }
        #expect(login.status == .ok)
        let userToken = try bodyObject(login)["accessToken"] as? String ?? ""

        var userHeaders = HTTPFields()
        userHeaders[.authorization] = "Bearer \(userToken)"
        let userRead = try await client.send(.get, headers: userHeaders, to: "/api/app-installation/server")
        #expect(userRead.status == .unauthorized)

        var mintHeaders = HTTPFields()
        mintHeaders[.contentType] = "application/json"
        let minted = try await client.send(.post, headers: mintHeaders, to: "/api/oauth/installation-token") { request in
            request.body = .init(string: "{\"client_id\":\"\(created.clientId)\",\"client_secret\":\"\(created.clientSecret)\",\"installation_id\":\"\(installationId)\"}")
        }
        #expect(minted.status == .ok)
        let installationToken = try bodyObject(minted)["access_token"] as? String ?? ""

        var installationHeaders = HTTPFields()
        installationHeaders[.authorization] = "Bearer \(installationToken)"
        let projection = try await client.send(.get, headers: installationHeaders, to: "/api/app-installation/server")
        #expect(projection.status == .ok)
        #expect(projection.headers[HTTPField.Name("Cache-Control")!] == "private, no-store")
        let projectionBody = try bodyObject(projection)
        #expect(projectionBody["installation_id"] as? String == installationId)
        #expect((projectionBody["server"] as? [String: Any])?["id"] as? String == serverId)

        let channels = try await client.send(.get, headers: installationHeaders, to: "/api/app-installation/channels")
        #expect(channels.status == .forbidden)
    }
}

@Test func retiredAndPlatformManagedAppsLoseInstallationCredentials() async throws {
    let scene = InstallationScene()
    let userId = "11111111-1111-4111-8111-111111111200"
    let serverId = "33333333-3333-4333-8333-333333333392"
    scene.auth.addAccount(id: userId, email: "app-retired-200@slock.test", password: "password123")
    scene.auth.markEmailVerified(userId: userId)
    scene.installations.seedServer(id: serverId, slug: "app-retired-200", name: "App Retirement", ownerId: userId)
    let created = try scene.installations.seedApp(
        serverId: serverId,
        createdByUserId: userId,
        name: "App Retirement Client",
        clientId: "app-retired-200",
        appType: "third_party_global"
    )
    let installationId = scene.installations.seedActiveInstallation(
        serverId: serverId,
        clientRecordId: created.id,
        installedByUserId: userId,
        groups: ["server"]
    )
    let tokenCountBefore = scene.installations.installationTokenCount(clientRecordId: created.id)

    try await withInstallationSceneApp(scene) { client in
        var mintHeaders = HTTPFields()
        mintHeaders[.contentType] = "application/json"
        let minted = try await client.send(.post, headers: mintHeaders, to: "/api/oauth/installation-token") { request in
            request.body = .init(string: "{\"client_id\":\"\(created.clientId)\",\"client_secret\":\"\(created.clientSecret)\",\"installation_id\":\"\(installationId)\"}")
        }
        #expect(minted.status == .ok)
        let installationToken = try bodyObject(minted)["access_token"] as? String ?? ""
        #expect(scene.installations.installationTokenCount(clientRecordId: created.id) == tokenCountBefore + 1)

        var headers = HTTPFields()
        headers[.authorization] = "Bearer \(installationToken)"
        #expect(try await client.send(.get, headers: headers, to: "/api/app-installation/server").status == .ok)

        scene.installations.setAppType(clientRecordId: created.id, appType: "slock_builtin")
        #expect(try await client.send(.get, headers: headers, to: "/api/app-installation/server").status == .unauthorized)
        let retiredMint = try await client.send(.post, headers: mintHeaders, to: "/api/oauth/installation-token") { request in
            request.body = .init(string: "{\"client_id\":\"\(created.clientId)\",\"client_secret\":\"\(created.clientSecret)\",\"installation_id\":\"\(installationId)\"}")
        }
        #expect(retiredMint.status == .unauthorized)
        #expect(scene.installations.installationTokenCount(clientRecordId: created.id) == tokenCountBefore + 1)

        scene.installations.setAppType(clientRecordId: created.id, appType: "third_party_global")
        scene.installations.registerExternalApp(clientRecordId: created.id, provider: "slack", state: "active")
        #expect(try await client.send(.get, headers: headers, to: "/api/app-installation/server").status == .unauthorized)
        let platformMint = try await client.send(.post, headers: mintHeaders, to: "/api/oauth/installation-token") { request in
            request.body = .init(string: "{\"client_id\":\"\(created.clientId)\",\"client_secret\":\"\(created.clientSecret)\",\"installation_id\":\"\(installationId)\"}")
        }
        #expect(platformMint.status == .unauthorized)
        #expect(scene.installations.installationTokenCount(clientRecordId: created.id) == tokenCountBefore + 1)
    }
}

/// The focused scene does not replace full-Fallback wiring coverage. This app
/// owns its separate legacy graph; no scene service or fixture is mixed into it.
@Test func appInstallationFullFallbackMountKeepsAllThreeCredentialRoutes() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111199"
    let serverId = "33333333-3333-4333-8333-333333333391"
    accounts.oauth.addOwnedServer(id: serverId, slug: "installation-full-mount", name: "Full Mount", ownerId: userId)
    let created = try accounts.oauth.createClient(
        serverId: serverId, createdByUserId: userId, name: "Full Mount",
        clientId: "installation-full-mount", appType: "third_party_global"
    )
    let installationId = accounts.oauth.installClient(
        serverId: serverId, clientRecordId: created.id, installedByUserId: userId, groups: ["server", "channel"]
    )
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            let minted = try await client.send(.post, headers: headers, to: "/api/oauth/installation-token") {
                $0.body = .init(string: "{\"clientId\":\"\(created.clientId)\",\"clientSecret\":\"\(created.clientSecret)\",\"installationId\":\"\(installationId)\"}")
            }
            #expect(minted.status == .ok)
            let token = try #require(try bodyObject(minted)["access_token"] as? String)
            headers[.authorization] = "Bearer \(token)"
            let server = try await client.get("/api/app-installation/server", headers: headers)
            #expect(server.status == .ok)
            #expect(server.body.string == "{\"installation_id\":\"\(installationId)\",\"server\":{\"id\":\"\(serverId)\",\"name\":\"Full Mount\",\"slug\":\"installation-full-mount\",\"avatar_url\":null}}")
            let channels = try await client.get("/api/app-installation/channels", headers: headers)
            #expect(channels.status == .ok)
            #expect(channels.body.string == "{\"installation_id\":\"\(installationId)\",\"channels\":[]}")
            for response in [minted, server, channels] {
                #expect(response.headers[HTTPField.Name("Cache-Control")!] == "private, no-store")
            }
        }
    }
}

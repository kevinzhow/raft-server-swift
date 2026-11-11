import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

/// Uploads write the image bytes to the profile-asset store, publish the
/// capability URL, and the public route serves those exact bytes with the
/// immutable cache policy. The deployment has no WebP encoder in its release
/// closure, so the stored image keeps its real content type; see
/// `docs/DEVIATIONS.md` D23.
private let oneByOneGIF = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==")!

private func multipart(
    field: String,
    filename: String,
    mimeType: String,
    bytes: Data,
    boundary: String = "raft-profile-assets"
) -> (contentType: String, body: Data) {
    var body = Data()
    body.append(Data("--\(boundary)\r\n".utf8))
    body.append(Data("Content-Disposition: form-data; name=\"\(field)\"; filename=\"\(filename)\"\r\n".utf8))
    body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
    body.append(bytes)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))
    return ("multipart/form-data; boundary=\(boundary)", body)
}

private func json(_ response: ClientResponse) throws -> [String: Any] {
    (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

private func login(_ client: any TestClient, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return try json(response)["accessToken"] as? String ?? ""
}

private func upload(
    _ client: any TestClient,
    path: String,
    token: String,
    field: String,
    filename: String,
    mimeType: String,
    bytes: Data,
    serverId: String? = nil
) async throws -> ClientResponse {
    let form = multipart(field: field, filename: filename, mimeType: mimeType, bytes: bytes)
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = form.contentType
    if let serverId { headers[HTTPField.Name("X-Server-Id")!] = serverId }
    return try await client.send(.post, headers: headers, to: URI(string: path)) { request in
        request.body = .init(data: form.body)
    }
}

@Test func userAvatarStoresAndServesBytesOnThePublishedPath() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111651"
    accounts.addAccount(id: userId, email: "profile-assets-user@slock.test", password: "password123")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        ))
        try await app.testing { client in
            let token = try await login(client, email: "profile-assets-user@slock.test")
            let uploaded = try await upload(
                client, path: "/api/auth/me/avatar", token: token, field: "avatar",
                filename: "avatar.gif", mimeType: "image/gif", bytes: oneByOneGIF
            )
            #expect(uploaded.status == .ok, "user avatar body: \(uploaded.body.string ?? "")")
            let avatarURL = try #require(try json(uploaded)["avatarUrl"] as? String)
            #expect(avatarURL.wholeMatch(of: /^\/api\/avatars\/users\/[0-9a-f]{32}\.webp$/) != nil)

            var served = try await client.get(URI(string: avatarURL))
            #expect(served.status == .ok)
            #expect(served.headers[.contentType] == "image/gif")
            #expect(served.headers[.cacheControl] == "public, max-age=31536000, immutable")
            #expect((try await served.body.collect() ?? Data()) == oneByOneGIF)

            let me = try await client.get(URI(string: "/api/auth/me"), headers: {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(token)"
                return headers
            }())
            #expect(try json(me)["avatarUrl"] as? String == avatarURL)

            let badFormat = try await upload(
                client, path: "/api/auth/me/avatar", token: token, field: "avatar",
                filename: "avatar.txt", mimeType: "text/plain", bytes: Data("not an image".utf8)
            )
            #expect(badFormat.status == .badRequest)
            #expect(try json(badFormat)["error"] as? String == "Only image files are allowed (JPEG, PNG, GIF, WebP)")
            #expect(try json(badFormat)["errorCode"] as? String == "PROFILE_AVATAR_BAD_FORMAT")

            let oversized = try await upload(
                client, path: "/api/auth/me/avatar", token: token, field: "avatar",
                filename: "huge.png", mimeType: "image/png", bytes: Data(repeating: 0, count: 5 * 1024 * 1024 + 1)
            )
            #expect(oversized.status == .badRequest)
            #expect(try json(oversized)["error"] as? String == "Avatar image must be 5 MB or smaller")
            #expect(try json(oversized)["errorCode"] as? String == "PROFILE_AVATAR_TOO_LARGE")
            #expect(try json(oversized)["maxBytes"] as? Int == 5 * 1024 * 1024)
        }
    }
}

@Test func serverAvatarStoresAndServesBytesOnThePublishedPath() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111652"
    let serverId = "33333333-3333-4333-8333-333333333677"
    accounts.addAccount(id: ownerId, email: "profile-assets-server@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "profile-assets", name: "Profile Assets", ownerId: ownerId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        ))
        try await app.testing { client in
            let token = try await login(client, email: "profile-assets-server@slock.test")
            let uploaded = try await upload(
                client, path: "/api/servers/\(serverId)/avatar", token: token, field: "avatar",
                filename: "server.gif", mimeType: "image/gif", bytes: oneByOneGIF, serverId: serverId
            )
            #expect(uploaded.status == .ok, "server avatar body: \(uploaded.body.string ?? "")")
            let avatarURL = try #require(try json(uploaded)["avatarUrl"] as? String)
            #expect(avatarURL.wholeMatch(of: /^\/api\/avatars\/server-[0-9a-f-]+\/[0-9a-f]{32}\.webp$/) != nil)

            var served = try await client.get(URI(string: avatarURL))
            #expect(served.status == .ok)
            #expect(served.headers[.contentType] == "image/gif")
            #expect((try await served.body.collect() ?? Data()) == oneByOneGIF)
        }
    }
}

@Test func agentAvatarUsesTheServerNamespaceAndServesBytes() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111653"
    let serverId = "33333333-3333-4333-8333-333333333678"
    accounts.addAccount(id: ownerId, email: "profile-assets-agent@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "profile-assets-agent", name: "Profile Assets Agent", ownerId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "asset-agent", creatorUserId: ownerId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        ))
        try await app.testing { client in
            let token = try await login(client, email: "profile-assets-agent@slock.test")
            let uploaded = try await upload(
                client, path: "/api/agents/\(agentId)/avatar", token: token, field: "avatar",
                filename: "agent.gif", mimeType: "image/gif", bytes: oneByOneGIF, serverId: serverId
            )
            #expect(uploaded.status == .ok, "agent avatar body: \(uploaded.body.string ?? "")")
            let avatarURL = try #require(try json(uploaded)["avatarUrl"] as? String)
            #expect(avatarURL == "/api/avatars/\(serverId)/\(avatarURL.split(separator: "/").last ?? "")")
            #expect(avatarURL.hasSuffix(".webp"))

            var served = try await client.get(URI(string: avatarURL))
            #expect(served.status == .ok)
            #expect((try await served.body.collect() ?? Data()) == oneByOneGIF)
        }
    }
}

@Test func avatarRouteRejectsInvalidFilenamesAndUnknownObjects() async throws {
    let accounts = EmailLoginDirectory()
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        ))
        try await app.testing { client in
            let invalid = try await client.get(URI(string: "/api/avatars/users/not-a-content-hash.webp"))
            #expect(invalid.status == .badRequest)
            #expect(try json(invalid)["error"] as? String == "Invalid filename")

            let unknown = try await client.get(
                URI(string: "/api/avatars/users/0123456789abcdef0123456789abcdef.webp")
            )
            #expect(unknown.status == .notFound)
            #expect(try json(unknown)["error"] as? String == "Avatar not found")

            let invalidLogo = try await client.get(
                URI(string: "/api/integration-logos/00000000-0000-4000-8000-000000000000/short.webp")
            )
            #expect(invalidLogo.status == .badRequest)
            #expect(try json(invalidLogo)["error"] as? String == "Invalid filename")
        }
    }
}

@Test func integrationLogoStoresListsServesAndClearsBytes() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111654"
    let serverId = "33333333-3333-4333-8333-333333333679"
    accounts.addAccount(id: ownerId, email: "profile-assets-logo@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "profile-assets-logo", name: "Profile Assets Logo", ownerId: ownerId)
    let client = try accounts.oauth.createClient(
        serverId: serverId, createdByUserId: ownerId, name: "Logo App", clientId: "logo-app"
    )

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        ))
        try await app.testing { http in
            let token = try await login(http, email: "profile-assets-logo@slock.test")
            let uploaded = try await upload(
                http, path: "/api/integrations/clients/\(client.id)/logo", token: token, field: "logo",
                filename: "logo.gif", mimeType: "image/gif", bytes: oneByOneGIF, serverId: serverId
            )
            #expect(uploaded.status == .ok, "logo body: \(uploaded.body.string ?? "")")
            let body = try json(uploaded)
            #expect(body["id"] as? String == client.id)
            let logoURL = try #require(body["logoUrl"] as? String)
            #expect(logoURL.wholeMatch(of: /^\/api\/integration-logos\/[0-9a-f-]+\/[0-9a-f]{32}\.webp$/) != nil)

            var served = try await http.get(URI(string: logoURL))
            #expect(served.status == .ok)
            #expect(served.headers[.contentType] == "image/gif")
            #expect(served.headers[.cacheControl] == "public, max-age=31536000, immutable")
            #expect((try await served.body.collect() ?? Data()) == oneByOneGIF)

            var listHeaders = HTTPFields()
            listHeaders[.authorization] = "Bearer \(token)"
            listHeaders[HTTPField.Name("X-Server-Id")!] = serverId
            let listed = try await http.get(URI(string: "/api/integrations/clients"), headers: listHeaders)
            #expect(listed.status == .ok)
            let rows = (try JSONSerialization.jsonObject(with: Data((listed.body.string ?? "").utf8))) as? [[String: Any]] ?? []
            #expect(rows.first { $0["id"] as? String == client.id }?["logoUrl"] as? String == logoURL)

            let cleared = try await http.send(
                .delete, headers: listHeaders, to: URI(string: "/api/integrations/clients/\(client.id)/logo")
            )
            #expect(cleared.status == .ok)
            #expect((try json(cleared)["logoUrl"]) is NSNull)

            let gone = try await http.get(URI(string: logoURL))
            #expect(gone.status == .notFound)
            #expect(try json(gone)["error"] as? String == "Logo not found")
        }
    }
}

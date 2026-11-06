import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private let sharePNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=") ?? Data()
private let shareBoundary = "share-contract-boundary"

private struct ShareFixture {
    let accounts: EmailLoginDirectory
    let ownerId: String
    let guestId: String
    let serverId: String
    let channelId: String
    let otherServerId: String
    let otherChannelId: String
    let ownerToken: String
    let guestToken: String
}

private func makeShareFixture() -> ShareFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111629"
    let guestId = "11111111-1111-4111-8111-111111111630"
    let otherOwnerId = "11111111-1111-4111-8111-111111111631"
    let serverId = "33333333-3333-4333-8333-333333333671"
    let otherServerId = "33333333-3333-4333-8333-333333333672"
    for (id, email) in [
        (ownerId, "share-contract-owner@slock.test"),
        (guestId, "share-contract-guest@slock.test"),
        (otherOwnerId, "share-contract-other@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "share-contract", name: "Share Contract", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: guestId, role: "guest")
    accounts.oauth.addOwnedServer(id: otherServerId, slug: "share-other", name: "Share Other", ownerId: otherOwnerId)
    return ShareFixture(
        accounts: accounts,
        ownerId: ownerId,
        guestId: guestId,
        serverId: serverId,
        channelId: accounts.oauth.createChannel(serverId: serverId, name: "general", creatorUserId: ownerId),
        otherServerId: otherServerId,
        otherChannelId: accounts.oauth.createChannel(serverId: otherServerId, name: "secret", creatorUserId: otherOwnerId),
        ownerToken: accounts.mintAccessTokenForTesting(userId: ownerId),
        guestToken: accounts.mintAccessTokenForTesting(userId: guestId)
    )
}

private func shareForm(channelId: String?, image: Data?, filename: String = "raft-thread.png") -> Data {
    var data = Data()
    if let channelId {
        data.append(Data("--\(shareBoundary)\r\nContent-Disposition: form-data; name=\"channelId\"\r\n\r\n\(channelId)\r\n".utf8))
    }
    data.append(Data("--\(shareBoundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"\(filename)\"\r\nContent-Type: image/png\r\n\r\n".utf8))
    if let image { data.append(image) }
    data.append(Data("\r\n--\(shareBoundary)--\r\n".utf8))
    return data
}

private func shareCreate(
    _ client: any Client,
    token: String,
    serverId: String,
    body: Data
) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "multipart/form-data; boundary=\(shareBoundary)"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    let response = try await client.send(.post, headers: headers, to: "/api/share-artifacts/message-selection") { request in
        request.body = .init(data: body)
    }
    let json = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    return (response.status, json)
}

private func shareServices(_ f: ShareFixture, serverBase: String? = nil, shareBase: String? = nil, cdnBase: String? = nil) -> FallbackServices {
    FallbackServices(
        nodeEnv: "test",
        tracker: DbLivenessTracker(ping: {}),
        pingDatabase: {},
        emailAccounts: f.accounts,
        serverBaseURL: serverBase,
        shareBaseURL: shareBase,
        cdnBaseURL: cdnBase
    )
}

@Test func shareArtifactUsesTheCanonicalShareAndCdnHosts() async throws {
    let f = makeShareFixture()
    let serverBase = "https://raft-server-staging.fly.dev"
    let shareBase = "https://slock.ai/share"
    let cdnBase = "https://cdn.slock.ai"
    try await withApp { app in
        configure(app, services: shareServices(f, serverBase: serverBase, shareBase: shareBase, cdnBase: cdnBase))
        try await app.testing { client in
            let created = try await shareCreate(client, token: f.ownerToken, serverId: f.serverId, body: shareForm(channelId: f.channelId, image: sharePNG))
            #expect(created.status == .ok)
            let id = try #require(created.body["id"] as? String)
            let url = try #require(created.body["url"] as? String)
            let imageUrl = try #require(created.body["imageUrl"] as? String)
            let storageKey = "\(f.serverId)/share-artifacts/\(id).png"
            #expect(url == "https://slock.ai/share/\(id)")
            #expect(imageUrl == "https://cdn.slock.ai/\(storageKey)")

            let page = try await client.send(.get, headers: HTTPFields(), to: URI(string: "/share/\(id)"))
            #expect(page.status == .ok)
            #expect(page.headers[HTTPField.Name("Cache-Control")!] == "public, max-age=300")
            #expect(page.headers[HTTPField.Name("X-Robots-Tag")!] == "noindex, nofollow")
            let html = page.body.string ?? ""
            #expect(html.contains("property=\"og:type\" content=\"article\""))
            #expect(html.contains("property=\"og:title\" content=\"Slock conversation screenshot\""))
            #expect(html.contains("property=\"og:description\" content=\"A conversation screenshot shared from Slock.\""))
            #expect(html.contains("property=\"og:url\" content=\"https://slock.ai/share/\(id)\""))
            #expect(html.contains("property=\"og:image\" content=\"https://cdn.slock.ai/\(storageKey)\""))
            #expect(html.contains("property=\"og:image:secure_url\" content=\"https://cdn.slock.ai/\(storageKey)\""))
            #expect(html.contains("property=\"og:image:type\" content=\"image/png\""))
            #expect(html.contains("name=\"twitter:image\" content=\"https://cdn.slock.ai/\(storageKey)\""))
            #expect(html.contains("name=\"twitter:title\" content=\"Slock conversation screenshot\""))
            #expect(!html.contains("fly.dev"), "the canonical hosts replace the request host")

            // The server-local image route still serves the bytes, not only the CDN.
            let fallbackImage = try await client.send(.get, headers: HTTPFields(), to: URI(string: "/share/\(id).png"))
            #expect(fallbackImage.status == .ok)
            #expect(fallbackImage.headers[.contentType] == "image/png")
            #expect(fallbackImage.body.data == sharePNG)
        }
    }
}

@Test func shareArtifactServesTheUploadedPngWithImmutableHeaders() async throws {
    let f = makeShareFixture()
    try await withApp { app in
        configure(app, services: shareServices(f))
        try await app.testing { client in
            let created = try await shareCreate(client, token: f.ownerToken, serverId: f.serverId, body: shareForm(channelId: f.channelId, image: sharePNG))
            let id = try #require(created.body["id"] as? String)
            let image = try await client.send(.get, headers: HTTPFields(), to: URI(string: "/share/\(id).png"))
            #expect(image.status == .ok)
            #expect(image.headers[.contentType] == "image/png")
            #expect(image.headers[HTTPField.Name("Cache-Control")!] == "public, immutable, max-age=31536000")
            #expect(image.headers[HTTPField.Name("Content-Disposition")!] == "inline")
            #expect(image.headers[HTTPField.Name("X-Content-Type-Options")!] == "nosniff")
            #expect(image.body.data == sharePNG, "the uploaded bytes are served back unchanged")
        }
    }
}

@Test func shareArtifactCreationValidatesTheUpload() async throws {
    let f = makeShareFixture()
    try await withApp { app in
        configure(app, services: shareServices(f))
        try await app.testing { client in
            let missingChannel = try await shareCreate(client, token: f.ownerToken, serverId: f.serverId, body: shareForm(channelId: nil, image: sharePNG))
            #expect(missingChannel.status == .badRequest)
            #expect(missingChannel.body["error"] as? String == "channelId is required")

            let missingImage = try await shareCreate(client, token: f.ownerToken, serverId: f.serverId, body: shareForm(channelId: f.channelId, image: nil))
            #expect(missingImage.status == .badRequest)
            #expect(missingImage.body["error"] as? String == "image is required")

            let notPng = try await shareCreate(client, token: f.ownerToken, serverId: f.serverId, body: shareForm(channelId: f.channelId, image: Data("not a png".utf8)))
            #expect(notPng.status == .unsupportedMediaType)
            #expect(notPng.body["error"] as? String == "Share artifact must be a PNG image")

            // A channel on another Server is outside the caller's membership.
            let crossServer = try await shareCreate(client, token: f.ownerToken, serverId: f.serverId, body: shareForm(channelId: f.otherChannelId, image: sharePNG))
            #expect(crossServer.status == .forbidden)

            let guest = try await shareCreate(client, token: f.guestToken, serverId: f.serverId, body: shareForm(channelId: f.channelId, image: sharePNG))
            #expect(guest.status == .forbidden)
            #expect(guest.body["error"] as? String == "Guests cannot create share artifacts")
        }
    }
}

@Test func unknownOrMalformedShareArtifactIdsAre404PlainText() async throws {
    let f = makeShareFixture()
    try await withApp { app in
        configure(app, services: shareServices(f))
        try await app.testing { client in
            for path in ["/share/not-a-uuid", "/share/not-a-uuid.png", "/share/11111111-1111-4111-8111-111111111111"] {
                let res = try await client.send(.get, headers: HTTPFields(), to: URI(string: path))
                #expect(res.status == .notFound)
                #expect(res.body.string == "Not found")
            }
        }
    }
}

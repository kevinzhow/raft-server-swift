// PRIVATE single-URL follow-up: tests written before production changes.
import Foundation
import HTTPTypes
@testable import RaftHTTP
import RaftHTTPServer
import RaftObjectStorage
import TestSupport
import Testing
import Vapor
import VaporTesting

@Suite(.serialized) struct AttachmentSingleURLBrowserTests: Sendable {
    @Test(.timeLimit(.minutes(1))) func uploadedBinaryDownloadsThroughHeaderlessAbsoluteProxyURL() async throws {
        try await withSingleURLStorage { storage in
            let setup = AttachmentPreviewAccounts(storage: storage.storage)
            let bytes = Data([0, 255, 254, 128, 13, 10, 1, 2, 3, 65, 66, 67])
            try await withApp { app in
                configure(app, services: singleURLServices(setup.accounts))
                try await app.testing(.running, options: .live(clientOptions: .init(timeout: .seconds(10)))) { client in
                    let id = try await singleURLUpload(client, authorization: setup.authorization, server: setup.serverId,
                        channel: setup.channelId, filename: "download.bin", mime: "application/octet-stream", bytes: bytes)
                    let first = try await client.get(URI(string: "/api/attachments/\(id)/url?disposition=attachment"),
                        headers: singleURLHeaders(setup.authorization, setup.serverId))
                    #expect(first.status == .ok)
                    let wire = try await singleURLWire(first)
                    let components = try #require(URLComponents(string: wire.url))
                    #expect(components.scheme == "http")
                    #expect(components.host == "127.0.0.1")
                    #expect(components.port == client.port)
                    #expect(components.path == "/api/attachments/\(id)")
                    #expect(components.queryItems?.first { $0.name == "token" }?.value == String(setup.authorization.dropFirst(7)))
                    #expect(components.queryItems?.first { $0.name == "serverId" }?.value == setup.serverId)
                    #expect(components.queryItems?.first { $0.name == "disposition" }?.value == "attachment")
                    let download = try await client.get(URI(string: wire.url))
                    #expect(download.status == .ok)
                    let plaintext = try await attachmentPreviewBody(download)
                    #expect(plaintext == bytes)
                    #expect(download.headers[.contentType] == "application/octet-stream")
                    #expect(download.headers[.contentDisposition]?.hasPrefix("attachment;") == true)
                    let sealed = storage.state.value.withLock { Array($0.ciphertext.values) }
                    #expect(sealed.count == 1)
                    #expect(sealed.first != bytes)
                    #expect(sealed.first?.count == bytes.count + 28)
                    #expect(setup.accounts.messagesAndThreadsStore.withState { $0.developmentAttachmentBytes[id] } == nil)
                    #expect(setup.accounts.messagesAndThreadsStore.attachmentPresign == nil)
                }
            }
        }
    }

    @Test(.timeLimit(.minutes(1))) func singleProxyHasNullExpiryAndMatchesNodeDispositionRules() async throws {
        try await withSingleURLStorage { storage in
            let setup = AttachmentPreviewAccounts(storage: storage.storage)
            try await withApp { app in
                configure(app, services: singleURLServices(setup.accounts))
                try await app.testing(.running, options: .live(clientOptions: .init(timeout: .seconds(10)))) { client in
                    let cases: [(String, String, String, String?, Bool)] = [
                        ("clip.mp4", "video/mp4", "?disposition=inline", "inline", true),
                        ("voice.mp3", "audio/mpeg", "?disposition=inline", "inline", true),
                        ("doc.pdf", "application/pdf", "?disposition=inline", "inline", true),
                        ("generic.pdf", "application/octet-stream", "?disposition=inline", "inline", true),
                        ("clip.mp4", "video/mp4", "?disposition=inline&download=1", "attachment", false),
                        ("note.txt", "text/plain", "?disposition=inline", nil, false),
                        ("page.html", "text/html", "?disposition=inline", nil, false),
                        ("clip.mp4", "video/mp4", "", nil, false),
                        ("note.txt", "text/plain", "?disposition=inline&disposition=attachment", nil, false),
                    ]
                    for (filename, mime, query, disposition, inline) in cases {
                        let bytes = Data("synthetic uploaded payload: \(filename)\n".utf8)
                        let id = try await singleURLUpload(client, authorization: setup.authorization, server: setup.serverId,
                            channel: setup.channelId, filename: filename, mime: mime, bytes: bytes)
                        let first = try await client.get(URI(string: "/api/attachments/\(id)/url\(query)"),
                            headers: singleURLHeaders(setup.authorization, setup.serverId))
                        #expect(first.status == .ok)
                        let wire = try await singleURLWire(first)
                        let components = try #require(URLComponents(string: wire.url))
                        #expect(components.queryItems?.first { $0.name == "disposition" }?.value == disposition)
                        let fetched = try await client.get(URI(string: wire.url))
                        #expect(fetched.status == .ok)
                        let plaintext = try await attachmentPreviewBody(fetched)
                        #expect(plaintext == bytes)
                        #expect(fetched.headers[.contentDisposition]?.hasPrefix(inline ? "inline;" : "attachment;") == true)
                    }
                }
            }
        }
    }

    @Test(.timeLimit(.minutes(1))) func queryOnlySingleURLAndOriginalHeaderPriorityRemainObservable() async throws {
        try await withSingleURLStorage { storage in
            let setup = AttachmentPreviewAccounts(storage: storage.storage)
            let bytes = Data("query-authenticated actual object\n".utf8)
            try await withApp { app in
                configure(app, services: singleURLServices(setup.accounts))
                try await app.testing(.running, options: .live(clientOptions: .init(timeout: .seconds(10)))) { client in
                    let id = try await singleURLUpload(client, authorization: setup.authorization, server: setup.serverId,
                        channel: setup.channelId, filename: "query.txt", mime: "text/plain", bytes: bytes)
                    var path = URLComponents()
                    path.path = "/api/attachments/\(id)/url"
                    path.queryItems = [.init(name: "token", value: String(setup.authorization.dropFirst(7))),
                        .init(name: "serverId", value: setup.serverId), .init(name: "disposition", value: "attachment")]
                    let requestPath = try #require(path.string)
                    let first = try await client.get(URI(string: requestPath))
                    #expect(first.status == .ok)
                    let wire = try await singleURLWire(first)
                    let fetched = try await client.get(URI(string: wire.url))
                    #expect(fetched.status == .ok)
                    let plaintext = try await attachmentPreviewBody(fetched)
                    #expect(plaintext == bytes)
                    let fallback = try await client.get(URI(string: requestPath), headers: singleURLHeaders("Bearer synthetic invalid+header", nil))
                    #expect(fallback.status == .ok)
                    let fallbackWire = try await singleURLWire(fallback)
                    let parsed = try #require(URLComponents(string: fallbackWire.url))
                    #expect(parsed.percentEncodedQuery?.hasPrefix("token=synthetic+invalid%2Bheader&") == true)
                    let refused = try await client.get(URI(string: fallbackWire.url))
                    #expect(refused.status == .unauthorized)
                    _ = try await attachmentPreviewBody(refused)
                }
            }
        }
    }

    @Test func singleConfiguredAndForwardedOriginsUseTheSameProxyPolicy() async throws {
        try await withSingleURLStorage { storage in
            let setup = AttachmentPreviewAccounts(storage: storage.storage)
            let id = try await setup.upload(Data("stored origin proof".utf8), filename: "origin.txt", mime: "text/plain")
            for slockdev in [false, true] {
                try await withApp { app in
                    configure(app, services: singleURLServices(setup.accounts, environment: [
                        "SERVER_URL": "https://configured.example", "DEPLOYMENT_ENV": slockdev ? "slockdev" : "production",
                    ]))
                    try await app.testing { client in
                        var fields = singleURLHeaders(setup.authorization, setup.serverId)
                        fields[HTTPField.Name("Host")!] = "incoming.example:8080"
                        fields[HTTPField.Name("X-Forwarded-Host")!] = "preview.example:8443, ignored.example"
                        fields[HTTPField.Name("X-Forwarded-Proto")!] = "https, http"
                        let response = try await client.get(URI(string: "/api/attachments/\(id)/url"), headers: fields)
                        #expect(response.status == .ok)
                        let wire = try await singleURLWire(response)
                        let parsed = try #require(URLComponents(string: wire.url))
                        #expect(parsed.scheme == "https")
                        #expect(parsed.host == (slockdev ? "preview.example" : "configured.example"))
                        #expect(parsed.port == (slockdev ? 8443 : nil))
                    }
                }
            }
        }
    }

    @Test func singleHTTPRefusesUnconfiguredStorageAndInvalidBaseWithExactErrors() async throws {
        let accounts = EmailLoginDirectory()
        accounts.oauth.jwtSecret = "single-url-only-synthetic-signing-secret-at-least-32-bytes"
        let owner = UUID().uuidString.lowercased(), server = UUID().uuidString.lowercased()
        accounts.addAccount(id: owner, email: "single-no-storage@example.com", password: "password123")
        accounts.markEmailVerified(userId: owner)
        accounts.oauth.addOwnedServer(id: server, slug: "single-no-storage", name: "Single", ownerId: owner)
        let channel = accounts.oauth.createChannel(serverId: server, name: "single", creatorUserId: owner)
        accounts.addPostableChannel(serverId: server, channelId: channel, memberId: owner, name: "single")
        let id = accounts.addChannelAttachment(channelId: channel, uploaderId: owner, filename: "metadata.bin", mimeType: "application/octet-stream", sizeBytes: 1)
        let authorization = "Bearer \(accounts.mintAccessTokenForTesting(userId: owner))"
        try await withApp { app in
            configure(app, services: singleURLServices(accounts))
            try await app.testing { client in
                let missing = try await client.get(URI(string: "/api/attachments/00000000-0000-4000-8000-000000000086/url"), headers: singleURLHeaders(authorization, server))
                #expect(missing.status == .notFound)
                let missingError = try await singleURLError(missing)
                #expect(missingError == "Attachment not found")
                let response = try await client.get(URI(string: "/api/attachments/\(id)/url"), headers: singleURLHeaders(authorization, server))
                #expect(response.status == .serviceUnavailable)
                let error = try await singleURLError(response)
                #expect(error == "File storage is not configured on this server")
            }
        }
        try await withSingleURLStorage { storage in
            let setup = AttachmentPreviewAccounts(storage: storage.storage)
            let id = try await setup.upload(Data("real storage object".utf8), filename: "proof.txt", mime: "text/plain")
            try await withApp { app in
                configure(app, services: singleURLServices(setup.accounts, environment: ["SERVER_URL": "://invalid-base"]))
                try await app.testing { client in
                    let response = try await client.get(URI(string: "/api/attachments/\(id)/url"), headers: singleURLHeaders(setup.authorization, setup.serverId))
                    #expect(response.status == .internalServerError)
                    let error = try await singleURLError(response)
                    #expect(error == "Failed to get attachment URL")
                }
            }
        }
    }
}

// Shared only within the HTTP test target; these helpers call the actual router
// and real Soto adapter and contain no presigner/count/fake-byte callbacks.
struct SingleURLWire: Decodable, CustomStringConvertible, CustomDebugStringConvertible {
    let url: String
    var description: String { "SingleURLWire(redacted)" }
    var debugDescription: String { description }
    enum CodingKeys: String, CodingKey { case url, expiresAt }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        url = try values.decode(String.self, forKey: .url)
        guard values.contains(.expiresAt), try values.decodeNil(forKey: .expiresAt) else {
            throw DecodingError.dataCorruptedError(forKey: .expiresAt, in: values, debugDescription: "Expected explicit null proxy expiry")
        }
    }
}
func singleURLWire(_ response: ClientResponse) async throws -> SingleURLWire {
    let bytes = try await attachmentPreviewBody(response)
    return try JSONDecoder().decode(SingleURLWire.self, from: bytes)
}
func singleURLError(_ response: ClientResponse) async throws -> String {
    struct Body: Decodable { let error: String }
    let bytes = try await attachmentPreviewBody(response)
    return try JSONDecoder().decode(Body.self, from: bytes).error
}
func singleURLHeaders(_ authorization: String?, _ server: String?) -> HTTPFields {
    var fields = HTTPFields(); fields[.authorization] = authorization
    fields[HTTPField.Name("X-Server-Id")!] = server; return fields
}
func singleURLServices(_ accounts: EmailLoginDirectory, environment: [String: String] = [:]) -> FallbackServices {
    FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, releaseEnvironment: environment, emailAccounts: accounts)
}
func withSingleURLStorage(_ body: (AttachmentPreviewStorageFixture) async throws -> Void) async throws {
    let storage = try AttachmentPreviewStorageFixture()
    do { try await body(storage); await storage.stop() }
    catch { await storage.stop(); throw error }
}
func singleURLUpload(_ client: any TestClient, authorization: String, server: String, channel: String,
                     filename: String, mime: String, bytes: Data) async throws -> String {
    let boundary = "single-url-upload-boundary"
    var data = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"channelId\"\r\n\r\n\(channel)\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"files\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8)
    data.append(bytes); data.append(Data("\r\n--\(boundary)--\r\n".utf8))
    let body = data
    var fields = singleURLHeaders(authorization, server)
    fields[.contentType] = "multipart/form-data; boundary=\(boundary)"
    let response = try await client.send(.post, headers: fields, to: "/api/attachments/upload") { $0.body = .init(data: body) }
    #expect(response.status == .ok)
    struct Body: Decodable { struct Row: Decodable { let id: String }; let attachments: [Row] }
    let uploadedBytes = try await attachmentPreviewBody(response)
    let decoded = try JSONDecoder().decode(Body.self, from: uploadedBytes)
    return try #require(decoded.attachments.first?.id)
}
